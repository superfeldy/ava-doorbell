package com.doorbell.ava

import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.EditText
import android.widget.SeekBar
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.util.Locale

/**
 * ConfigActivity — Configuration screen for AVA Doorbell v4.0
 *
 * V4 changes from V3:
 * - Layout spinner includes 8up/9up options
 * - API token field for Bearer auth
 * - Overlay enable/disable toggle
 * - forceReconnect properly triggers via SettingsManager flag
 * - Overlay permission request button
 */
class ConfigActivity : AppCompatActivity() {

    private val overlayPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { _ ->
        // Re-check overlay permission after returning from settings
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
            switchOverlayEnabled.isChecked = false
            Toast.makeText(this, "Overlay permission not granted", Toast.LENGTH_SHORT).show()
        }
    }

    private lateinit var settingsManager: SettingsManager

    private lateinit var inputServerIp: EditText
    private lateinit var inputAdminPort: EditText
    private lateinit var inputMqttPort: EditText
    private lateinit var inputTalkPort: EditText
    private lateinit var switchHttpsEnabled: SwitchCompat

    private lateinit var inputDefaultCamera: EditText
    private lateinit var spinnerDefaultLayout: Spinner
    private lateinit var seekBarBrightness: SeekBar
    private lateinit var tvBrightnessValue: TextView

    private lateinit var inputApiToken: EditText

    private lateinit var switchChimeEnabled: SwitchCompat
    private lateinit var switchVibrationEnabled: SwitchCompat
    private lateinit var switchOverlayEnabled: SwitchCompat

    private lateinit var btnClearCache: Button
    private lateinit var btnForceReconnect: Button
    private lateinit var tvDeviceInfo: TextView
    private lateinit var tvVersionInfo: TextView

    private lateinit var btnSave: Button
    private lateinit var btnCancel: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_config)

        settingsManager = SettingsManager(this)

        setupTheme()
        initializeViews()
        loadSettings()
    }

    private fun setupTheme() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun initializeViews() {
        inputServerIp = findViewById(R.id.input_server_ip)
        inputAdminPort = findViewById(R.id.input_admin_port)
        inputMqttPort = findViewById(R.id.input_mqtt_port)
        inputTalkPort = findViewById(R.id.input_talk_port)
        switchHttpsEnabled = findViewById(R.id.switch_https_enabled)

        inputDefaultCamera = findViewById(R.id.input_default_camera)
        spinnerDefaultLayout = findViewById(R.id.spinner_default_layout)
        seekBarBrightness = findViewById(R.id.seek_bar_brightness)
        tvBrightnessValue = findViewById(R.id.tv_brightness_value)

        inputApiToken = findViewById(R.id.input_api_token)

        switchChimeEnabled = findViewById(R.id.switch_chime_enabled)
        switchVibrationEnabled = findViewById(R.id.switch_vibration_enabled)
        switchOverlayEnabled = findViewById(R.id.switch_overlay_enabled)

        btnClearCache = findViewById(R.id.btn_clear_cache)
        btnForceReconnect = findViewById(R.id.btn_force_reconnect)
        tvDeviceInfo = findViewById(R.id.tv_device_info)
        tvVersionInfo = findViewById(R.id.tv_version_info)

        btnSave = findViewById(R.id.btn_save)
        btnCancel = findViewById(R.id.btn_cancel)

        // V4: Layout spinner includes 8up and 9up
        val layouts = arrayOf("single", "2up", "4up", "6up", "8up", "9up")
        val adapter = android.widget.ArrayAdapter(this, android.R.layout.simple_spinner_item, layouts)
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        spinnerDefaultLayout.adapter = adapter

        seekBarBrightness.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                tvBrightnessValue.text = if (progress == 0) "System Default" else "${progress}%"
            }
            override fun onStartTrackingTouch(seekBar: SeekBar?) {}
            override fun onStopTrackingTouch(seekBar: SeekBar?) {}
        })

        btnClearCache.setOnClickListener { clearWebViewCache() }
        btnForceReconnect.setOnClickListener { forceReconnectMqtt() }
        btnSave.setOnClickListener { saveSettings() }
        btnCancel.setOnClickListener { finish() }

        // Request overlay permission if needed when toggle is enabled
        switchOverlayEnabled.setOnCheckedChangeListener { _, isChecked ->
            if (isChecked && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:$packageName"))
                overlayPermissionLauncher.launch(intent)
            }
        }
    }

    private fun loadSettings() {
        inputServerIp.setText(settingsManager.getServerIp())
        inputAdminPort.setText(settingsManager.getAdminPort().toString())
        inputMqttPort.setText(settingsManager.getMqttPort().toString())
        inputTalkPort.setText(settingsManager.getTalkPort().toString())
        switchHttpsEnabled.isChecked = settingsManager.isHttpsEnabled()

        inputDefaultCamera.setText(settingsManager.getDefaultCamera())

        val layouts = arrayOf("single", "2up", "4up", "6up", "8up", "9up")
        val layoutIndex = layouts.indexOf(settingsManager.getDefaultLayout())
        spinnerDefaultLayout.setSelection(maxOf(0, layoutIndex))

        val brightness = settingsManager.getScreenBrightness()
        seekBarBrightness.progress = if (brightness == -1) 0 else brightness
        tvBrightnessValue.text = if (brightness == -1) "System Default" else "${brightness}%"

        inputApiToken.setText(settingsManager.getApiToken())

        switchChimeEnabled.isChecked = settingsManager.isChimeEnabled()
        switchVibrationEnabled.isChecked = settingsManager.isVibrationEnabled()
        switchOverlayEnabled.isChecked = settingsManager.isOverlayEnabled()

        updateDeviceInfo()
        updateVersionInfo()
    }

    private fun updateDeviceInfo() {
        val deviceName = Build.DEVICE
        val androidVersion = Build.VERSION.RELEASE
        val sdkInt = Build.VERSION.SDK_INT
        val ipAddress = getDeviceIpAddress()

        tvDeviceInfo.text = """
            Device: $deviceName
            Android Version: $androidVersion (API $sdkInt)
            IP Address: $ipAddress
        """.trimIndent()
    }

    @Suppress("DEPRECATION")
    private fun updateVersionInfo() {
        try {
            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            val version = packageInfo.versionName
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode
            } else {
                packageInfo.versionCode.toLong()
            }
            tvVersionInfo.text = getString(R.string.version_info_format, version, code)
        } catch (_: Exception) {
            tvVersionInfo.text = getString(R.string.version_info_default)
        }
    }

    @Suppress("DEPRECATION")
    private fun getDeviceIpAddress(): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // API 31+: Use ConnectivityManager (WifiManager.connectionInfo deprecated)
                val cm = getSystemService(android.net.ConnectivityManager::class.java)
                val linkProps = cm?.getLinkProperties(cm.activeNetwork)
                linkProps?.linkAddresses
                    ?.firstOrNull { it.address is java.net.Inet4Address }
                    ?.address?.hostAddress ?: "Unknown"
            } else {
                val wifiManager = getSystemService(WIFI_SERVICE) as WifiManager
                val ipInt = wifiManager.connectionInfo.ipAddress
                String.format(
                    Locale.US,
                    "%d.%d.%d.%d",
                    ipInt and 0xff,
                    (ipInt shr 8) and 0xff,
                    (ipInt shr 16) and 0xff,
                    (ipInt shr 24) and 0xff
                )
            }
        } catch (_: Exception) {
            "Unknown"
        }
    }

    private fun saveSettings() {
        val serverIp = inputServerIp.text.toString()
        if (!isValidIpAddress(serverIp)) {
            showValidationError("Invalid server IP address")
            return
        }

        val adminPort = inputAdminPort.text.toString().toIntOrNull() ?: 5000
        if (!isValidPort(adminPort)) {
            showValidationError("Admin port must be between 1-65535")
            return
        }

        val mqttPort = inputMqttPort.text.toString().toIntOrNull() ?: 1883
        if (!isValidPort(mqttPort)) {
            showValidationError("MQTT port must be between 1-65535")
            return
        }

        val talkPort = inputTalkPort.text.toString().toIntOrNull() ?: 5001
        if (!isValidPort(talkPort)) {
            showValidationError("Talk port must be between 1-65535")
            return
        }

        settingsManager.setServerIp(serverIp)
        settingsManager.setAdminPort(adminPort)
        settingsManager.setMqttPort(mqttPort)
        settingsManager.setTalkPort(talkPort)

        settingsManager.setDefaultCamera(inputDefaultCamera.text.toString())
        settingsManager.setDefaultLayout(spinnerDefaultLayout.selectedItem.toString())
        settingsManager.setScreenBrightness(seekBarBrightness.progress)

        settingsManager.setHttpsEnabled(switchHttpsEnabled.isChecked)
        settingsManager.setChimeEnabled(switchChimeEnabled.isChecked)
        settingsManager.setVibrationEnabled(switchVibrationEnabled.isChecked)
        settingsManager.setOverlayEnabled(switchOverlayEnabled.isChecked)

        settingsManager.setApiToken(inputApiToken.text.toString())

        if (seekBarBrightness.progress != -1) {
            val brightnessVal = seekBarBrightness.progress.toFloat() / 100f
            window.attributes.apply {
                screenBrightness = brightnessVal
                window.attributes = this
            }
        }

        Toast.makeText(this, "Settings saved successfully", Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun isValidIpAddress(ip: String): Boolean {
        if (ip.isEmpty()) return false
        val parts = ip.split(".")
        if (parts.size != 4) return false
        return parts.all { part ->
            try {
                val num = part.toInt()
                num in 0..255
            } catch (_: NumberFormatException) {
                false
            }
        }
    }

    private fun isValidPort(port: Int): Boolean = port in 1..65535

    private fun showValidationError(message: String) {
        AlertDialog.Builder(this)
            .setTitle("Validation Error")
            .setMessage(message)
            .setPositiveButton("OK") { dialog, _ -> dialog.dismiss() }
            .show()
    }

    private fun clearWebViewCache() {
        AlertDialog.Builder(this)
            .setTitle("Clear Cache")
            .setMessage("Are you sure you want to clear the WebView cache?")
            .setPositiveButton("Clear") { _, _ ->
                try {
                    val webViewDataDir = getDir("webview", MODE_PRIVATE)
                    deleteDir(webViewDataDir)
                    Toast.makeText(this, "Cache cleared", Toast.LENGTH_SHORT).show()
                } catch (e: Exception) {
                    Toast.makeText(this, "Error: ${e.message}", Toast.LENGTH_SHORT).show()
                }
            }
            .setNegativeButton("Cancel") { dialog, _ -> dialog.dismiss() }
            .show()
    }

    private fun deleteDir(dir: java.io.File): Boolean {
        if (dir.isDirectory) {
            val children = dir.listFiles() ?: return false
            for (child in children) {
                if (!deleteDir(child)) return false
            }
        }
        return dir.delete()
    }

    /**
     * V4 fix: Actually triggers reconnect via SettingsManager flag.
     * CinemaActivity checks this flag on resume and calls mqttManager.forceReconnect().
     */
    private fun forceReconnectMqtt() {
        AlertDialog.Builder(this)
            .setTitle("Reconnect MQTT")
            .setMessage("Force reconnection to MQTT broker?")
            .setPositiveButton("Reconnect") { _, _ ->
                settingsManager.setForceReconnect(true)
                Toast.makeText(this, "MQTT reconnect queued — return to main screen", Toast.LENGTH_LONG).show()
            }
            .setNegativeButton("Cancel") { dialog, _ -> dialog.dismiss() }
            .show()
    }
}
