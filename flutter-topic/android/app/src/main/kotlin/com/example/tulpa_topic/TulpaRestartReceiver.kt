package com.example.tulpa_topic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/// 内部重启接收器（非导出，安全）
/// 当无障碍服务被系统销毁时，通过此接收器重启保活服务
class TulpaRestartReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "TulpaRestartReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        Log.i(TAG, "Restart broadcast received")
        try {
            val serviceIntent = Intent(context, TulpaKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start keep-alive service", e)
        }
    }
}
