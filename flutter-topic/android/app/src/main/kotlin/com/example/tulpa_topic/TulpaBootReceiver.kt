package com.example.tulpa_topic

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/// 保活广播接收器 — 运行在 :accessibility 进程
/// 1. 开机自动启动保活前台服务
/// 2. 无障碍服务被系统销毁时，接收自定义广播重启保活服务
class TulpaBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TulpaBootReceiver"
        const val ACTION_RESTART = "com.example.tulpa_topic.ACTION_RESTART_SERVICE"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        Log.i(TAG, "onReceive action=$action")

        when (action) {
            Intent.ACTION_BOOT_COMPLETED -> {
                Log.i(TAG, "Boot completed — starting keep-alive service")
                startKeepAlive(context)
            }
            ACTION_RESTART -> {
                Log.i(TAG, "Restart requested — starting keep-alive service")
                startKeepAlive(context)
            }
        }
    }

    private fun startKeepAlive(context: Context) {
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
