package com.example.tulpa_topic

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log

/**
 * 保活后台服务 — 运行在 :accessibility 进程。
 *
 * ⚠️ 不启动前台通知：无障碍服务（TulpaAccessibilityService）已在该进程中
 * 启动了前台服务（FG_NOTIF_ID=1002），足以保持进程存活。
 * 本服务仅作为 START_STICKY 兜底，被杀后自动重启。
 */
class TulpaKeepAliveService : Service() {

    companion object {
        private const val TAG = "TulpaKeepAlive"

        fun start(context: Context) {
            val intent = Intent(context, TulpaKeepAliveService::class.java)
            // 使用 startService 而不是 startForegroundService：
            // 同进程的 TulpaAccessibilityService 已经是前台服务（FG_NOTIF_ID=1002）
            // 进程保活由无障碍服务的前台通知保证，本服务仅作为 START_STICKY 兜底
            context.startService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "KeepAliveService created (no foreground notification)")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "KeepAliveService running (relying on accessibility service's foreground)")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        Log.w(TAG, "KeepAliveService destroyed — attempting restart")
        try {
            val intent = Intent(this, TulpaKeepAliveService::class.java)
            startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "self-restart failed", e)
        }
        super.onDestroy()
    }
}
