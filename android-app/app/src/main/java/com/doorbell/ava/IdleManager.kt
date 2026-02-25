package com.doorbell.ava

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * IdleManager — Auto-dismiss logic for the camera view.
 *
 * Tracks three idle signals and dismisses (sends app to background) when any fires:
 *   1. No camera motion for MOTION_IDLE_MS (3 min) AND no touch for MOTION_IDLE_MS
 *   2. Device face-down for FACE_DOWN_MS (30s)
 *   3. No user touch for TOUCH_IDLE_MS (5 min)
 *
 * Wake-up events that reset timers:
 *   - Doorbell ring
 *   - Camera motion (VideoMotion MQTT event)
 *   - User touch
 *   - Device picked up (no longer face-down)
 */
class IdleManager(
    context: Context,
    private val onDismiss: () -> Unit
) : SensorEventListener {

    companion object {
        private const val TAG = "IdleManager"
        private const val CHECK_INTERVAL_MS = 10_000L   // check every 10s
        private const val MOTION_IDLE_MS = 180_000L     // 3 min no camera motion + no touch
        private const val FACE_DOWN_MS = 30_000L        // 30s face-down
        private const val TOUCH_IDLE_MS = 300_000L      // 5 min no touch at all
        private const val FACE_DOWN_Z_THRESHOLD = -7.0f // accelerometer Z when face-down
    }

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val handler = Handler(Looper.getMainLooper())

    @Volatile var lastMotionTime = System.currentTimeMillis()
        private set
    @Volatile var lastTouchTime = System.currentTimeMillis()
        private set
    @Volatile var faceDownSince = 0L
        private set

    private var running = false
    private var dismissed = false

    private val checkRunnable = object : Runnable {
        override fun run() {
            if (!running) return
            checkIdle()
            handler.postDelayed(this, CHECK_INTERVAL_MS)
        }
    }

    fun start() {
        if (running) return
        running = true
        dismissed = false

        // Reset timers on start
        val now = System.currentTimeMillis()
        lastMotionTime = now
        lastTouchTime = now
        faceDownSince = 0L

        // Register accelerometer
        if (accelerometer != null) {
            // 1 Hz is plenty for face-down detection (threshold is 30s).
            // SENSOR_DELAY_NORMAL (~5 Hz) wastes battery on continuous updates.
            sensorManager.registerListener(
                this, accelerometer, 1_000_000  // 1 Hz (microseconds)
            )
            Log.i(TAG, "Accelerometer registered for face-down detection")
        } else {
            Log.w(TAG, "No accelerometer available — face-down detection disabled")
        }

        // Start periodic idle check
        handler.postDelayed(checkRunnable, CHECK_INTERVAL_MS)
        Log.i(TAG, "IdleManager started (motion=${MOTION_IDLE_MS}ms, faceDown=${FACE_DOWN_MS}ms, touch=${TOUCH_IDLE_MS}ms)")
    }

    fun stop() {
        running = false
        handler.removeCallbacks(checkRunnable)
        sensorManager.unregisterListener(this)
        Log.i(TAG, "IdleManager stopped")
    }

    /** Called when user touches the screen. */
    fun onTouchEvent() {
        lastTouchTime = System.currentTimeMillis()
        // Touch implies the user is present — also reset motion timer
        // so we don't dismiss while they're actively watching
        lastMotionTime = System.currentTimeMillis()
        if (dismissed) {
            dismissed = false
            Log.i(TAG, "Touch detected — dismiss state reset")
        }
    }

    /** Called when MQTT VideoMotion event is received from the camera. */
    fun onMotionDetected() {
        lastMotionTime = System.currentTimeMillis()
        Log.d(TAG, "Camera motion detected — timer reset")
    }

    /** Called on doorbell ring — resets all timers. */
    fun onDoorbellRing() {
        val now = System.currentTimeMillis()
        lastMotionTime = now
        lastTouchTime = now
        faceDownSince = 0L
        dismissed = false
        Log.i(TAG, "Doorbell ring — all idle timers reset")
    }

    private fun checkIdle() {
        if (dismissed) return
        val now = System.currentTimeMillis()

        // Check 1: No camera motion AND no touch for MOTION_IDLE_MS
        val motionIdle = (now - lastMotionTime) > MOTION_IDLE_MS
        val touchIdleForMotion = (now - lastTouchTime) > MOTION_IDLE_MS
        if (motionIdle && touchIdleForMotion) {
            Log.i(TAG, "Idle: no motion for ${(now - lastMotionTime) / 1000}s, no touch for ${(now - lastTouchTime) / 1000}s — dismissing")
            dismiss()
            return
        }

        // Check 2: Face-down for FACE_DOWN_MS
        if (faceDownSince > 0 && (now - faceDownSince) > FACE_DOWN_MS) {
            Log.i(TAG, "Idle: face-down for ${(now - faceDownSince) / 1000}s — dismissing")
            dismiss()
            return
        }

        // Check 3: No touch at all for TOUCH_IDLE_MS (even if motion is happening)
        if ((now - lastTouchTime) > TOUCH_IDLE_MS) {
            Log.i(TAG, "Idle: no touch for ${(now - lastTouchTime) / 1000}s — dismissing")
            dismiss()
            return
        }
    }

    private fun dismiss() {
        if (dismissed) return
        dismissed = true
        Log.i(TAG, "=== AUTO-DISMISS ===")
        handler.post { onDismiss() }
    }

    // SensorEventListener — accelerometer for face-down detection
    override fun onSensorChanged(event: SensorEvent?) {
        if (event?.sensor?.type != Sensor.TYPE_ACCELEROMETER) return

        val z = event.values[2]  // Z-axis: ~9.8 face-up, ~-9.8 face-down

        if (z < FACE_DOWN_Z_THRESHOLD) {
            // Device is face-down
            if (faceDownSince == 0L) {
                faceDownSince = System.currentTimeMillis()
                Log.d(TAG, "Device placed face-down (z=${"%.1f".format(z)})")
            }
        } else {
            // Device is not face-down
            if (faceDownSince > 0L) {
                Log.d(TAG, "Device picked up (z=${"%.1f".format(z)})")
                faceDownSince = 0L
                // Picking up = user is present, reset touch timer
                lastTouchTime = System.currentTimeMillis()
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // no-op
    }
}
