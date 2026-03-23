package com.doorbell.ava

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * On boot: starts MqttService (persistent doorbell monitoring) and
 * launches CinemaActivity (camera view).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            Log.i("BootReceiver", "Boot completed — starting MqttService + CinemaActivity")
            MqttService.start(context)
            val launch = Intent(context, CinemaActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(launch)
        }
    }
}
