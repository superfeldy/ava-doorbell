package com.doorbell.ava

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

/**
 * Persistent foreground service that maintains the MQTT connection
 * independently of CinemaActivity's lifecycle. When the activity is
 * destroyed (user exits to home screen), this service keeps listening
 * for doorbell ring events and launches the activity when one arrives.
 */
class MqttService : Service() {

    companion object {
        private const val TAG = "MqttService"
        private const val NOTIFICATION_ID = 2001
        private const val CHANNEL_ID = "mqtt_service"

        fun start(context: Context) {
            val intent = Intent(context, MqttService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private var mqttManager: MqttManager? = null
    private var mediaPlayer: MediaPlayer? = null

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "MqttService created")
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (mqttManager == null) {
            val settings = SettingsManager(this)
            mqttManager = MqttManager(
                context = this,
                onConnectionStateChanged = { connected ->
                    Log.i(TAG, "MQTT connection state: $connected")
                },
                onDoorbellRing = { onRing() },
                onMotionEvent = null
            )
            mqttManager?.connect(
                serverIp = settings.getServerIp(),
                port = settings.getMqttPort()
            )
            Log.i(TAG, "MQTT connect initiated from service")
        }
        return START_STICKY  // restart if killed
    }

    private fun onRing() {
        Log.i(TAG, "=== RING received in MqttService — showing overlay ===")
        playChime()
        vibrate()

        // Show the doorbell overlay popup (Answer / Dismiss).
        // CinemaActivity launches only when the user taps Answer.
        val settings = SettingsManager(this)
        val overlayIntent = Intent(this, DoorbellOverlayService::class.java).apply {
            putExtra("server_ip", settings.getServerIp())
            putExtra("admin_port", settings.getAdminPort())
            putExtra("camera_id", settings.getDefaultCamera())
            putExtra("https_enabled", false)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(overlayIntent)
            } else {
                startService(overlayIntent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Cannot start overlay from service: ${e.message}")
            // Fallback: launch activity directly
            val launch = Intent(this, CinemaActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("ring_event", true)
            }
            startActivity(launch)
        }
    }

    private fun playChime() {
        try {
            mediaPlayer?.release()
            val mp = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setOnCompletionListener { it.release() }
            }
            val afd = resources.openRawResourceFd(R.raw.doorbell_chime) ?: return
            mp.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            afd.close()
            mp.prepare()
            mp.start()
            mediaPlayer = mp
        } catch (e: Exception) {
            Log.w(TAG, "Chime playback failed: ${e.message}")
        }
    }

    private fun vibrate() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(VIBRATOR_SERVICE) as Vibrator
            }
            vibrator.vibrate(VibrationEffect.createOneShot(500, VibrationEffect.DEFAULT_AMPLITUDE))
        } catch (e: Exception) {
            Log.w(TAG, "Vibration failed: ${e.message}")
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Doorbell Monitor",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps doorbell monitoring active"
                setShowBadge(false)
            }
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, CinemaActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("AVA Doorbell")
            .setContentText("Monitoring for doorbell events")
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    override fun onDestroy() {
        Log.i(TAG, "MqttService destroyed")
        mqttManager?.disconnect()
        mqttManager = null
        mediaPlayer?.release()
        mediaPlayer = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
