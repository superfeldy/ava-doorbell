package com.doorbell.ava

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.Toast
import androidx.core.content.ContextCompat
import org.json.JSONObject
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString.Companion.toByteString
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * NativeTalkManager — Native Android mic capture + WebSocket streaming to talk relay.
 *
 * Captures audio via AudioRecord at 8kHz mono PCM16, sends frames over WebSocket
 * directly to the talk_relay service (bypasses WebView getUserMedia HTTPS restriction).
 *
 * Wire format: [0x01 (PCM16 LE format byte)] + [PCM16 audio data]
 * Chunk size: 640 bytes (320 PCM16 samples = 40ms at 8kHz)
 */
class NativeTalkManager(private val context: Context) {

    companion object {
        private const val TAG = "NativeTalkManager"
        private const val SAMPLE_RATE = 8000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val CHUNK_SAMPLES = 320  // 40ms at 8kHz
        private const val CHUNK_BYTES = CHUNK_SAMPLES * 2  // 16-bit = 2 bytes per sample
        private const val FORMAT_PCM16_LE: Byte = 0x01
    }

    private var audioRecord: AudioRecord? = null
    private var webSocket: WebSocket? = null
    private var recordThread: Thread? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var agc: AutomaticGainControl? = null
    private val recording = AtomicBoolean(false)
    private val connected = AtomicBoolean(false)

