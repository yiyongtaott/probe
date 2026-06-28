package com.example.probe_app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.util.Log
import io.flutter.app.FlutterApplication
import java.io.File

class ProbeApplication : FlutterApplication() {
    companion object {
        private const val TAG = "ProbeApplication"
    }

    override fun onCreate() {
        val startMs = System.currentTimeMillis()
        Log.i(TAG, "onCreate start")

        try {
            checkAndCleanCrashData()
            writeStartupMarker("starting")

            super.onCreate()
            ProbeDeviceState.start(this)
            createServiceNotificationChannels()

            writeStartupMarker("ready")
            Log.i(TAG, "onCreate done in ${System.currentTimeMillis() - startMs}ms")
        } catch (e: Throwable) {
            Log.e(TAG, "onCreate failed", e)
            writeStartupMarker("crashed")
        }
    }

    private fun createServiceNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
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
        } catch (e: Exception) {
            Log.w(TAG, "create notification channels failed", e)
        }
    }

    /** 检测上次启动是否崩溃，如果是则清理可能损坏的数据文件 */
    private fun checkAndCleanCrashData() {
        try {
            val marker = File(filesDir, "startup_marker.txt")
            if (!marker.exists()) return

            val lastState = marker.readText().trim()
            if (lastState == "ready") return // 上次正常启动

            Log.w(TAG, "last startup state=$lastState  -> cleaning corrupted data")
            // 清理可能损坏的状态文件
            for (name in listOf(
                ProbeDeviceState.DEVICE_STATE_FILE,
                ProbeAccessibilityService.ACCESSIBILITY_WINDOW_FILE,
                "probe_logs.txt"
            )) {
                try {
                    File(filesDir, name).delete()
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
    }

    /** 写入启动阶段标记 */
    private fun writeStartupMarker(state: String) {
        try {
            File(filesDir, "startup_marker.txt").writeText(state)
        } catch (_: Exception) {}
    }
}
