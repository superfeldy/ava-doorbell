package com.doorbell.ava.services

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.doorbell.ava.DoorbellApplication
import com.doorbell.ava.MainActivity
import com.doorbell.ava.R
import com.doorbell.ava.config.ServerConfig
import org.eclipse.paho.client.mqttv3.*
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MqttService : Service() {
    private var mqttClient: MqttAsyncClient? = null
    private val executor = Executors.newSingleThreadScheduledExecutor()
    
    companion object {
        private const val TAG = "MqttService"
        private const val NOTIF_ID = 1
        private const val DOORBELL_NOTIF_ID = 100
        const val ACTION_DOORBELL = "com.doorbell.ava.DOORBELL_RING"
    }

    override fun onCreate() {
        super.onCreate()
        startForeground(NOTIF_ID, createServiceNotification())
        connectMqtt()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        mqttClient?.disconnect()
        executor.shutdownNow()
    }

    private fun createServiceNotification(): Notification {
        val intent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, DoorbellApplication.CHANNEL_SERVICE)
            .setContentTitle("Doorbell Monitor")
            .setContentText("Listening for doorbell events")
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(intent)
            .setOngoing(true)
            .build()
    }

    private fun connectMqtt() {
        val config = ServerConfig.load(this)
        val serverUri = "tcp://${config.serverHost}:${config.mqttPort}"
        
        try {
            mqttClient = MqttAsyncClient(serverUri, "ava_doorbell_${System.currentTimeMillis()}", MemoryPersistence())
            
            mqttClient?.setCallback(object : MqttCallbackExtended {
                override fun connectComplete(reconnect: Boolean, serverURI: String?) {
                    Log.i(TAG, "MQTT connected to $serverURI")
                    subscribe()
                }
                override fun connectionLost(cause: Throwable?) {
                    Log.w(TAG, "MQTT connection lost")
                    scheduleReconnect()
                }
                override fun messageArrived(topic: String?, message: MqttMessage?) {
                    handleMessage(topic, message)
                }
                override fun deliveryComplete(token: IMqttDeliveryToken?) {}
            })
            
            val options = MqttConnectOptions().apply {
                isCleanSession = true
                connectionTimeout = 10
                keepAliveInterval = 30
            }
            
            mqttClient?.connect(options)
        } catch (e: Exception) {
            Log.e(TAG, "MQTT connect error: ${e.message}")
            scheduleReconnect()
        }
    }

    private fun subscribe() {
        try {
            mqttClient?.subscribe(arrayOf("doorbell/ring", "doorbell/motion"), intArrayOf(1, 1))
            Log.i(TAG, "Subscribed to doorbell topics")
        } catch (e: Exception) {
            Log.e(TAG, "Subscribe error: ${e.message}")
        }
    }

    private fun handleMessage(topic: String?, message: MqttMessage?) {
        if (topic == "doorbell/ring") {
            Log.i(TAG, "🔔 DOORBELL RING!")
            showDoorbellNotification()
            vibrate()
            sendBroadcast(Intent(ACTION_DOORBELL))
        }
    }

    private fun showDoorbellNotification() {
        val intent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, DoorbellApplication.CHANNEL_DOORBELL)
            .setContentTitle("🔔 Doorbell")
            .setContentText("Someone is at the door!")
            .setSmallIcon(R.drawable.ic_notification)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(intent)
            .setVibrate(longArrayOf(0, 500, 200, 500))
            .build()

        NotificationManagerCompat.from(this).notify(DOORBELL_NOTIF_ID, notification)
    }

    @Suppress("DEPRECATION")
    private fun vibrate() {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 500, 200, 500, 200, 500), -1))
        } else {
            vibrator.vibrate(longArrayOf(0, 500, 200, 500, 200, 500), -1)
        }
    }

    private fun scheduleReconnect() {
        executor.schedule({ connectMqtt() }, 5, TimeUnit.SECONDS)
    }
}
