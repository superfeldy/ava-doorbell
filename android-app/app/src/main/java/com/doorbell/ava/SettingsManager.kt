package com.doorbell.ava

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * SettingsManager — SharedPreferences wrapper for app settings (v4.0)
 *
 * V4 changes from V3:
 * - Added API token storage for authenticated API calls
 * - Added overlay enabled flag for doorbell popup
 * - Added forceReconnect flag (V3 bug: ConfigActivity couldn't trigger reconnect)
 */
class SettingsManager(context: Context) {

    private val prefs: SharedPreferences = context.getSharedPreferences(
        PREFS_NAME,
        Context.MODE_PRIVATE
    )

    /** Encrypted preferences for sensitive data (API token). */
    private val securePrefs: SharedPreferences by lazy {
        try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                SECURE_PREFS_NAME,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.w("SettingsManager", "EncryptedSharedPreferences failed, falling back to plain: ${e.message}")
            context.getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE)
        }
    }

    // Connection Settings
    fun getServerIp(): String = prefs.getString(KEY_SERVER_IP, DEFAULT_SERVER_IP) ?: DEFAULT_SERVER_IP
    fun setServerIp(ip: String) = prefs.edit().putString(KEY_SERVER_IP, ip).apply()

    fun getAdminPort(): Int = prefs.getInt(KEY_ADMIN_PORT, DEFAULT_ADMIN_PORT)
    fun setAdminPort(port: Int) = prefs.edit().putInt(KEY_ADMIN_PORT, port).apply()

    fun getMqttPort(): Int = prefs.getInt(KEY_MQTT_PORT, DEFAULT_MQTT_PORT)
    fun setMqttPort(port: Int) = prefs.edit().putInt(KEY_MQTT_PORT, port).apply()

    fun getTalkPort(): Int = prefs.getInt(KEY_TALK_PORT, DEFAULT_TALK_PORT)
    fun setTalkPort(port: Int) = prefs.edit().putInt(KEY_TALK_PORT, port).apply()

    // Display Settings
    fun getDefaultCamera(): String = prefs.getString(KEY_DEFAULT_CAMERA, DEFAULT_CAMERA) ?: DEFAULT_CAMERA
    fun setDefaultCamera(camera: String) = prefs.edit().putString(KEY_DEFAULT_CAMERA, camera).apply()

    fun getDefaultLayout(): String = prefs.getString(KEY_DEFAULT_LAYOUT, DEFAULT_LAYOUT) ?: DEFAULT_LAYOUT
    fun setDefaultLayout(layout: String) = prefs.edit().putString(KEY_DEFAULT_LAYOUT, layout).apply()

    fun getScreenBrightness(): Int = prefs.getInt(KEY_SCREEN_BRIGHTNESS, -1)
    fun setScreenBrightness(brightness: Int) = prefs.edit().putInt(KEY_SCREEN_BRIGHTNESS, brightness).apply()

    // Notification Settings
    fun isChimeEnabled(): Boolean = prefs.getBoolean(KEY_CHIME_ENABLED, true)
    fun setChimeEnabled(enabled: Boolean) = prefs.edit().putBoolean(KEY_CHIME_ENABLED, enabled).apply()

    fun isVibrationEnabled(): Boolean = prefs.getBoolean(KEY_VIBRATION_ENABLED, true)
    fun setVibrationEnabled(enabled: Boolean) = prefs.edit().putBoolean(KEY_VIBRATION_ENABLED, enabled).apply()

    // HTTPS
    fun isHttpsEnabled(): Boolean = prefs.getBoolean(KEY_HTTPS_ENABLED, true)
    fun setHttpsEnabled(enabled: Boolean) = prefs.edit().putBoolean(KEY_HTTPS_ENABLED, enabled).apply()

    fun getHttpsPort(): Int = prefs.getInt(KEY_HTTPS_PORT, DEFAULT_HTTPS_PORT)
    fun setHttpsPort(port: Int) = prefs.edit().putInt(KEY_HTTPS_PORT, port).apply()

    // API Token (V4: Bearer token auth for API calls — stored in encrypted prefs)
    fun getApiToken(): String {
        val token = securePrefs.getString(KEY_API_TOKEN, "") ?: ""
        if (token.isNotEmpty()) return token
        // Migrate from plaintext prefs if present
        val plainToken = prefs.getString(KEY_API_TOKEN, "") ?: ""
        if (plainToken.isNotEmpty()) {
            securePrefs.edit().putString(KEY_API_TOKEN, plainToken).apply()
            prefs.edit().remove(KEY_API_TOKEN).apply()
            return plainToken
        }
        return ""
    }
    fun setApiToken(token: String) {
        securePrefs.edit().putString(KEY_API_TOKEN, token).apply()
        // Remove from plain prefs if it was there (migration cleanup)
        prefs.edit().remove(KEY_API_TOKEN).apply()
    }

    // Overlay enabled (V4: floating doorbell popup)
    fun isOverlayEnabled(): Boolean = prefs.getBoolean(KEY_OVERLAY_ENABLED, true)
    fun setOverlayEnabled(enabled: Boolean) = prefs.edit().putBoolean(KEY_OVERLAY_ENABLED, enabled).apply()

    // Force reconnect flag (V4 fix: ConfigActivity sets this, CinemaActivity checks on resume)
    fun getForceReconnect(): Boolean = prefs.getBoolean(KEY_FORCE_RECONNECT, false)
    fun setForceReconnect(value: Boolean) = prefs.edit().putBoolean(KEY_FORCE_RECONNECT, value).apply()

    // WebView renderer failure tracking — persists across app restarts so we
    // don't waste time retrying WebView on devices where it never works.
    // Incremented each time we enter MJPEG-only mode; reset to 0 when WebView succeeds.
    fun getWebViewFailureCount(): Int = prefs.getInt(KEY_WEBVIEW_FAILURES, 0)
    fun setWebViewFailureCount(count: Int) = prefs.edit().putInt(KEY_WEBVIEW_FAILURES, count).apply()

    companion object {
        private const val PREFS_NAME = "ava_doorbell_prefs"
        private const val SECURE_PREFS_NAME = "ava_doorbell_secure_prefs"

        private const val KEY_SERVER_IP = "server_ip"
        private const val KEY_ADMIN_PORT = "admin_port"
        private const val KEY_MQTT_PORT = "mqtt_port"
        private const val KEY_TALK_PORT = "talk_port"
        private const val KEY_DEFAULT_CAMERA = "default_camera"
        private const val KEY_DEFAULT_LAYOUT = "default_layout"
        private const val KEY_SCREEN_BRIGHTNESS = "screen_brightness"
        private const val KEY_CHIME_ENABLED = "chime_enabled"
        private const val KEY_VIBRATION_ENABLED = "vibration_enabled"
        private const val KEY_HTTPS_ENABLED = "https_enabled"
        private const val KEY_HTTPS_PORT = "https_port"
        private const val KEY_API_TOKEN = "api_token"
        private const val KEY_OVERLAY_ENABLED = "overlay_enabled"
        private const val KEY_FORCE_RECONNECT = "force_reconnect"
        private const val KEY_WEBVIEW_FAILURES = "webview_failure_count"

        private const val DEFAULT_SERVER_IP = "10.10.10.167"
        private const val DEFAULT_ADMIN_PORT = 5000
        private const val DEFAULT_HTTPS_PORT = 5443
        private const val DEFAULT_MQTT_PORT = 1883
        private const val DEFAULT_TALK_PORT = 5001
        private const val DEFAULT_CAMERA = "doorbell_direct"
        private const val DEFAULT_LAYOUT = "single"
    }
}
