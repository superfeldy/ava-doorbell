package com.doorbell.ava

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken
import org.eclipse.paho.client.mqttv3.MqttCallback
import org.eclipse.paho.client.mqttv3.MqttClient
import org.eclipse.paho.client.mqttv3.MqttConnectOptions
import org.eclipse.paho.client.mqttv3.MqttException
import org.eclipse.paho.client.mqttv3.MqttMessage
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import java.util.concurrent.atomic.AtomicBoolean

/**
 * MqttManager — MQTT connection manager for doorbell events (v4.0)
 *
 * V4 changes from V3:
 * - 15s connect timeout watchdog clears `connecting` AtomicBoolean (V3: stuck forever on timeout)
 * - `connecting.set(false)` in finally block (V3: missed on some exception paths)
 * - forceReconnect() public method for ConfigActivity trigger
 */
class MqttManager(
    @Suppress("unused") private val context: Context,
    private val onConnectionStateChanged: (Boolean) -> Unit,
    private val onDoorbellRing: () -> Unit,
    private val onMotionEvent: (() -> Unit)? = null
) : MqttCallback {

    companion object {
        private const val TAG = "MqttManager"
        private const val INITIAL_RECONNECT_MS = 2000L
        private const val MAX_RECONNECT_MS = 30000L
        private const val CONNECT_TIMEOUT_MS = 15000L
    }

    private var mqttClient: MqttClient? = null
    private val connected = AtomicBoolean(false)
    private val connecting = AtomicBoolean(false)
    @Volatile private var reconnectAttempt = 0
    private val mainHandler = Handler(Looper.getMainLooper())
    private val connectionLock = Object()

    private var lastServerIp: String? = null
    private var lastPort: Int = 1883
    private var reconnectRunnable: Runnable? = null

    private val subscribedTopics = arrayOf(
        "doorbell/ring",
        "doorbell/event",
        "doorbell/status"
    )

    private val topicQoS = intArrayOf(1, 1, 1)

    fun connect(serverIp: String, port: Int = 1883) {
        if (connected.get()) {
            Log.d(TAG, "Already connected — skipping connect()")
            return
        }
        if (!connecting.compareAndSet(false, true)) {
            Log.d(TAG, "Connection already in progress — skipping connect()")
            return
        }

        lastServerIp = serverIp
        lastPort = port
        Log.i(TAG, "Connecting to MQTT broker at tcp://$serverIp:$port")

        // V4 fix: 15s watchdog to clear `connecting` if connect() hangs
        val watchdogRunnable = Runnable {
            if (connecting.get() && !connected.get()) {
                Log.w(TAG, "Connect timeout watchdog fired — clearing connecting flag")
                connecting.set(false)
            }
        }
        mainHandler.postDelayed(watchdogRunnable, CONNECT_TIMEOUT_MS)

        Thread({
            try {
                val brokerUrl = "tcp://$serverIp:$port"
                val clientId = "ava-doorbell-${System.currentTimeMillis()}"

                val client = MqttClient(brokerUrl, clientId, MemoryPersistence())
                client.setCallback(this)

                val connectOptions = MqttConnectOptions().apply {
                    isCleanSession = true
                    connectionTimeout = 10
                    keepAliveInterval = 60
                    setWill("doorbell/app/status", "offline".toByteArray(), 1, true)
                }

                client.connect(connectOptions)
                // Cancel watchdog — connection succeeded
                mainHandler.removeCallbacks(watchdogRunnable)
                synchronized(connectionLock) {
                    mqttClient = client
                    connected.set(true)
                }
                reconnectAttempt = 0
                Log.i(TAG, "Connected to MQTT broker at $brokerUrl")

                try {
                    client.subscribe(subscribedTopics, topicQoS)
                    Log.i(TAG, "Subscribed to topics: ${subscribedTopics.joinToString()}")
                } catch (e: MqttException) {
                    Log.e(TAG, "Error subscribing to topics", e)
                }

                mainHandler.post { onConnectionStateChanged(true) }

            } catch (e: MqttException) {
                Log.e(TAG, "Failed to connect to MQTT broker at tcp://$serverIp:$port: ${e.message}")
                connected.set(false)
                mainHandler.post { onConnectionStateChanged(false) }
                scheduleReconnect(serverIp, port)
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error connecting to MQTT at tcp://$serverIp:$port: ${e.message}")
                connected.set(false)
                mainHandler.post { onConnectionStateChanged(false) }
                scheduleReconnect(serverIp, port)
            } finally {
                // V4 fix: always clear connecting flag
                connecting.set(false)
            }
        }, "mqtt-connect").start()
    }

    fun disconnect() {
        try {
            mqttClient?.let {
                if (it.isConnected) {
                    it.disconnect()
                }
                it.close()
            }
        } catch (e: MqttException) {
            Log.e(TAG, "Error disconnecting from MQTT broker", e)
        }

        mqttClient = null
        connected.set(false)
        connecting.set(false)
        reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        reconnectRunnable = null
        onConnectionStateChanged(false)
    }

    /**
     * V4: Public method so ConfigActivity can trigger reconnect via forceReconnect flag.
     */
    fun forceReconnect(serverIp: String, port: Int) {
        disconnect()
        reconnectAttempt = 0
        connect(serverIp, port)
    }

    fun isConnected(): Boolean = connected.get()

    override fun connectionLost(cause: Throwable?) {
        Log.w(TAG, "MQTT connection lost", cause)
        connected.set(false)
        connecting.set(false)
        mainHandler.post { onConnectionStateChanged(false) }

        lastServerIp?.let { ip ->
            Log.i(TAG, "Scheduling auto-reconnect to $ip:$lastPort")
            scheduleReconnect(ip, lastPort)
        }
    }

    override fun messageArrived(topic: String?, message: MqttMessage?) {
        try {
            val payload = message?.payload?.let { String(it) } ?: ""

            when (topic) {
                "doorbell/ring" -> {
                    Log.i(TAG, "RING event received: $payload")
                    mainHandler.post { onDoorbellRing() }
                }
                "doorbell/event" -> {
                    Log.d(TAG, "Event: $payload")
                    // Check for VideoMotion events to reset idle timers
                    if (payload.contains("VideoMotion") || payload.contains("MDResult")) {
                        onMotionEvent?.let { mainHandler.post(it) }
                    }
                }
                "doorbell/status" -> {
                    Log.i(TAG, "Alarm scanner status: $payload")
                }
                else -> {
                    Log.d(TAG, "Message on unknown topic: $topic")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error processing MQTT message on topic=$topic", e)
        }
    }

    override fun deliveryComplete(token: IMqttDeliveryToken?) {
        // no-op
    }

    private fun scheduleReconnect(serverIp: String, port: Int) {
        // Cancel any pending reconnect to prevent pileup on flappy networks
        reconnectRunnable?.let { mainHandler.removeCallbacks(it) }

        val delay = minOf(
            INITIAL_RECONNECT_MS * (1 shl reconnectAttempt),
            MAX_RECONNECT_MS
        )

        reconnectAttempt++
        Log.i(TAG, "Scheduling reconnect #$reconnectAttempt in ${delay}ms to tcp://$serverIp:$port")

        reconnectRunnable = Runnable { connect(serverIp, port) }
        mainHandler.postDelayed(reconnectRunnable!!, delay)
    }
}
