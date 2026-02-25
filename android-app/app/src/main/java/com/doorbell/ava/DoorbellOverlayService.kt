package com.doorbell.ava

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.NotificationCompat
import java.io.InputStream
import java.net.URL
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * DoorbellOverlayService — Floating overlay popup for doorbell ring events (v4.0)
 *
 * Shows a floating window with camera preview + Answer/Dismiss buttons.
 * Uses SYSTEM_ALERT_WINDOW permission for overlay on top of all apps.
 * Auto-dismisses after 30s. Tapping "Answer" launches CinemaActivity with talk.
 *
 * V4 new: This didn't exist in V3. V3 hijacked the main UI for ring events.
 */
class DoorbellOverlayService : Service() {

    companion object {
        private const val TAG = "DoorbellOverlay"
        private const val OVERLAY_CHANNEL_ID = "doorbell_overlay"
        private const val FOREGROUND_NOTIFICATION_ID = 2001
        private const val AUTO_DISMISS_MS = 30000L
        private const val PREVIEW_POLL_MS = 500L
    }

    private var windowManager: WindowManager? = null
    private var overlayView: View? = null
    private val handler = Handler(Looper.getMainLooper())
    private var previewRunning = false
    private var previewThread: Thread? = null

    private val trustAllSslFactory: javax.net.ssl.SSLSocketFactory by lazy {
        val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        })
        val ctx = SSLContext.getInstance("TLS")
        ctx.init(null, trustAll, java.security.SecureRandom())
        ctx.socketFactory
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Check overlay permission
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            Log.w(TAG, "No overlay permission — cannot show popup")
            stopSelf()
            return START_NOT_STICKY
        }

        // Remove existing overlay if shown
        removeOverlay()

        // Start as foreground service
        startForegroundNotification()

        // Build and show the overlay
        val serverIp = intent?.getStringExtra("server_ip") ?: "10.10.10.167"
        val adminPort = intent?.getIntExtra("admin_port", 5000) ?: 5000
        val cameraId = intent?.getStringExtra("camera_id") ?: "doorbell_direct"
        val httpsEnabled = intent?.getBooleanExtra("https_enabled", false) ?: false

        showOverlay(serverIp, adminPort, cameraId, httpsEnabled)

        // Auto-dismiss after 30s
        handler.postDelayed({ dismissOverlay() }, AUTO_DISMISS_MS)

        return START_NOT_STICKY
    }

    private fun showOverlay(serverIp: String, adminPort: Int, cameraId: String, httpsEnabled: Boolean) {
        val inflater = LayoutInflater.from(this)

        // Build overlay programmatically (no XML layout needed for a simple popup)
        overlayView = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(0xE6121230.toInt()) // Dark semi-transparent
            setPadding(24, 24, 24, 24)

            // Title
            addView(TextView(context).apply {
                text = "Doorbell Ringing"
                setTextColor(0xFFE94560.toInt())
                textSize = 18f
                setPadding(0, 0, 0, 12)
            })

            // Camera preview
            val previewImage = ImageView(context).apply {
                layoutParams = LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT, 240
                )
                scaleType = ImageView.ScaleType.FIT_CENTER
                setBackgroundColor(0xFF000000.toInt())
            }
            addView(previewImage)

            // Start preview polling
            startPreviewPolling(previewImage, serverIp, adminPort, cameraId, httpsEnabled)

            // Button row
            val buttonRow = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                setPadding(0, 16, 0, 0)
                gravity = Gravity.CENTER
            }

            // View button (video only, no mic)
            val viewBtn = TextView(context).apply {
                text = "  View  "
                textSize = 16f
                setTextColor(0xFFFFFFFF.toInt())
                setBackgroundColor(0xFF3B82F6.toInt())
                setPadding(32, 16, 32, 16)
                setOnClickListener {
                    val intent = Intent(context, CinemaActivity::class.java).apply {
                        this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                        putExtra(CinemaActivity.EXTRA_ANSWER_DOORBELL, true)
                        putExtra(CinemaActivity.EXTRA_TALK_ENABLED, false)
                    }
                    startActivity(intent)
                    dismissOverlay()
                }
            }
            buttonRow.addView(viewBtn)

            // Spacer
            buttonRow.addView(View(context).apply {
                layoutParams = LinearLayout.LayoutParams(16, 1)
            })

            // Talk button (video + mic)
            val talkBtn = TextView(context).apply {
                text = "  Talk  "
                textSize = 16f
                setTextColor(0xFFFFFFFF.toInt())
                setBackgroundColor(0xFF4ADE80.toInt())
                setPadding(32, 16, 32, 16)
                setOnClickListener {
                    val intent = Intent(context, CinemaActivity::class.java).apply {
                        this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                        putExtra(CinemaActivity.EXTRA_ANSWER_DOORBELL, true)
                        putExtra(CinemaActivity.EXTRA_TALK_ENABLED, true)
                    }
                    startActivity(intent)
                    dismissOverlay()
                }
            }
            buttonRow.addView(talkBtn)

            // Spacer
            buttonRow.addView(View(context).apply {
                layoutParams = LinearLayout.LayoutParams(16, 1)
            })

            // Dismiss button
            val dismissBtn = TextView(context).apply {
                text = "  Dismiss  "
                textSize = 16f
                setTextColor(0xFFFFFFFF.toInt())
                setBackgroundColor(0xFF333355.toInt())
                setPadding(32, 16, 32, 16)
                setOnClickListener { dismissOverlay() }
            }
            buttonRow.addView(dismissBtn)

            addView(buttonRow)
        }

        val layoutType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        var windowFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        // FLAG_SHOW_WHEN_LOCKED and FLAG_TURN_SCREEN_ON are deprecated in API 27+.
        // TYPE_APPLICATION_OVERLAY already shows over the lock screen on API 26+.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O_MR1) {
            @Suppress("DEPRECATION")
            windowFlags = windowFlags or
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            layoutType,
            windowFlags,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = 64
        }

        try {
            windowManager?.addView(overlayView, params)
            Log.i(TAG, "Overlay shown")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show overlay: ${e.message}")
            stopSelf()
        }
    }

    private fun startPreviewPolling(
        imageView: ImageView,
        serverIp: String,
        adminPort: Int,
        cameraId: String,
        httpsEnabled: Boolean
    ) {
        previewRunning = true
        Thread({
            var errorCount = 0
            while (previewRunning) {
                try {
                    val protocol = if (httpsEnabled) "https" else "http"
                    val url = "$protocol://$serverIp:$adminPort/api/frame.jpeg?src=$cameraId&_t=${System.currentTimeMillis()}"
                    val conn = URL(url).openConnection()
                    if (conn is HttpsURLConnection) {
                        conn.sslSocketFactory = trustAllSslFactory
                        conn.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true }
                    }
                    conn.connectTimeout = 3000
                    conn.readTimeout = 5000

                    val inputStream: InputStream = conn.getInputStream()
                    val bitmap = BitmapFactory.decodeStream(inputStream)
                    inputStream.close()

                    if (bitmap != null) {
                        errorCount = 0
                        handler.post {
                            if (previewRunning) {
                                imageView.setImageBitmap(bitmap)
                            }
                        }
                    }
                } catch (e: Exception) {
                    errorCount++
                    if (errorCount > 10) break
                }

                try {
                    Thread.sleep(PREVIEW_POLL_MS)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }, "overlay-preview").apply {
            isDaemon = true
            start()
        }.also { previewThread = it }
    }

    private fun dismissOverlay() {
        handler.removeCallbacksAndMessages(null)
        previewRunning = false
        previewThread?.let { thread ->
            thread.interrupt()
            try { thread.join(500) } catch (_: InterruptedException) {}
        }
        previewThread = null
        removeOverlay()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun removeOverlay() {
        overlayView?.let {
            try {
                windowManager?.removeView(it)
            } catch (e: Exception) {
                Log.w(TAG, "Remove overlay failed: ${e.message}")
            }
            overlayView = null
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                OVERLAY_CHANNEL_ID,
                "Doorbell Overlay",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Persistent notification while doorbell overlay is active"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun startForegroundNotification() {
        val notification = NotificationCompat.Builder(this, OVERLAY_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Doorbell Active")
            .setContentText("Doorbell overlay is showing")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()

        startForeground(FOREGROUND_NOTIFICATION_ID, notification)
    }

    override fun onDestroy() {
        super.onDestroy()
        previewRunning = false
        removeOverlay()
        handler.removeCallbacksAndMessages(null)
    }
}
