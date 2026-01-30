package com.doorbell.ava

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import com.doorbell.ava.services.MqttService

class DoorbellApplication : Application() {
    companion object {
        const val CHANNEL_DOORBELL = "doorbell_alerts"
        const val CHANNEL_SERVICE = "service_channel"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
        startMqttService()
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            
            val doorbellChannel = NotificationChannel(
                CHANNEL_DOORBELL, "Doorbell Alerts", NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Doorbell ring notifications"
                enableVibration(true)
            }
            
            val serviceChannel = NotificationChannel(
                CHANNEL_SERVICE, "Background Service", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps connection active"
            }
            
            manager.createNotificationChannels(listOf(doorbellChannel, serviceChannel))
        }
    }

    private fun startMqttService() {
        val intent = Intent(this, MqttService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
