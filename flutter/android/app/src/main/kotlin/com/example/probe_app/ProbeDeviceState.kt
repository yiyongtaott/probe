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
            writeCurrent(context.applicationContext, intent?.action)
        }
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
            File(context.filesDir, DEVICE_STATE_FILE).writeText(json.toString())
            lastStateKey = stateKey
            lastWriteAtMs = now
        } catch (e: Exception) {
            Log.w(TAG, "write state failed", e)
        }
        return json
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
