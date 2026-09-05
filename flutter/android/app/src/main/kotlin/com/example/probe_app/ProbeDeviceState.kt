package com.example.probe_app

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.PowerManager
import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.FileLock

object ProbeDeviceState {
    const val DEVICE_STATE_FILE = "probe_device_state.json"
    const val SCREEN_OFF_WINDOW = "系统息屏"
    const val LOCKED_WINDOW = "系统锁屏"
    private const val TAG = "ProbeDeviceState"

    @Volatile
    private var receiverRegistered = false
    private var lastStateKey: String? = null
    private var lastWriteAtMs: Long = 0

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent?) {
            val action = intent?.action
            writeCurrent(context.applicationContext, action)
            // Screen-off backstop: devices often suspend the Flutter isolate's network
            // the instant the display turns off, so the Dart keepalive never lands.
            // Fire a one-shot status POST natively under a short wakelock here.
            if (action == Intent.ACTION_SCREEN_OFF) {
                pingScreenOff(context.applicationContext)
            }
        }
    }

    /** One-shot screen-off status report (window = 系统息屏). Runs in the broadcast
     *  window under a PARTIAL_WAKE_LOCK so it completes before the device suspends
     *  app network. Sends no vitals; the server preserves last-known lan/wifi/battery. */
    private fun pingScreenOff(context: Context) {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val wl = try {
            pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "probe:screenoff")
        } catch (e: Exception) { null }
        try { wl?.acquire(8000) } catch (_: Exception) {}
        Thread {
            var conn: java.net.HttpURLConnection? = null
            try {
                // 与 Dart 上报同一个设备名（由 --dart-define=device=xxx 编译期注入，默认 phone）
                val deviceId = java.net.URLEncoder.encode(BuildConfig.DEVICE_ID, "UTF-8")
                val url = java.net.URL("https://flandretiamat.dpdns.org/api/report/" + deviceId)
                conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                val body = ("{\"keepalive\":1,\"window\":\"" + SCREEN_OFF_WINDOW + "\"}")
                    .toByteArray(Charsets.UTF_8)
                conn.outputStream.use { it.write(body) }
                Log.i(TAG, "screen-off ping -> ${conn.responseCode}")
            } catch (e: Exception) {
                Log.w(TAG, "screen-off ping failed", e)
            } finally {
                try { conn?.disconnect() } catch (_: Exception) {}
                try { if (wl != null && wl.isHeld) wl.release() } catch (_: Exception) {}
            }
        }.start()
    }

    fun start(context: Context) {
        val appContext = context.applicationContext
        writeCurrent(appContext, "start")
        if (receiverRegistered) return

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                addAction(Intent.ACTION_USER_UNLOCKED)
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appContext.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                appContext.registerReceiver(receiver, filter)
            }
            receiverRegistered = true
        } catch (e: Exception) {
            Log.w(TAG, "register receiver failed", e)
        }
    }

    @Synchronized
    fun writeCurrent(context: Context, reason: String? = null): JSONObject {
        val json = currentJson(context, reason)
        val now = json.optLong("updatedAt", System.currentTimeMillis())
        val stateKey = listOf(
            json.optString("state"),
            json.optBoolean("isInteractive"),
            json.optBoolean("isKeyguardLocked"),
            json.optBoolean("isDeviceLocked")
        ).joinToString("|")
        if (reason == "accessibility" && stateKey == lastStateKey && now - lastWriteAtMs < 15000) {
            return json
        }

        try {
            writeFileWithLock(context, DEVICE_STATE_FILE, json.toString())
            lastStateKey = stateKey
            lastWriteAtMs = now
        } catch (e: Exception) {
            Log.w(TAG, "write state failed", e)
        }
        return json
    }

    /** 使用跨进程文件锁写入文件，避免多进程并发写冲突 */
    private fun writeFileWithLock(context: Context, fileName: String, content: String) {
        val file = File(context.filesDir, fileName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // 使用 FileLock 保证跨进程写入原子性
            RandomAccessFile(file, "rw").use { raf ->
                raf.channel.lock().use { _ ->
                    raf.setLength(0)
                    raf.writeBytes(content)
                }
            }
        } else {
            file.writeText(content)
        }
    }

    fun currentJson(context: Context, reason: String? = null): JSONObject {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val keyguardManager =
            context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager

        val isInteractive = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
            powerManager?.isInteractive ?: true
        } else {
            @Suppress("DEPRECATION")
            powerManager?.isScreenOn ?: true
        }
        val isKeyguardLocked = keyguardManager?.isKeyguardLocked ?: false
        val isDeviceLocked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            keyguardManager?.isDeviceLocked ?: isKeyguardLocked
        } else {
            isKeyguardLocked
        }
        val locked = isKeyguardLocked || isDeviceLocked
        val state = when {
            !isInteractive -> "screen_off"
            locked -> "locked"
            else -> "user_present"
        }
        val systemWindow = when {
            !isInteractive -> SCREEN_OFF_WINDOW
            locked -> LOCKED_WINDOW
            else -> null
        }

        return JSONObject()
            .put("state", state)
            .put("isInteractive", isInteractive)
            .put("isKeyguardLocked", isKeyguardLocked)
            .put("isDeviceLocked", isDeviceLocked)
            .put("isUserPresent", isInteractive && !locked)
            .put("systemWindow", systemWindow ?: JSONObject.NULL)
            .put("reason", reason ?: JSONObject.NULL)
            .put("updatedAt", System.currentTimeMillis())
    }
}