    /** OkHttp client that trusts self-signed certs (LAN deployment with self-signed TLS). */
    private val wsClient: OkHttpClient by lazy {
        val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        })
        val sslCtx = SSLContext.getInstance("TLS")
        sslCtx.init(null, trustAll, java.security.SecureRandom())

        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)  // no read timeout for streaming
            .sslSocketFactory(sslCtx.socketFactory, trustAll[0] as X509TrustManager)
            .hostnameVerifier { _, _ -> true }
            .build()
    }

    var onStateChanged: ((TalkState) -> Unit)? = null

    enum class TalkState { IDLE, CONNECTING, ACTIVE, ERROR }

    private var pendingServerIp: String? = null
    private var pendingTalkPort: Int = 0

    fun startTalk(serverIp: String, talkPort: Int) {
        if (recording.get()) return

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "RECORD_AUDIO permission not granted")
            onStateChanged?.invoke(TalkState.ERROR)
            return
        }

        pendingServerIp = serverIp
        pendingTalkPort = talkPort
        onStateChanged?.invoke(TalkState.CONNECTING)

        // Try wss:// first (talk_relay may have TLS enabled), fall back to ws://
        connectWebSocket("wss://$serverIp:$talkPort", fallbackToWs = true)
    }

    private fun connectWebSocket(url: String, fallbackToWs: Boolean) {
        Log.i(TAG, "Connecting to $url")
        val request = Request.Builder().url(url).build()

        webSocket = wsClient.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                Log.i(TAG, "WebSocket connected to $url")
                connected.set(true)
                startRecording()
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                try {
                    val json = JSONObject(text)
                    val status = json.optString("status")
                    when (status) {
                        "backchannel_unavailable" -> {
                            Log.w(TAG, "Backchannel unavailable — doorbell not responding")
                            Handler(Looper.getMainLooper()).post {
                                Toast.makeText(context, "Talk unavailable — doorbell not responding", Toast.LENGTH_LONG).show()
                            }
                        }
                        "backchannel_ready" -> Log.i(TAG, "Backchannel ready")
                        "backchannel_failed" -> Log.w(TAG, "Backchannel failed, retry in ${json.optInt("retry_in")}s")
                        "backchannel_connecting" -> Log.i(TAG, "Backchannel connecting...")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Unexpected text message: $text")
                }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                Log.e(TAG, "WebSocket failed ($url): ${t.message}")
                if (fallbackToWs && url.startsWith("wss://")) {
                    // TLS failed — try plain ws://
                    val wsUrl = "ws://${pendingServerIp}:${pendingTalkPort}"
                    Log.i(TAG, "Falling back to $wsUrl")
                    connectWebSocket(wsUrl, fallbackToWs = false)
                } else {
                    connected.set(false)
                    stopTalk()
                    onStateChanged?.invoke(TalkState.ERROR)
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                Log.i(TAG, "WebSocket closed: $reason")
                connected.set(false)
                stopTalk()
            }
        })
    }

    fun stopTalk() {
        recording.set(false)
        connected.set(false)

        recordThread?.let { thread ->
            thread.interrupt()
            try { thread.join(500) } catch (_: InterruptedException) {}
        }
        recordThread = null

        // Stop AudioRecord first, then release effects (effects may reference active session)
        try {
            audioRecord?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "AudioRecord stop error: ${e.message}")
        }

        echoCanceler?.release()
        echoCanceler = null
        noiseSuppressor?.release()
        noiseSuppressor = null
        agc?.release()
        agc = null

        audioRecord?.release()
        audioRecord = null

        try {
            webSocket?.close(1000, "Talk ended")
        } catch (e: Exception) {
            Log.w(TAG, "WebSocket close error: ${e.message}")
        }
        webSocket = null

        onStateChanged?.invoke(TalkState.IDLE)
    }

    fun isActive(): Boolean = recording.get() && connected.get()

    private fun startRecording() {
        val minBufSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        val bufferSize = maxOf(minBufSize, CHUNK_BYTES * 4)

        try {
            // Use MIC source for cleanest signal — explicit AGC + NS effects handle processing.
            // VOICE_COMMUNICATION platform DSP can add artifacts on some (MediaTek) devices.
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                AUDIO_FORMAT,
                bufferSize
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "Cannot create AudioRecord: ${e.message}")
            onStateChanged?.invoke(TalkState.ERROR)
            return
        }

        if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord failed to initialize")
            audioRecord?.release()
            audioRecord = null
            onStateChanged?.invoke(TalkState.ERROR)
            return
        }

        // Enable acoustic echo cancellation if available
        val sessionId = audioRecord!!.audioSessionId
        if (AcousticEchoCanceler.isAvailable()) {
            echoCanceler = AcousticEchoCanceler.create(sessionId)
            echoCanceler?.enabled = true
            Log.i(TAG, "AcousticEchoCanceler enabled (session=$sessionId)")
        } else {
            Log.w(TAG, "AcousticEchoCanceler not available on this device")
        }

        // Enable noise suppression if available
        if (NoiseSuppressor.isAvailable()) {
            noiseSuppressor = NoiseSuppressor.create(sessionId)
            noiseSuppressor?.enabled = true
            Log.i(TAG, "NoiseSuppressor enabled (session=$sessionId)")
        } else {
            Log.w(TAG, "NoiseSuppressor not available on this device")
        }

        // Enable hardware automatic gain control — boosts physical preamp gain
        // This is critical for quiet mics that output peaks of only 14-67/32767
        if (AutomaticGainControl.isAvailable()) {
            agc = AutomaticGainControl.create(sessionId)
            agc?.enabled = true
            Log.i(TAG, "AutomaticGainControl enabled (session=$sessionId)")
        } else {
            Log.w(TAG, "AutomaticGainControl not available on this device")
        }

        recording.set(true)
        audioRecord?.startRecording()
        onStateChanged?.invoke(TalkState.ACTIVE)
        Log.i(TAG, "Recording started (8kHz mono PCM16, MIC + AGC + NS)")

        recordThread = Thread({
            val buffer = ByteArray(CHUNK_BYTES)
            val frame = ByteArray(1 + CHUNK_BYTES)
            frame[0] = FORMAT_PCM16_LE

            while (recording.get() && connected.get()) {
                val read = audioRecord?.read(buffer, 0, CHUNK_BYTES) ?: -1
                if (read > 0) {
                    System.arraycopy(buffer, 0, frame, 1, read)
                    // Pad remaining bytes with silence if short read
                    if (read < CHUNK_BYTES) {
                        for (i in (1 + read) until frame.size) {
                            frame[i] = 0
                        }
                    }
                    try {
                        webSocket?.send(frame.toByteString(0, 1 + CHUNK_BYTES))
                    } catch (e: Exception) {
                        Log.w(TAG, "Send error: ${e.message}")
                        break
                    }
                } else if (read < 0) {
                    Log.w(TAG, "AudioRecord.read returned $read")
                    break
                }
            }

            Log.i(TAG, "Recording thread stopped")
        }, "native-talk-record")
        recordThread!!.isDaemon = true
        recordThread!!.start()
    }
}
