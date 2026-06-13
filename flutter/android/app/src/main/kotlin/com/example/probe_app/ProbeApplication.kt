package com.example.probe_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import io.flutter.app.FlutterApplication

class ProbeApplication : FlutterApplication() {
    override fun onCreate() {
        super.onCreate()
        ProbeDeviceState.start(this)
        createServiceNotificationChannels()
    }

    private fun createServiceNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(NotificationManager::class.java)
        val channels = listOf(
            NotificationChannel(
                "probe_reporter",
                "UltraLightProbe",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "UltraLightProbe background reporting"
                setShowBadge(false)
            },
            NotificationChannel(
                "FOREGROUND_DEFAULT",
                "Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Background service"
                setShowBadge(false)
            }
        )
        manager.createNotificationChannels(channels)
    }
}
