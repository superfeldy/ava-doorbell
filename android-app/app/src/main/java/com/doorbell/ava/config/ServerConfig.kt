package com.doorbell.ava.config

import android.content.Context
import com.google.gson.Gson

data class ServerConfig(
    val serverHost: String = "192.168.1.100",
    val rtspPort: Int = 8554,
    val mqttPort: Int = 1883,
    val go2rtcPort: Int = 1984
) {
    companion object {
        private const val PREFS = "doorbell_prefs"
        private const val KEY = "config"
        
        fun load(context: Context): ServerConfig {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val json = prefs.getString(KEY, null) ?: return ServerConfig()
            return try { Gson().fromJson(json, ServerConfig::class.java) } catch (e: Exception) { ServerConfig() }
        }
    }
    
    fun save(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, Gson().toJson(this)).apply()
    }
}
