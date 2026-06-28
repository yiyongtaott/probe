package com.example.tulpa_topic

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import io.flutter.app.FlutterApplication

class TulpaApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
        TulpaDeviceState.start(this)
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val manager = getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(
                "topic_channel",
                "话题推送",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "注意力释放窗口检测到时推送讨论话题"
                setShowBadge(true)
            }
            manager.createNotificationChannel(channel)
        } catch (_: Exception) {}
    }
}
