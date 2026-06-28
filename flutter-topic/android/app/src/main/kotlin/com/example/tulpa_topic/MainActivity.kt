package com.example.tulpa_topic

import android.content.ComponentName
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tulpa_topic/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAccessibilityAccess" -> result.success(hasAccessibilityAccess())
                    "openAccessibilitySettings" -> {
                        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                        result.success(true)
                    }
                    "getInstalledApps" -> result.success(getInstalledApps())
                    "getWhitelist" -> result.success(getWhitelist())
                    "setWhitelist" -> {
                        val packages = call.argument<List<String>>("packages")
                        if (packages != null) {
                            saveWhitelist(packages)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "packages is null", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun getInstalledApps(): List<Map<String, String>> {
        val apps = mutableListOf<Map<String, String>>()
        try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                PackageManager.GET_META_DATA
            } else {
                0
            }
            val installedApps = packageManager.getInstalledApplications(flags)
            for (app in installedApps) {
                // 只返回有启动入口的非系统应用
                if (app.flags and ApplicationInfo.FLAG_SYSTEM == 0) {
                    val launchIntent = packageManager.getLaunchIntentForPackage(app.packageName)
                    if (launchIntent != null) {
                        val label = packageManager.getApplicationLabel(app).toString()
                        apps.add(mapOf("packageName" to app.packageName, "appName" to label))
                    }
                }
            }
            apps.sortBy { it["appName"]?.lowercase() }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return apps
    }

    private fun getWhitelist(): List<String> {
        return try {
            val file = java.io.File(filesDir, "tulpa_whitelist.json")
            if (!file.exists()) return emptyList()
            val content = file.readText()
            val json = JSONArray(content)
            val list = mutableListOf<String>()
            for (i in 0 until json.length()) {
                json.optString(i, null)?.let { list.add(it) }
            }
            list
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun saveWhitelist(packages: List<String>) {
        try {
            val json = JSONArray(packages)
            java.io.File(filesDir, "tulpa_whitelist.json").writeText(json.toString())
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun hasAccessibilityAccess(): Boolean {
        val service = ComponentName(this, TulpaAccessibilityService::class.java)
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
}
