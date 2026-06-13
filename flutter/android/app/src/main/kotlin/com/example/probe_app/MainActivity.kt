package com.example.probe_app

import android.content.ComponentName
import android.content.Intent
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "probe/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAccessibilityAccess" -> result.success(hasAccessibilityAccess())
                    "getAndroidDeviceState" -> {
                        result.success(jsonToMap(ProbeDeviceState.writeCurrent(this, "method")))
                    }
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAccessibilityAccess(): Boolean {
        val service = ComponentName(this, ProbeAccessibilityService::class.java)
        val serviceName = service.flattenToString()
        val shortServiceName = service.flattenToShortString()
        val enabledServices = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabledServices.split(':').any {
            it.equals(serviceName, ignoreCase = true) ||
                it.equals(shortServiceName, ignoreCase = true)
        }
    }

    private fun jsonToMap(json: JSONObject): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = json.opt(key)
            map[key] = if (value == JSONObject.NULL) null else value
        }
        return map
    }
}
