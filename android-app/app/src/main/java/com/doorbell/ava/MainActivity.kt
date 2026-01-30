package com.doorbell.ava

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.WindowManager
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.rtsp.RtspMediaSource
import com.doorbell.ava.config.ServerConfig
import com.doorbell.ava.databinding.ActivityMainBinding
import com.doorbell.ava.services.MqttService
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private var player: ExoPlayer? = null
    
    private val doorbellReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == MqttService.ACTION_DOORBELL) {
                showDoorbellAlert()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY)
        
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        
        checkPermissions()
        setupUI()
        startStream()
    }

    private fun checkPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) 
                != PackageManager.PERMISSION_GRANTED) {
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100)
            }
        }
    }

    private fun setupUI() {
        binding.btnSettings.setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        
        binding.btnRetry.setOnClickListener {
            binding.errorOverlay.visibility = View.GONE
            startStream()
        }
        
        binding.btnMute.setOnClickListener {
            player?.let {
                val muted = it.volume == 0f
                it.volume = if (muted) 1f else 0f
                binding.btnMute.text = if (muted) "🔊" else "🔇"
            }
        }
        
        binding.alertOverlay.setOnClickListener {
            binding.alertOverlay.visibility = View.GONE
        }
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun startStream() {
        val config = ServerConfig.load(this)
        binding.loadingOverlay.visibility = View.VISIBLE
        binding.statusText.text = "Connecting..."
        
        player?.release()
        player = ExoPlayer.Builder(this).build().apply {
            val url = "rtsp://${config.serverHost}:${config.rtspPort}/doorbell"
            val source = RtspMediaSource.Factory().setForceUseRtpTcp(true)
                .createMediaSource(MediaItem.fromUri(url))
            
            setMediaSource(source)
            addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    when (state) {
                        Player.STATE_READY -> {
                            binding.loadingOverlay.visibility = View.GONE
                            binding.connectionStatus.isSelected = true
                            binding.connectionStatusText.text = "Connected"
                        }
                        Player.STATE_BUFFERING -> binding.statusText.text = "Buffering..."
                        Player.STATE_ENDED -> {
                            lifecycleScope.launch {
                                delay(2000)
                                startStream()
                            }
                        }
                    }
                }
                override fun onPlayerError(error: PlaybackException) {
                    binding.loadingOverlay.visibility = View.GONE
                    binding.errorOverlay.visibility = View.VISIBLE
                    binding.errorText.text = "Connection failed\n${error.message}"
                    binding.connectionStatus.isSelected = false
                    binding.connectionStatusText.text = "Disconnected"
                }
            })
            
            binding.playerView.player = this
            playWhenReady = true
            prepare()
        }
    }

    private fun showDoorbellAlert() {
        binding.alertOverlay.visibility = View.VISIBLE
        lifecycleScope.launch {
            delay(10000)
            binding.alertOverlay.visibility = View.GONE
        }
    }

    override fun onResume() {
        super.onResume()
        val filter = IntentFilter(MqttService.ACTION_DOORBELL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(doorbellReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(doorbellReceiver, filter)
        }
        player?.play()
    }

    override fun onPause() {
        super.onPause()
        try { unregisterReceiver(doorbellReceiver) } catch (_: Exception) {}
        player?.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        player?.release()
    }
}
