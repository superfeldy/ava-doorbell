package com.doorbell.ava

import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.doorbell.ava.config.ServerConfig
import com.doorbell.ava.databinding.ActivitySettingsBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

class SettingsActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySettingsBinding
    private val client = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).build()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
        
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        loadSettings()
        
        binding.btnBack.setOnClickListener { finish() }
        binding.btnSave.setOnClickListener { saveSettings() }
        binding.btnTest.setOnClickListener { testConnection() }
    }

    private fun loadSettings() {
        val config = ServerConfig.load(this)
        binding.editServerHost.setText(config.serverHost)
        binding.editRtspPort.setText(config.rtspPort.toString())
        binding.editMqttPort.setText(config.mqttPort.toString())
    }

    private fun saveSettings() {
        val config = ServerConfig(
            serverHost = binding.editServerHost.text.toString().trim(),
            rtspPort = binding.editRtspPort.text.toString().toIntOrNull() ?: 8554,
            mqttPort = binding.editMqttPort.text.toString().toIntOrNull() ?: 1883
        )
        config.save(this)
        Toast.makeText(this, "Settings saved", Toast.LENGTH_SHORT).show()
    }

    private fun testConnection() {
        val host = binding.editServerHost.text.toString().trim()
        if (host.isEmpty()) {
            Toast.makeText(this, "Enter server IP", Toast.LENGTH_SHORT).show()
            return
        }
        
        binding.btnTest.isEnabled = false
        binding.testStatus.visibility = View.VISIBLE
        binding.testStatus.text = "Testing..."
        
        lifecycleScope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    val request = Request.Builder().url("http://$host:1984/api/streams").build()
                    client.newCall(request).execute().use { response ->
                        if (response.isSuccessful) "✓ Connected!" else "✗ Error: ${response.code}"
                    }
                } catch (e: Exception) {
                    "✗ ${e.message}"
                }
            }
            binding.testStatus.text = result
            binding.testStatus.setTextColor(getColor(if (result.startsWith("✓")) R.color.green else R.color.red))
            binding.btnTest.isEnabled = true
        }
    }
}
