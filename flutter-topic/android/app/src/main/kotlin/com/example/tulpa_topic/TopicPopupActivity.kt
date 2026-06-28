package com.example.tulpa_topic

import android.app.Activity
import android.app.AlertDialog
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import org.json.JSONObject
import java.io.File

/**
 * 退出应用时弹出的通知对话框（AI 动态话题版）。
 *
 * 当用户从哔哩哔哩等白名单应用切出时：
 * 1. 显示「AI 正在分析浏览内容…」加载状态
 * 2. 后台 Flutter 调用 AI 生成话题，写入 tulpa_ai_topic.json
 * 3. 本 Activity 检测到文件更新后，自动刷新内容
 */
class TopicPopupActivity : Activity() {
    companion object {
        private const val TAG = "TulpaPopup"
        const val EXTRA_APP_LABEL = "app_label"
        const val EXTRA_DURATION_MS = "duration_ms"
        private const val AI_TOPIC_FILE = "tulpa_ai_topic.json"
        private const val POLL_INTERVAL_MS = 1500L
    }

    private var userResponded = false
    private var dialog: AlertDialog? = null
    private var topicLoaded = false
    private var aiTopicText: String? = null
    private var aiAppLabel: String? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pollRunnable: Runnable? = null
    private var fileObserver: FileObserver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val appLabel = intent?.getStringExtra(EXTRA_APP_LABEL) ?: ""
        val durationMs = intent?.getLongExtra(EXTRA_DURATION_MS, 0) ?: 0
        aiAppLabel = appLabel

        // 配置窗口：覆盖在其他应用之上、锁屏显示
        window?.apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setType(WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY)
            }
            addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
            addFlags(WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
            addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            addFlags(WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD)
        }

        // 先读取上次可能存在的话题结果
        tryLoadTopic()

        showDialog(appLabel, durationMs)
        startTopicWatcher()
    }

    /// 读取 AI 话题文件
    private fun tryLoadTopic(): Boolean {
        try {
            val file = File(filesDir, AI_TOPIC_FILE)
            if (!file.exists()) return false
            val content = file.readText()
            val json = JSONObject(content)
            val topic = json.optString("topic", null)
            if (topic != null && topic.isNotBlank()) {
                aiTopicText = topic
                aiAppLabel = json.optString("app", aiAppLabel)
                topicLoaded = true
                return true
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read AI topic", e)
        }
        return false
    }

    /// 显示对话框（加载态或已加载）
    private fun showDialog(appLabel: String, durationMs: Long) {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("from_popup", true)
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title: String
        val message: String

        if (topicLoaded && aiTopicText != null) {
            title = "今天的话题"
            message = "关于你在 $appLabel 看到的内容：\n\n「${aiTopicText}」\n\n${formatDuration(durationMs)} 的浏览后生成"
        } else {
            title = "AI 正在分析…"
            message = "检测到你刚刚在 $appLabel 浏览了 ${formatDuration(durationMs)}。\nAI 正在总结浏览内容，请稍候…"
        }

        dialog?.dismiss()
        dialog = null

        dialog = AlertDialog.Builder(this, android.R.style.Theme_Material_Light_Dialog_Alert)
            .setTitle(title)
            .setMessage(message)
            .setPositiveButton("去看看") { _, _ ->
                userResponded = true
                try { pendingIntent.send() } catch (_: Exception) {}
                finish()
            }
            .setNegativeButton("关闭") { _, _ ->
                userResponded = true
                finish()
            }
            .setOnCancelListener {
                userResponded = true
                finish()
            }
            .setCancelable(true)
            .create()

        dialog?.show()
        dialog?.setOnDismissListener {
            if (!userResponded && !isFinishing) finish()
        }

        Log.i(TAG, "Popup shown: $title")
    }

    /// 启动话题文件监控（轮询 + FileObserver）
    private fun startTopicWatcher() {
        if (topicLoaded) return // 已加载则无需等待

        // 1. FileObserver 监控文件改动
        try {
            val file = File(filesDir, AI_TOPIC_FILE)
            if (!file.exists()) {
                file.parentFile?.mkdirs()
                file.createNewFile()
            }
            @Suppress("DEPRECATION")
            fileObserver = object : FileObserver(file.absolutePath, MODIFY or CLOSE_WRITE) {
                override fun onEvent(event: Int, path: String?) {
                    if (event == MODIFY || event == CLOSE_WRITE) {
                        mainHandler.post {
                            if (!topicLoaded && tryLoadTopic() && !userResponded) {
                                val label = aiAppLabel ?: ""
                                val dur = intent?.getLongExtra(EXTRA_DURATION_MS, 0) ?: 0
                                showDialog(label, dur)
                            }
                        }
                    }
                }
            }
            fileObserver?.startWatching()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start FileObserver", e)
        }

        // 2. 轮询兜底（每 1.5s）
        pollRunnable = object : Runnable {
            override fun run() {
                if (topicLoaded || userResponded || isFinishing) return
                if (tryLoadTopic() && !userResponded) {
                    val label = aiAppLabel ?: ""
                    val dur = intent?.getLongExtra(EXTRA_DURATION_MS, 0) ?: 0
                    runOnUiThread { showDialog(label, dur) }
                } else {
                    mainHandler.postDelayed(this, POLL_INTERVAL_MS)
                }
            }
        }
        mainHandler.postDelayed(pollRunnable!!, POLL_INTERVAL_MS)

        // 3. 超时回退：10秒后强制关闭
        mainHandler.postDelayed({
            if (!topicLoaded && !userResponded && !isFinishing) {
                Log.i(TAG, "AI topic timed out, showing fallback")
                val label = aiAppLabel ?: ""
                val dur = intent?.getLongExtra(EXTRA_DURATION_MS, 0) ?: 0
                // 不重新创建对话框，直接 finish
                if (!userResponded) finish()
            }
        }, 10000L)
    }

    override fun onDestroy() {
        dialog?.dismiss()
        dialog = null
        pollRunnable?.let { mainHandler.removeCallbacks(it) }
        pollRunnable = null
        fileObserver?.stopWatching()
        fileObserver = null
        Log.i(TAG, "Popup dismissed (userResponded=$userResponded topicLoaded=$topicLoaded)")
        super.onDestroy()
    }

    private fun formatDuration(ms: Long): String {
        val minutes = ms / 60000
        val seconds = (ms % 60000) / 1000
        return when {
            minutes >= 60 -> "${minutes / 60}小时${minutes % 60}分钟"
            minutes >= 1 -> "${minutes}分钟"
            seconds >= 1 -> "${seconds}秒"
            else -> "刚刚"
        }
    }
}
