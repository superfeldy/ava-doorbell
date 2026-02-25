package com.doorbell.ava

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.os.Build
import android.provider.Settings
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.view.animation.AlphaAnimation
import android.view.animation.Animation
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import okhttp3.OkHttpClient
import okhttp3.Request
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import androidx.media3.ui.PlayerView
import kotlin.math.sqrt

/**
 * CinemaActivity — Main launcher activity for AVA Doorbell v4.0
 *
 * V4 change: This is now a "cinema remote" first — the tablet's primary
 * purpose is displaying camera streams. Doorbell ring events trigger a
 * floating overlay popup (DoorbellOverlayService) rather than taking over
 * the main UI. The WebView loads the multiview page with all cameras.
 *
 * Key V4 changes from V3 MainActivity:
 * - Renamed from MainActivity → CinemaActivity (cinema remote first)
 * - Layout includes 8up/9up options (V3: only up to 6up)
 * - Swipe gestures for layout cycling
 * - Doorbell ring → starts DoorbellOverlayService instead of hijacking main UI
 * - forceReconnect flag check on resume (V3 bug: ConfigActivity couldn't reconnect)
 * - All existing V3 reliability features preserved (stall detection, MJPEG fallback, etc.)
 */
class CinemaActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "CinemaActivity"
        private const val CHANNEL_ID = "doorbell_ring"
        private const val NOTIFICATION_ID = 1001
        private const val PERMISSIONS_CODE = 100
        private const val MIC_PERMISSION_CODE = 101
        private const val LONG_PRESS_MS = 3000L
        private const val STALL_DETECT_MS = 8000L
        private const val MAX_CONN_ERRORS = 2
        private const val MAX_RECREATE_COOLDOWN = 3
        private const val GO2RTC_PORT = 1984
        private const val GO2RTC_RTSP_PORT = 8554
        private const val SWIPE_THRESHOLD = 150f
        const val EXTRA_ANSWER_DOORBELL = "com.doorbell.ava.ANSWER_DOORBELL"
        const val EXTRA_TALK_ENABLED = "com.doorbell.ava.TALK_ENABLED"
    }

    private lateinit var webView: WebView
    private lateinit var loadingOverlay: View
    private lateinit var touchOverlay: View
    private lateinit var statusDot: View
    private lateinit var mjpegPreview: ImageView
    private lateinit var playerView: PlayerView
    private lateinit var layoutIndicator: TextView
    private lateinit var swipeHint: TextView

    private var exoPlayer: ExoPlayer? = null
    private var rtspConnected = false

    @Volatile private var mjpegRunning = false
    private var mjpegThread: Thread? = null

    /**
     * OkHttp client for MJPEG snapshot polling (LAN only).
     * - connectTimeout: 5s (initial TCP handshake)
     * - readTimeout: 5s (each snapshot should complete in <100ms on LAN;
     *   5s catches stalls without triggering on slow starts)
     * - callTimeout: 10s (overall safety net)
     */
    private val mjpegHttpClient: OkHttpClient by lazy {
        val trustAll = arrayOf<TrustManager>(object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        })
        val sslCtx = SSLContext.getInstance("TLS")
        sslCtx.init(null, trustAll, java.security.SecureRandom())

        OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .callTimeout(10, TimeUnit.SECONDS)
            .sslSocketFactory(sslCtx.socketFactory, trustAll[0] as X509TrustManager)
            .hostnameVerifier { _, _ -> true }
            .build()
    }

    private lateinit var settingsManager: SettingsManager
    private lateinit var mqttManager: MqttManager
    private lateinit var micFab: ImageView
    private lateinit var idleManager: IdleManager
    private var nativeTalkManager: NativeTalkManager? = null

    private var mediaPlayer: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    private var longPressStartTime = 0L
    private var lastTouchX = 0f
    private var lastTouchY = 0f
    private var touchStartX = 0f  // V4: swipe gesture tracking

    private var lastProgress = 0
    private var progressStallRunnable: Runnable? = null
    private var connectionErrorCount = 0
    private var hadMainFrameError = false
    private var recreateAttempts = 0
    private var totalWebViewFailures = 0
    private var mjpegOnlyMode = false
    private val isMediaTek = Build.HARDWARE.contains("mt", ignoreCase = true) ||
                             Build.BOARD.contains("mt", ignoreCase = true)
    private var showingCachedStill = false  // MJPEG preview kept visible as still while WebView loads
    private var answerIntentHandled = false
    private var mjpegOnlyRetryRunnable: Runnable? = null
    private var layoutIndicatorRunnable: Runnable? = null

    // V4: Layout cycling via swipe
    private val layoutSizes = arrayOf("single", "2up", "4up", "6up", "8up", "9up")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "=== onCreate() ===")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                WebView.setDataDirectorySuffix("ava")
            } catch (e: Exception) {
                Log.w(TAG, "setDataDirectorySuffix failed: ${e.message}")
            }
        }

        // Removed enableSlowWholeDocumentDraw() — it forces full-page rendering
        // into a single GPU texture, wasting GPU memory on video-heavy pages.
        // The default tiled rendering is more efficient for MediaTek GPUs.
        setContentView(R.layout.activity_cinema)

        settingsManager = SettingsManager(this)
        idleManager = IdleManager(this) { moveTaskToBack(true) }
        mqttManager = MqttManager(this, ::onMqttConnectionStateChanged, ::onDoorbellRing, ::onMotionEvent)

        createNotificationChannel()
        initializeViews()
        setupImmersiveMode()
        configureWebView()
        setupTouchOverlay()

        // Connect MQTT early — don't wait for onResume() which may be delayed
        // by permission dialogs on fresh install.
        mqttManager.connect(
            serverIp = settingsManager.getServerIp(),
            port = settingsManager.getMqttPort()
        )

        requestPermissions()
        requestOverlayPermission()

        // MediaTek chipsets have a known WebView multiprocess bug where the
        // renderer process fails to start (cr_ChildProcessConn errors).
        // Detect MediaTek and skip straight to MJPEG-only mode on first launch
        // instead of wasting ~18s on 3 doomed WebView attempts.
        if (isMediaTek) {
            Log.i(TAG, "MediaTek chipset detected (${Build.HARDWARE}/${Build.BOARD}) — using MJPEG-only mode")
        }

        val persistedFailures = settingsManager.getWebViewFailureCount()
        if (isMediaTek || persistedFailures >= 3) {
            if (!isMediaTek) {
                Log.w(TAG, "WebView has failed $persistedFailures times across sessions — starting in MJPEG-only mode")
            }
            mjpegOnlyMode = true
            webView.visibility = View.GONE
            webView.post {
                startMjpegPreview()
                hideLoadingOverlay()
            }
            // On MediaTek, don't bother retrying — WebView multiprocess never works.
            // On other chipsets, try again after 10 minutes in case it was transient.
            if (!isMediaTek) {
                mjpegOnlyRetryRunnable?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
                mjpegOnlyRetryRunnable = Runnable {
                    Log.i(TAG, "Attempting WebView retry after persistent-failure cooldown")
                    mjpegOnlyMode = false
                    totalWebViewFailures = 0
                    webView.visibility = View.VISIBLE
                    loadWebViewContent()
                }
                Handler(Looper.getMainLooper()).postDelayed(mjpegOnlyRetryRunnable!!, 10 * 60 * 1000L)
            }
        } else {
            webView.post {
                loadWebViewContent()
                // Only start native video if in single layout — multi-up uses WebView
                if (settingsManager.getDefaultLayout() == "single") {
                    startMjpegPreview()
                } else {
                    playerView.visibility = View.GONE
                    mjpegPreview.visibility = View.GONE
                    Log.i(TAG, "Starting in multiview layout: ${settingsManager.getDefaultLayout()}")
                }
            }
        }

        // Show swipe hint so users discover the layout switching gesture
        showSwipeHint()
    }

    private fun initializeViews() {
        webView = findViewById(R.id.web_view)
        loadingOverlay = findViewById(R.id.loading_overlay)
        touchOverlay = findViewById(R.id.touch_overlay)
        statusDot = findViewById(R.id.status_dot)
        mjpegPreview = findViewById(R.id.mjpeg_preview)
        playerView = findViewById(R.id.player_view)
        micFab = findViewById(R.id.mic_fab)
        micFab.visibility = View.VISIBLE
        layoutIndicator = findViewById(R.id.layout_indicator)
        swipeHint = findViewById(R.id.swipe_hint)

        micFab.setOnClickListener { toggleNativeTalk() }
    }

    private fun setupImmersiveMode() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.statusBars() or WindowInsetsCompat.Type.navigationBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
        window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun configureWebView() {
        val isDebuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (isDebuggable) {
            WebView.setWebContentsDebuggingEnabled(true)
        }

        webView.apply {
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                mediaPlaybackRequiresUserGesture = false
                mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
                allowContentAccess = true
                allowFileAccess = true
                loadWithOverviewMode = true
                useWideViewPort = true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    safeBrowsingEnabled = false
                }
            }

            // Don't set LAYER_TYPE_HARDWARE — it forces an extra offscreen GPU texture
            // that doubles memory/GPU usage. The activity already has hardware acceleration
            // enabled via the manifest. On weak MediaTek GPUs, the extra layer causes
            // GPUAUX buffer exhaustion and crashes.
            setLayerType(View.LAYER_TYPE_NONE, null)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setRendererPriorityPolicy(WebView.RENDERER_PRIORITY_IMPORTANT, false)
            }

            // Clear HTTP cache on startup for MediaTek only — their WebView
            // renderer process fails to start when cache grows large (54MB+).
            // Non-MediaTek devices keep cache for faster subsequent loads.
            if (isMediaTek) {
                clearCache(true)
            }

            isFocusable = true
            isFocusableInTouchMode = true
            requestFocus()

            webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest) {
                    request.grant(request.resources)
                }

                override fun onConsoleMessage(consoleMessage: android.webkit.ConsoleMessage?): Boolean {
                    consoleMessage?.let { msg ->
                        val level = msg.messageLevel()
                        if (level == android.webkit.ConsoleMessage.MessageLevel.WARNING ||
                            level == android.webkit.ConsoleMessage.MessageLevel.ERROR) {
                            Log.w(TAG, "WebView console [${level}]: ${msg.message()}")
                        }
                    }
                    return true
                }

                override fun onProgressChanged(view: WebView?, newProgress: Int) {
                    super.onProgressChanged(view, newProgress)
                    if (newProgress == 10 || newProgress == 50 || newProgress == 80 || newProgress == 100) {
                        Log.d(TAG, "WebView loading progress: $newProgress%")
                    }
                    lastProgress = newProgress

                    if (newProgress >= 30 && !hadMainFrameError) {
                        cancelStallDetection()
                        connectionErrorCount = 0
                        recreateAttempts = 0
                        totalWebViewFailures = 0
                        // WebView loaded successfully — reset persisted failure count
                        // so next cold start will try WebView first again.
                        settingsManager.setWebViewFailureCount(0)
                    }

                    if (newProgress >= 80) {
                        hideLoadingOverlay()
                        // Hide cached still frame once WebView multiview has loaded
                        if (showingCachedStill) {
                            showingCachedStill = false
                            mjpegPreview.visibility = View.GONE
                            Log.d(TAG, "WebView loaded — hiding cached still")
                        }
                    }
                }
            }

            webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                    super.onPageStarted(view, url, favicon)
                    hadMainFrameError = false
                    showLoadingOverlay()
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    super.onPageFinished(view, url)
                    hideLoadingOverlay()
                    // Hide cached still frame if still showing
                    if (showingCachedStill) {
                        showingCachedStill = false
                        mjpegPreview.visibility = View.GONE
                        Log.d(TAG, "Page finished — hiding cached still")
                    }
                    // Hide the web-based talk button — native mic FAB handles talk
                    view?.evaluateJavascript(
                        "document.getElementById('btn-talk')?.remove();"
                    ) { }
                }

                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                    return false
                }

                override fun onReceivedError(
                    view: WebView?,
                    request: WebResourceRequest?,
                    error: WebResourceError?
                ) {
                    super.onReceivedError(view, request, error)
                    val isMainFrame = request?.isForMainFrame ?: false
                    if (isMainFrame) {
                        Log.e(TAG, "onReceivedError: code=${error?.errorCode}, desc=${error?.description}")
                        cancelStallDetection()
                        hadMainFrameError = true
                        connectionErrorCount++

                        if (connectionErrorCount >= MAX_CONN_ERRORS) {
                            Log.e(TAG, "Server unreachable — retrying in 15s")
                            connectionErrorCount = 0
                            hideLoadingOverlay()
                            Toast.makeText(this@CinemaActivity, "Server unreachable — retrying...", Toast.LENGTH_LONG).show()
                            view?.postDelayed({ loadWebViewContent() }, 15000)
                        } else {
                            Toast.makeText(this@CinemaActivity, "Connecting... (attempt ${connectionErrorCount + 1})", Toast.LENGTH_SHORT).show()
                            view?.postDelayed({
                                webView.stopLoading()
                                webView.loadUrl(buildViewUrl())
                            }, 3000)
                        }
                    }
                }

                override fun onReceivedHttpError(
                    view: WebView?, request: WebResourceRequest?, errorResponse: WebResourceResponse?
                ) {
                    super.onReceivedHttpError(view, request, errorResponse)
                    val isMainFrame = request?.isForMainFrame ?: false
                    if (isMainFrame) {
                        Log.e(TAG, "HTTP error: status=${errorResponse?.statusCode}")
                    }
                }

                override fun onReceivedSslError(view: WebView?, handler: android.webkit.SslErrorHandler?, error: android.net.http.SslError?) {
                    val url = error?.url ?: ""
                    val isLocal = url.contains("10.10.10.") || url.contains("192.168.") || url.contains("127.0.0.1") || url.contains("localhost")

                    if (isLocal) {
                        // Accept self-signed certs on local network (LAN-only deployment)
                        Log.d(TAG, "Accepting self-signed cert for local URL: $url")
                        handler?.proceed()
                    } else {
                        handler?.cancel()
                    }
                }

                @RequiresApi(Build.VERSION_CODES.O)
                override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                    Log.e(TAG, "WebView RENDERER CRASHED! (total failures: ${totalWebViewFailures + 1})")
                    totalWebViewFailures++
                    runOnUiThread {
                        startMjpegPreview()
                        if (totalWebViewFailures >= 3) {
                            Log.w(TAG, "Renderer keeps crashing — switching to MJPEG-only mode")
                            enterMjpegOnlyMode()
                        } else {
                            Toast.makeText(this@CinemaActivity, "Reloading camera view...", Toast.LENGTH_SHORT).show()
                            recreateWebView(3000L)
                        }
                    }
                    return true
                }
            }
        }
    }

    private var longPressRunnable: Runnable? = null

    private fun setupTouchOverlay() {
        touchOverlay.setOnTouchListener { _, event ->
            try {
                val copy = MotionEvent.obtain(event)
                webView.dispatchTouchEvent(copy)
                copy.recycle()
            } catch (e: Exception) {
                Log.w(TAG, "Touch forwarding failed: ${e.message}")
            }

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    idleManager.onTouchEvent()  // Reset idle timers on any touch
                    longPressStartTime = System.currentTimeMillis()
                    lastTouchX = event.x
                    lastTouchY = event.y
                    touchStartX = event.x  // V4: swipe tracking

                    longPressRunnable = Runnable { openConfigActivity() }
                    touchOverlay.postDelayed(longPressRunnable!!, LONG_PRESS_MS)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.x - lastTouchX
                    val dy = event.y - lastTouchY
                    val distance = sqrt((dx * dx + dy * dy).toDouble())
                    if (distance > 50) {
                        longPressRunnable?.let { touchOverlay.removeCallbacks(it) }
                        longPressRunnable = null
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    longPressRunnable?.let { touchOverlay.removeCallbacks(it) }
                    longPressRunnable = null

                    // V4: Detect horizontal swipe for layout cycling
                    val swipeX = event.x - touchStartX
                    if (kotlin.math.abs(swipeX) > SWIPE_THRESHOLD) {
                        // Dismiss swipe hint immediately — user discovered the gesture
                        if (swipeHint.visibility == View.VISIBLE) {
                            swipeHint.clearAnimation()
                            swipeHint.visibility = View.GONE
                        }
                        val currentLayout = settingsManager.getDefaultLayout()
                        val currentIdx = layoutSizes.indexOf(currentLayout).coerceAtLeast(0)
                        val nextIdx = if (swipeX < 0) {
                            // Swipe left → next layout (wrap around)
                            (currentIdx + 1) % layoutSizes.size
                        } else {
                            // Swipe right → previous layout (wrap around)
                            (currentIdx - 1 + layoutSizes.size) % layoutSizes.size
                        }
                        switchToLayout(layoutSizes[nextIdx])
                    }

                    touchOverlay.performClick()
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    longPressRunnable?.let { touchOverlay.removeCallbacks(it) }
                    longPressRunnable = null
                    true
                }
                else -> true
            }
        }
    }

    private fun openConfigActivity() {
        startActivity(Intent(this, ConfigActivity::class.java))
    }

    /**
     * Switch layout and toggle native video vs WebView multiview visibility.
     * - "single" layout: native video (ExoPlayer/MJPEG) on top for best quality
     * - Multi-up layouts: hide native video, show WebView multiview grid
     *
     * Shows a layout indicator overlay and keeps the last MJPEG frame visible
     * as a cached still while the WebView multiview grid loads.
     */
    private fun switchToLayout(layout: String) {
        settingsManager.setDefaultLayout(layout)
        showLayoutIndicator(layout)

        if (layout == "single") {
            // Single camera: native video provides primary feed
            showingCachedStill = false
            playerView.visibility = View.VISIBLE
            mjpegPreview.visibility = View.VISIBLE
            if (exoPlayer == null && !mjpegRunning) {
                startNativeVideo()
            }
            webView.evaluateJavascript(
                "if(typeof window.switchLayout==='function') window.switchLayout('$layout');"
            ) { }
            Log.i(TAG, "Layout: single — native video on top")
        } else {
            // Multi-camera: hide native video overlays, show WebView multiview grid.
            // Don't show a single-camera cached still on top — it would cover
            // the entire multiview grid. Let the WebView cells load individually
            // (each cell has a black background until its MJPEG stream starts).
            stopNativeVideo()
            playerView.visibility = View.GONE
            mjpegPreview.visibility = View.GONE
            showingCachedStill = false

            // On MediaTek, WebView multiprocess never works — stay in single MJPEG.
            // Snap back to single layout instead of loading a doomed WebView.
            if (isMediaTek) {
                Log.w(TAG, "Layout: $layout requested but MediaTek — forcing single (WebView unavailable)")
                settingsManager.setDefaultLayout("single")
                showLayoutIndicator("single")
                playerView.visibility = View.VISIBLE
                mjpegPreview.visibility = View.VISIBLE
                if (exoPlayer == null && !mjpegRunning) {
                    startNativeVideo()
                }
                return
            }

            // Ensure WebView is visible and loaded — it may be GONE if device
            // entered mjpegOnlyMode due to past WebView renderer crashes.
            if (webView.visibility != View.VISIBLE) {
                Log.i(TAG, "Restoring WebView for multiview (was ${if (mjpegOnlyMode) "mjpegOnly" else "hidden"})")
                mjpegOnlyMode = false
                settingsManager.setWebViewFailureCount(0)
                webView.visibility = View.VISIBLE
                loadWebViewContent()
            } else {
                webView.evaluateJavascript(
                    "if(typeof window.switchLayout==='function') window.switchLayout('$layout');"
                ) { }
            }
            Log.i(TAG, "Layout: $layout — WebView multiview visible")
        }
    }

    /**
     * Show a brief layout name indicator in the center of the screen, then fade out.
     */
    private fun showLayoutIndicator(layout: String) {
        val displayName = when (layout) {
            "single" -> "SINGLE"
            "2up" -> "2-UP"
            "4up" -> "4-UP"
            "6up" -> "6-UP"
            "8up" -> "8-UP"
            "9up" -> "9-UP"
            else -> layout.uppercase()
        }

        // Cancel any pending fade-out from previous swipe
        layoutIndicatorRunnable?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
        layoutIndicator.clearAnimation()

        layoutIndicator.text = displayName
        layoutIndicator.alpha = 1f
        layoutIndicator.visibility = View.VISIBLE

        // Fade out after 1.5 seconds
        layoutIndicatorRunnable = Runnable {
            val fadeOut = AlphaAnimation(1f, 0f).apply {
                duration = 500
                fillAfter = true
                setAnimationListener(object : Animation.AnimationListener {
                    override fun onAnimationStart(animation: Animation?) {}
                    override fun onAnimationRepeat(animation: Animation?) {}
                    override fun onAnimationEnd(animation: Animation?) {
                        layoutIndicator.visibility = View.GONE
                        layoutIndicator.alpha = 1f
                    }
                })
            }
            layoutIndicator.startAnimation(fadeOut)
        }
        Handler(Looper.getMainLooper()).postDelayed(layoutIndicatorRunnable!!, 1500)
    }

    /**
     * Show a brief "swipe to change layout" hint on startup so users
     * discover the swipe gesture. Appears after 2s, fades out after 4s.
     */
    private var swipeHintShowRunnable: Runnable? = null
    private var swipeHintFadeRunnable: Runnable? = null

    private fun showSwipeHint() {
        val handler = Handler(Looper.getMainLooper())
        swipeHintFadeRunnable = Runnable {
            val fadeOut = AlphaAnimation(1f, 0f).apply {
                duration = 1000
                fillAfter = true
                setAnimationListener(object : Animation.AnimationListener {
                    override fun onAnimationStart(animation: Animation?) {}
                    override fun onAnimationRepeat(animation: Animation?) {}
                    override fun onAnimationEnd(animation: Animation?) {
                        swipeHint.visibility = View.GONE
                        swipeHint.alpha = 1f
                    }
                })
            }
            swipeHint.startAnimation(fadeOut)
        }
        swipeHintShowRunnable = Runnable {
            swipeHint.alpha = 1f
            swipeHint.visibility = View.VISIBLE
            handler.postDelayed(swipeHintFadeRunnable!!, 4000)
        }
        handler.postDelayed(swipeHintShowRunnable!!, 2000)
    }

    private fun buildViewUrl(): String {
        val serverIp = settingsManager.getServerIp()
        val adminPort = settingsManager.getAdminPort()
        val defaultCamera = settingsManager.getDefaultCamera()
        val defaultLayout = settingsManager.getDefaultLayout()
        // Always use HTTP for WebView — Android WebView can't trust self-signed
        // certs for sub-resources (JS/CSS), causing stalls. The native app doesn't
        // need HTTPS for microphone access (handled natively).
        // Force MJPEG mode in the web page — MSE/WebRTC triggers MediaCodec +
        // GPU flush storms on MediaTek hardware that crash the video decoder.
        // The native MJPEG stream overlay provides the primary video feed;
        // the web page's MJPEG is a secondary display for multi-camera layouts.
        // Only pass camera= for single layout — for multi-up the JS uses
        // server-configured camera assignments. Passing camera= would override
        // the layout and force a single-camera grid.
        val base = "http://$serverIp:$adminPort/view?layout=$defaultLayout&mode=mjpeg"
        return if (defaultLayout == "single") "$base&camera=$defaultCamera" else base
    }

    private var lastLoadedUrl: String? = null

    private fun loadWebViewContent() {
        if (mjpegOnlyMode) {
            Log.i(TAG, "MJPEG-only mode active — skipping WebView load")
            startMjpegPreview()
            hideLoadingOverlay()
            return
        }

        val url = buildViewUrl()
        lastLoadedUrl = url
        lastProgress = 0
        hadMainFrameError = false

        webView.stopLoading()

        try {
            webView.loadUrl(url)
        } catch (e: Exception) {
            Log.e(TAG, "Exception calling loadUrl(): ${e.message}", e)
        }

        startStallDetection()

        webView.postDelayed({
            if (loadingOverlay.visibility == View.VISIBLE) {
                Log.w(TAG, "Force-hiding loading overlay (8s timeout)")
                hideLoadingOverlay()
            }
        }, 8000)
    }

    private fun startStallDetection() {
        cancelStallDetection()
        progressStallRunnable = Runnable {
            if (lastProgress < 30) {
                totalWebViewFailures++
                Log.w(TAG, "WebView STALLED at ${lastProgress}% (attempt ${recreateAttempts + 1}, total failures: $totalWebViewFailures)")

                // Show MJPEG fallback immediately on stall
                startMjpegPreview()

                // If WebView renderer keeps failing (MediaTek multiprocess bug),
                // stop retrying and stay in MJPEG-only mode.
                // 2 stalls = ~18s — fast enough to not annoy the user.
                if (totalWebViewFailures >= 2) {
                    Log.w(TAG, "WebView renderer repeatedly failing — switching to MJPEG-only mode")
                    enterMjpegOnlyMode()
                    return@Runnable
                }

                if (recreateAttempts < MAX_RECREATE_COOLDOWN) {
                    recreateAttempts++

                    if (recreateAttempts <= 2) {
                        Log.d(TAG, "Attempting reload (attempt $recreateAttempts)")
                        webView.clearCache(false)
                        webView.stopLoading()
                        val delay = if (recreateAttempts == 1) 2000L else 5000L
                        Handler(Looper.getMainLooper()).postDelayed({
                            loadWebViewContent()
                        }, delay)
                    } else {
                        Log.d(TAG, "Escalating to full WebView recreate")
                        recreateWebView(5000L)
                    }
                } else {
                    Log.w(TAG, "WebView failed after $recreateAttempts attempts — cooling down 30s")
                    recreateAttempts = 0
                    hideLoadingOverlay()
                    showRetryOverlay()
                }
            }
        }
        webView.postDelayed(progressStallRunnable!!, STALL_DETECT_MS)
    }

    private fun cancelStallDetection() {
        progressStallRunnable?.let {
            webView.removeCallbacks(it)
            progressStallRunnable = null
        }
    }

    private fun recreateWebView(preLoadDelayMs: Long = 2000L) {
        Log.w(TAG, "Recreating WebView (${preLoadDelayMs}ms delay)")
        startMjpegPreview()

        val parent = webView.parent as? android.view.ViewGroup ?: return
        val index = parent.indexOfChild(webView)
        val lp = webView.layoutParams

        cancelStallDetection()
        webView.stopLoading()
        parent.removeViewAt(index)
        webView.destroy()

        webView = WebView(this).apply {
            id = R.id.web_view
            layoutParams = lp
        }
        parent.addView(webView, index)

        configureWebView()

        Handler(Looper.getMainLooper()).postDelayed({
            loadWebViewContent()
        }, preLoadDelayMs)
    }

    private fun showRetryOverlay() {
        Toast.makeText(this, "Camera view unavailable — retrying in 30s", Toast.LENGTH_LONG).show()
        Handler(Looper.getMainLooper()).postDelayed({
            Log.w(TAG, "30s cooldown complete — recreating WebView")
            recreateWebView(3000L)
        }, 30000)
    }

    /**
     * Switch to MJPEG-only mode: hide WebView, persist failure count,
     * and schedule a single retry after 5 minutes.
     * Cancels any previously scheduled retry to prevent stacking.
     */
    private fun enterMjpegOnlyMode() {
        mjpegOnlyMode = true
        recreateAttempts = 0
        cancelStallDetection()
        webView.stopLoading()
        webView.clearCache(true)
        webView.visibility = View.GONE
        hideLoadingOverlay()
        startMjpegPreview()

        val persisted = settingsManager.getWebViewFailureCount() + 1
        settingsManager.setWebViewFailureCount(persisted)
        Log.w(TAG, "Entered MJPEG-only mode (persisted failure count: $persisted)")

        Toast.makeText(this@CinemaActivity, "Using camera preview mode", Toast.LENGTH_SHORT).show()

        // Cancel any previously scheduled WebView retry to prevent stacking
        mjpegOnlyRetryRunnable?.let { Handler(Looper.getMainLooper()).removeCallbacks(it) }
        mjpegOnlyRetryRunnable = Runnable {
            Log.i(TAG, "Retrying WebView after MJPEG-only cooldown")
            mjpegOnlyMode = false
            totalWebViewFailures = 0
            webView.visibility = View.VISIBLE
            loadWebViewContent()
        }
        Handler(Looper.getMainLooper()).postDelayed(mjpegOnlyRetryRunnable!!, 5 * 60 * 1000L)
    }

    // =========================================================================
    // NATIVE VIDEO PLAYBACK (ExoPlayer RTSP → MJPEG fallback)
    // =========================================================================

    /**
     * Start native video playback via ExoPlayer RTSP.
     *
     * Connects to go2rtc's RTSP re-stream (port 8554) which provides true H.264/H.265
     * video via a single hardware decoder — no WebView, no MediaCodec conflicts.
     * Falls back to MJPEG snapshot polling if RTSP fails.
     */
    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun startNativeVideo() {
        if (exoPlayer != null) return  // already running
        Log.i(TAG, "Starting native RTSP video")

        stopMjpegFallback()  // stop any running MJPEG

        val rtspUrl = buildRtspUrl()
        Log.i(TAG, "RTSP URL: $rtspUrl")

        val player = ExoPlayer.Builder(this).build()
        player.setVideoScalingMode(android.media.MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)

        val mediaItem = MediaItem.fromUri(rtspUrl)
        val rtspSource = RtspMediaSource.Factory()
            .setForceUseRtpTcp(true)  // TCP interleaved — more reliable on LAN
            .createMediaSource(mediaItem)

        player.setMediaSource(rtspSource)
        player.playWhenReady = true
        player.volume = 0f  // muted — audio is handled separately

        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_READY -> {
                        Log.i(TAG, "ExoPlayer RTSP: playing")
                        rtspConnected = true
                        playerView.visibility = View.VISIBLE
                        mjpegPreview.visibility = View.GONE
                        hideLoadingOverlay()
                    }
                    Player.STATE_BUFFERING -> {
                        Log.d(TAG, "ExoPlayer RTSP: buffering")
                    }
                    Player.STATE_ENDED -> {
                        Log.w(TAG, "ExoPlayer RTSP: stream ended")
                        rtspConnected = false
                        scheduleRtspReconnect()
                    }
                    Player.STATE_IDLE -> {
                        // no-op
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e(TAG, "ExoPlayer RTSP error: ${error.message} (code=${error.errorCode})")
                rtspConnected = false
                // Fall back to MJPEG
                releaseExoPlayer()
                startMjpegFallback()
            }
        })

        playerView.player = player
        playerView.visibility = View.VISIBLE
        exoPlayer = player
        player.prepare()
    }

    /**
     * Release ExoPlayer and hide the player view.
     */
    private fun releaseExoPlayer() {
        exoPlayer?.let { player ->
            playerView.player = null
            player.release()
        }
        exoPlayer = null
        rtspConnected = false
        playerView.visibility = View.GONE
    }

    /**
     * Schedule an RTSP reconnect after a brief delay.
     */
    private fun scheduleRtspReconnect() {
        releaseExoPlayer()
        Handler(Looper.getMainLooper()).postDelayed({
            if (!mjpegRunning) {  // don't reconnect if already fell back to MJPEG
                startNativeVideo()
            }
        }, 3000)
    }

    /**
     * MJPEG fallback: snapshot polling from go2rtc when ExoPlayer RTSP fails.
     * Slower but always works.
     */
    private fun startMjpegFallback() {
        if (mjpegRunning) return
        mjpegRunning = true
        mjpegPreview.visibility = View.VISIBLE
        playerView.visibility = View.GONE
        Log.i(TAG, "MJPEG fallback: starting snapshot polling")

        mjpegThread = Thread({
            var consecutiveErrors = 0
            var frameCount = 0
            var lastLogTime = System.currentTimeMillis()

            while (mjpegRunning) {
                try {
                    val frameUrl = buildFrameUrl()
                    val request = Request.Builder().url(frameUrl).build()

                    mjpegHttpClient.newCall(request).execute().use { response ->
                        val body = response.body
                        if (response.isSuccessful && body != null) {
                            val bitmap = BitmapFactory.decodeStream(body.byteStream())
                            if (bitmap != null) {
                                frameCount++
                                consecutiveErrors = 0
                                runOnUiThread {
                                    if (mjpegRunning) {
                                        mjpegPreview.setImageBitmap(bitmap)
                                    }
                                }
                            } else {
                                consecutiveErrors++
                            }
                        } else {
                            consecutiveErrors++
                        }
                    }
                } catch (e: Exception) {
                    if (!mjpegRunning) break
                    if (Thread.currentThread().isInterrupted) break
                    consecutiveErrors++
                    if (consecutiveErrors <= 3 || consecutiveErrors % 20 == 0) {
                        Log.w(TAG, "MJPEG fallback error #$consecutiveErrors: ${e.message}")
                    }
                }

                val now = System.currentTimeMillis()
                if (now - lastLogTime >= 10000) {
                    val fps = frameCount * 1000.0 / (now - lastLogTime)
                    Log.d(TAG, "MJPEG fallback: %.1f fps".format(fps))
                    frameCount = 0
                    lastLogTime = now
                }

                // Cap at ~15 fps on success to avoid spinning at 200+ fps on LAN
                // (go2rtc returns frames in <5ms, which saturates CPU/battery)
                val sleepMs = if (consecutiveErrors > 0) {
                    when {
                        consecutiveErrors <= 3 -> 500L
                        consecutiveErrors <= 10 -> 2000L
                        consecutiveErrors <= 30 -> 5000L
                        else -> 15000L
                    }
                } else {
                    66L // ~15 fps cap
                }
                try { Thread.sleep(sleepMs) } catch (_: InterruptedException) { break }
            }
            Log.d(TAG, "MJPEG fallback thread exiting")
        }, "mjpeg-fallback")
        mjpegThread!!.isDaemon = true
        mjpegThread!!.start()

        // Retry RTSP after 60s of MJPEG fallback
        Handler(Looper.getMainLooper()).postDelayed({
            if (mjpegRunning && exoPlayer == null) {
                Log.i(TAG, "Retrying RTSP after MJPEG fallback period")
                stopMjpegFallback()
                startNativeVideo()
            }
        }, 60_000)
    }

    private fun stopMjpegFallback() {
        mjpegRunning = false
        mjpegThread?.let { thread ->
            thread.interrupt()
            try { thread.join(500) } catch (_: InterruptedException) {}
        }
        mjpegThread = null
        mjpegPreview.visibility = View.GONE
    }

    /**
     * Stop all native video (ExoPlayer + MJPEG fallback).
     */
    private fun stopNativeVideo() {
        releaseExoPlayer()
        stopMjpegFallback()
    }

    // Aliases used by existing code paths (onCreate, enterMjpegOnlyMode, etc.)
    private fun startMjpegPreview() = startNativeVideo()
    private fun hideMjpegPreview() = stopNativeVideo()

    private fun buildRtspUrl(): String {
        val serverIp = settingsManager.getServerIp()
        val defaultCamera = settingsManager.getDefaultCamera()
        // go2rtc RTSP re-stream — single hardware decoder, true video
        return "rtsp://$serverIp:$GO2RTC_RTSP_PORT/$defaultCamera"
    }

    private fun buildFrameUrl(): String {
        val serverIp = settingsManager.getServerIp()
        val defaultCamera = settingsManager.getDefaultCamera()
        // go2rtc snapshot endpoint — slow (decodes on demand), used as MJPEG fallback
        return "http://$serverIp:$GO2RTC_PORT/api/frame.jpeg?src=$defaultCamera"
    }

    private fun showLoadingOverlay() {
        loadingOverlay.visibility = View.VISIBLE
    }

    private fun hideLoadingOverlay() {
        loadingOverlay.visibility = View.GONE
    }

    // =========================================================================
    // MQTT & DOORBELL
    // =========================================================================

    private fun onMqttConnectionStateChanged(connected: Boolean) {
        runOnUiThread {
            val color = if (connected) android.graphics.Color.GREEN else android.graphics.Color.RED
            statusDot.backgroundTintList = android.content.res.ColorStateList.valueOf(color)
        }
    }

    /** Camera motion detected via MQTT — reset idle timer. */
    private fun onMotionEvent() {
        idleManager.onMotionDetected()
    }

    /**
     * V4: Ring event triggers DoorbellOverlayService (floating popup) instead of
     * taking over the main camera view. The overlay shows a preview + answer/dismiss.
     */
    private fun onDoorbellRing() {
        Log.i(TAG, "=== DOORBELL RING EVENT ===")
        idleManager.onDoorbellRing()
        runOnUiThread {
            Log.i(TAG, "onDoorbellRing: playing chime, overlay=${settingsManager.isOverlayEnabled()}")
            playChimeSound()
            triggerVibration()

            // Tell WebView about the ring event (switches to doorbell camera)
            val cameraId = settingsManager.getDefaultCamera()
            webView.evaluateJavascript(
                "if(typeof onRingEvent==='function') onRingEvent('$cameraId');"
            ) { }

            // V4: Start the floating overlay if enabled — it has its own foreground
            // notification, so skip the standalone notification to avoid duplicates.
            if (settingsManager.isOverlayEnabled()) {
                val overlayIntent = Intent(this, DoorbellOverlayService::class.java).apply {
                    putExtra("server_ip", settingsManager.getServerIp())
                    putExtra("admin_port", settingsManager.getAdminPort())
                    putExtra("camera_id", settingsManager.getDefaultCamera())
                    putExtra("https_enabled", false)
                }
                try {
                    // Android O+ requires startForegroundService for services that
                    // call startForeground(). Android 12+ (API 31) throws
                    // BackgroundServiceStartNotAllowedException if the app is in
                    // the background and we use plain startService().
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(overlayIntent)
                    } else {
                        startService(overlayIntent)
                    }
                } catch (e: Exception) {
                    // Android 12+ may still throw if app is fully backgrounded
                    // and doesn't have a foreground-service exemption. Fall back
                    // to a standard high-priority notification.
                    Log.w(TAG, "Cannot start overlay service (background restriction): ${e.message}")
                    showDoorbellNotification()
                }
            } else {
                // No overlay — show standalone notification with answer actions
                showDoorbellNotification()
            }
        }
    }

    private fun playChimeSound() {
        if (!settingsManager.isChimeEnabled()) return
        try {
            mediaPlayer?.release()
            mediaPlayer = null

            // Build MediaPlayer manually so we can set audio attributes BEFORE
            // prepare(). MediaPlayer.create() returns a player already in
            // Prepared state, and setAudioAttributes() is invalid after prepare
            // (causes "trying to set audio attributes called in state 8" error).
            val chimeAttrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

            val mp = MediaPlayer().apply {
                setAudioAttributes(chimeAttrs)
                setOnCompletionListener { it.release() }
            }

            // Open the raw resource and set as data source
            val afd = resources.openRawResourceFd(R.raw.doorbell_chime)
            if (afd != null) {
                mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                afd.close()
                mp.prepare()

                // Max out alarm volume so chime is audible
                val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
                val maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_ALARM)
                audioManager.setStreamVolume(AudioManager.STREAM_ALARM, maxVol, 0)

                mp.start()
                mediaPlayer = mp
            } else {
                mp.release()
                Log.w(TAG, "Could not open doorbell_chime raw resource")
            }

            if (mediaPlayer == null) {
                val ringtoneUri = android.media.RingtoneManager.getDefaultUri(
                    android.media.RingtoneManager.TYPE_NOTIFICATION
                )
                android.media.RingtoneManager.getRingtone(this, ringtoneUri)?.play()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error playing chime", e)
        }
    }

    @Suppress("DEPRECATION")
    private fun triggerVibration() {
        if (!settingsManager.isVibrationEnabled()) return
        try {
            if (vibrator == null) {
                vibrator = getSystemService(VIBRATOR_SERVICE) as Vibrator
            }
            val pattern = longArrayOf(0, 300, 200, 300, 200, 600)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, -1))
            } else {
                vibrator?.vibrate(pattern, -1)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error vibrating", e)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Doorbell Ring",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Doorbell ring notifications"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 300, 200, 300, 200, 600)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun showDoorbellNotification() {
        try {
            val viewIntent = Intent(this, CinemaActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_ANSWER_DOORBELL, true)
                putExtra(EXTRA_TALK_ENABLED, false)
            }
            val viewPending = PendingIntent.getActivity(
                this, 0, viewIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val talkIntent = Intent(this, CinemaActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(EXTRA_ANSWER_DOORBELL, true)
                putExtra(EXTRA_TALK_ENABLED, true)
            }
            val talkPending = PendingIntent.getActivity(
                this, 1, talkIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val notification = NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle("Doorbell Ringing")
                .setContentText("Someone is at the door!")
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_ALARM)
                .setAutoCancel(true)
                .setContentIntent(viewPending)
                .addAction(android.R.drawable.ic_menu_view, "View", viewPending)
                .addAction(android.R.drawable.ic_btn_speak_now, "Talk", talkPending)
                .setDefaults(0)
                .build()

            val manager = getSystemService(NotificationManager::class.java)
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.e(TAG, "Error showing notification", e)
        }
    }

    // =========================================================================
    // NATIVE TALK (2-WAY AUDIO)
    // =========================================================================

    private fun startNativeTalk() {
        // Check mic permission first — request if not granted
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "RECORD_AUDIO not granted — requesting")
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION_CODE
            )
            return
        }

        if (nativeTalkManager == null) {
            nativeTalkManager = NativeTalkManager(this).apply {
                onStateChanged = { state -> runOnUiThread { updateMicFab(state) } }
            }
        }
        nativeTalkManager?.startTalk(
            settingsManager.getServerIp(),
            settingsManager.getTalkPort()
        )
    }

    private fun stopNativeTalk() {
        nativeTalkManager?.stopTalk()
    }

    private fun toggleNativeTalk() {
        if (nativeTalkManager?.isActive() == true) {
            stopNativeTalk()
        } else {
            startNativeTalk()
        }
    }

    private fun showMicFab() {
        micFab.visibility = View.VISIBLE
    }

    private fun updateMicFab(state: NativeTalkManager.TalkState) {
        when (state) {
            NativeTalkManager.TalkState.IDLE -> {
                micFab.backgroundTintList = android.content.res.ColorStateList.valueOf(0x80333333.toInt())
                micFab.alpha = 0.7f
            }
            NativeTalkManager.TalkState.CONNECTING -> {
                micFab.backgroundTintList = android.content.res.ColorStateList.valueOf(0xFFFFAA00.toInt())
                micFab.alpha = 1.0f
            }
            NativeTalkManager.TalkState.ACTIVE -> {
                micFab.backgroundTintList = android.content.res.ColorStateList.valueOf(0xFFEF4444.toInt())
                micFab.alpha = 1.0f
            }
            NativeTalkManager.TalkState.ERROR -> {
                micFab.backgroundTintList = android.content.res.ColorStateList.valueOf(0x80333333.toInt())
                micFab.alpha = 0.7f
                Toast.makeText(this, "Mic error — check permissions", Toast.LENGTH_SHORT).show()
            }
        }
    }

    // =========================================================================
    // PERMISSIONS
    // =========================================================================

    private fun requestPermissions() {
        // Only request dangerous permissions (INTERNET/VIBRATE are normal, auto-granted)
        val permissions = mutableListOf(
            Manifest.permission.RECORD_AUDIO
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        val permissionsToRequest = permissions.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }

        if (permissionsToRequest.isNotEmpty()) {
            Log.i(TAG, "Requesting permissions: $permissionsToRequest")
            ActivityCompat.requestPermissions(
                this, permissionsToRequest.toTypedArray(), PERMISSIONS_CODE
            )
        } else {
            Log.i(TAG, "All permissions already granted")
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            PERMISSIONS_CODE -> {
                for (i in permissions.indices) {
                    val granted = grantResults[i] == PackageManager.PERMISSION_GRANTED
                    Log.i(TAG, "Permission ${permissions[i]}: ${if (granted) "GRANTED" else "DENIED"}")
                }
            }
            MIC_PERMISSION_CODE -> {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    Log.i(TAG, "RECORD_AUDIO granted — starting talk")
                    startNativeTalk()
                } else {
                    Log.w(TAG, "RECORD_AUDIO denied")
                    Toast.makeText(this, "Mic permission required for 2-way audio", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun requestOverlayPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            )
            startActivity(intent)
        }
    }

    // =========================================================================
    // LIFECYCLE
    // =========================================================================

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    override fun onRestoreInstanceState(savedInstanceState: Bundle) {
        super.onRestoreInstanceState(savedInstanceState)
        webView.restoreState(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        answerIntentHandled = false
        handleAnswerIntent(intent)
    }

    private fun handleAnswerIntent(intent: Intent?) {
        if (answerIntentHandled) return
        if (intent?.getBooleanExtra(EXTRA_ANSWER_DOORBELL, false) == true) {
            answerIntentHandled = true
            intent.removeExtra(EXTRA_ANSWER_DOORBELL)
            val talkEnabled = intent.getBooleanExtra(EXTRA_TALK_ENABLED, false)
            Log.i(TAG, "Answer intent — talk=${talkEnabled}")
            val manager = getSystemService(NotificationManager::class.java)
            manager.cancel(NOTIFICATION_ID)
            val cameraId = settingsManager.getDefaultCamera()
            webView.postDelayed({
                webView.evaluateJavascript(
                    "if(typeof switchCamera==='function') switchCamera('$cameraId');"
                ) { }
                if (talkEnabled) {
                    startNativeTalk()
                }
            }, 500)
        }
    }

    override fun onResume() {
        super.onResume()
        webView.onResume()

        // V4 fix: Check forceReconnect flag from ConfigActivity
        if (settingsManager.getForceReconnect()) {
            settingsManager.setForceReconnect(false)
            mqttManager.forceReconnect(
                settingsManager.getServerIp(),
                settingsManager.getMqttPort()
            )
        } else if (!mqttManager.isConnected()) {
            mqttManager.connect(
                serverIp = settingsManager.getServerIp(),
                port = settingsManager.getMqttPort()
            )
        }

        val currentUrl = buildViewUrl()
        if (lastLoadedUrl != null && lastLoadedUrl != currentUrl) {
            Log.w(TAG, "Settings changed — reloading")
            if (settingsManager.getDefaultLayout() == "single") {
                startMjpegPreview()
            }
            loadWebViewContent()
        } else if (!mjpegOnlyMode && settingsManager.getDefaultLayout() == "single"
                   && exoPlayer == null && !mjpegRunning) {
            // Ensure native video is running on resume (single layout only)
            startNativeVideo()
        }

        setupImmersiveMode()
        handleAnswerIntent(intent)
        idleManager.start()
    }

    override fun onPause() {
        super.onPause()
        webView.onPause()
        idleManager.stop()
    }

    override fun onDestroy() {
        super.onDestroy()
        idleManager.stop()
        cancelStallDetection()
        val handler = Handler(Looper.getMainLooper())
        mjpegOnlyRetryRunnable?.let { handler.removeCallbacks(it) }
        mjpegOnlyRetryRunnable = null
        swipeHintShowRunnable?.let { handler.removeCallbacks(it) }
        swipeHintFadeRunnable?.let { handler.removeCallbacks(it) }
        hideMjpegPreview()
        nativeTalkManager?.stopTalk()
        nativeTalkManager = null
        webView.destroy()
        mqttManager.disconnect()
        mediaPlayer?.release()
        mediaPlayer = null
    }
}
