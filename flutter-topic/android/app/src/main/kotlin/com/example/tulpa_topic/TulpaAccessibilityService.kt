package com.example.tulpa_topic

import android.accessibilityservice.AccessibilityService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.FileObserver
import android.text.InputType
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/// 无障碍服务 — 采集当前浏览窗口标题
/// 改编自原 probe 项目 ProbeAccessibilityService
/// 仅收集：页面标题、页面 App 来源、时间（design2.md 第五节）
/// 隐私白名单：只有指定 App 才抓取页面标题，其余只显示应用名
class TulpaAccessibilityService : AccessibilityService() {
    private var lastLoggedDisplay: String? = null
    private var lastWrittenDisplay: String? = null
    private var lastWrittenPackage: String? = null
    private var lastWindowWriteAtMs: Long = 0
    private val lastMeaningfulTitles = mutableMapOf<String, String>()
    private var totalEventsHandled: Long = 0
    private var totalFileWrites: Long = 0
    private var serviceStartTimeMs: Long = 0

    // ── 白名单动态管理 ────────────────────────────────────
    private var dynamicWhitelist = mutableSetOf<String>()
    private var whitelistFileObserver: FileObserver? = null

    // ── 应用退出检测 ──────────────────────────────────────
    private var activeWhitelistedApp: String? = null
    private var activeWhitelistStartMs: Long = 0
    private var lastNotifiedExitMs: Long = 0

    companion object {
        const val ACCESSIBILITY_WINDOW_FILE = "tulpa_accessibility_window.json"
        private const val WHITELIST_FILE = "tulpa_whitelist.json"
        private const val TAG = "TulpaAccessibility"
        private const val WINDOW_REFRESH_MS = 30000L
        private const val FG_NOTIF_CHANNEL_ID = "tulpa_foreground"
        private const val EXIT_NOTIF_CHANNEL_ID = "topic_channel_exit"
        private const val FG_NOTIF_ID = 1002
        private const val EXIT_NOTIF_ID = 2002
        private const val MIN_EXIT_INTERVAL_MS = 30000L // 30秒内不重复推送

        private val ignoredPackages = setOf(
            "com.android.systemui",
            "com.coloros.smartsidebar",
            "com.oplus.smartsidebar",
            "com.iflytek.inputmethod"
        )

        /// 默认白名单（不可变基准）
        private val defaultTextCapturePackages = setOf(
            "com.tencent.mobileqq",
            "tv.danmaku.bili",
            "com.zhihu.android",
            "com.sina.weibo",
            "com.ss.android.article.news",
            "com.tencent.mm"
        )

        private val ignoredTexts = setOf(
            "返回", "Back", "更多", "More", "搜索", "Search", "刷新",
            "取消", "确定", "完成", "关闭", "开启", "转到上一层级",
            "发送", "发布", "添加表情", "添加图片", "点我发弹幕",
            "弹幕输入框", "查看表情", "表情", "图片", "语音", "消息",
            "联系人", "动态", "转到动态", "评论详情", "简介", "首页",
            "推荐", "热门", "频道", "我的", "会员购", "直播", "动画",
            "番剧", "国创", "影视", "关注", "发现", "附近", "电话",
            "群聊", "小世界", "账号及设置", "TulpaTopic"
        )

        private val bilibiliLowValueTexts = setOf(
            "简介", "评论详情", "转到动态", "转到上一层级", "UP主头像",
            "热门评论", "按热度", "发布", "添加表情", "添加图片",
            "评论区等你", "天青色等烟雨，评论区等你", "评论走一走",
            "宫廷玉液酒，评论走一走", "点我发弹幕", "弹幕输入框",
            "评论", "评论区", "直播", "推荐", "热门", "关注", "弹幕",
            "发弹幕", "关闭弹幕", "点赞", "投币", "收藏", "分享", "关注UP主"
        )

        private val qqLowValueTexts = setOf(
            "账号及设置", "查看表情", "听筒模式", "在线 - 4G", "在线",
            "4G", "你加入了群聊", "表情", "图片", "语音", "发送",
            "消息", "联系人", "动态", "电话", "群聊", "小世界"
        )

        private val knownAppLabels = mapOf(
            "com.example.tulpa_topic" to "TulpaTopic",
            "com.tencent.mobileqq" to "QQ",
            "tv.danmaku.bili" to "哔哩哔哩",
            "com.zhihu.android" to "知乎",
            "com.sina.weibo" to "微博",
            "com.ss.android.article.news" to "今日头条",
            "com.tencent.mm" to "微信",
            "com.microsoft.emmx" to "Edge",
            "com.android.chrome" to "Chrome",
            "com.heytap.browser" to "浏览器",
            "com.coloros.browser" to "浏览器",
            "com.android.settings" to "设置",
            "com.android.launcher" to "系统桌面",
            "com.oplus.launcher" to "系统桌面",
            "com.coloros.launcher" to "系统桌面"
        )

        private val browserPackages = setOf(
            "com.microsoft.emmx",
            "com.android.chrome",
            "com.chrome.beta",
            "com.heytap.browser",
            "com.coloros.browser",
            "com.UCMobile",
            "org.mozilla.firefox"
        )
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        serviceStartTimeMs = System.currentTimeMillis()
        TulpaDeviceState.start(this)

        // 启动保活前台服务（无通知）
        TulpaKeepAliveService.start(this)
        // 无障碍服务自身启动低噪前台通知（Android 强制要求）
        startAccessibilityForeground()

        // 加载动态白名单
        loadDynamicWhitelist()
        startWhitelistObserver()

        Log.i(TAG, "=== TulpaTopic Accessibility Service CONNECTED ===")
        Log.i(TAG, "Service package: $packageName")
        Log.i(TAG, "Whitelist: ${dynamicWhitelist.size} apps")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        TulpaDeviceState.writeCurrent(this, "accessibility")
        val eventType = event.eventType
        if (eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOWS_CHANGED
        ) {
            return
        }
        totalEventsHandled++
        if (totalEventsHandled <= 5 || totalEventsHandled % 50 == 0L) {
            Log.i(TAG, "events=$totalEventsHandled writes=$totalFileWrites uptime=${(System.currentTimeMillis() - serviceStartTimeMs) / 1000}s")
        }

        val root = rootInActiveWindow
        val eventPackageName = event.packageName?.toString()?.takeIf { it.isNotBlank() }
        val rootPackageName = root?.packageName?.toString()?.takeIf { it.isNotBlank() }
        val packageName = when {
            rootPackageName != null && !ignoredPackages.contains(rootPackageName) -> rootPackageName
            eventPackageName != null && !ignoredPackages.contains(eventPackageName) -> eventPackageName
            else -> return
        }
        if (ignoredPackages.contains(packageName)) return

        // ── 应用切换/退出检测 ──────────────────────────────
        if (eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            detectAppSwitch(packageName)
        }

        val activeRoot = root?.takeIf { rootPackageName == packageName }
        val className = event.className?.toString()?.takeIf { it.isNotBlank() }
            ?: activeRoot?.className?.toString()?.takeIf { it.isNotBlank() }
        val appLabel = getAppLabel(packageName)
        val canCaptureText = isWhitelisted(packageName)
        val texts = mutableListOf<NodeText>()

        if (canCaptureText) activeRoot?.let {
            collectNodeTexts(it, texts, 0)
        }

        val shouldReusePreviousTitle = isCommentContext(packageName, texts)
        val chosenTitle = if (canCaptureText && !shouldReusePreviousTitle) {
            chooseTitle(texts, appLabel, packageName)
        } else {
            null
        }
        if (chosenTitle != null) {
            lastMeaningfulTitles[packageName] = chosenTitle
            Log.d(TAG, "title chosen: $chosenTitle app=$appLabel pkg=$packageName")
        } else if (canCaptureText) {
            Log.d(TAG, "no title chosen: app=$appLabel pkg=$packageName texts=${texts.size}")
        }
        val title = chosenTitle ?: if (canCaptureText) lastMeaningfulTitles[packageName] else null
        val display = when {
            title != null && title != appLabel -> "$appLabel - $title"
            appLabel.isNotBlank() -> appLabel
            className != null -> "$packageName/$className"
            else -> packageName
        }

        val nowMs = System.currentTimeMillis()
        val json = JSONObject()
            .put("display", display)
            .put("packageName", packageName)
            .put("className", className)
            .put("appLabel", appLabel)
            .put("title", title)
            .put("updatedAt", nowMs)

        val shouldWrite = display != lastWrittenDisplay ||
            packageName != lastWrittenPackage ||
            nowMs - lastWindowWriteAtMs >= WINDOW_REFRESH_MS
        if (shouldWrite) {
            totalFileWrites++
            File(filesDir, ACCESSIBILITY_WINDOW_FILE).writeText(json.toString())
            lastWrittenDisplay = display
            lastWrittenPackage = packageName
            lastWindowWriteAtMs = nowMs
        }
        if (lastLoggedDisplay != display) {
            lastLoggedDisplay = display
            Log.i(TAG, "display=$display package=$packageName title=$title canCapture=$canCaptureText")
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "=== Accessibility Service INTERRUPTED ===)")
    }

    override fun onDestroy() {
        Log.i(TAG, "=== Accessibility Service DESTROYED (events=$totalEventsHandled writes=$totalFileWrites) ===)")
        whitelistFileObserver?.stopWatching()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        // 发送广播尝试重启保活服务
        try {
            sendBroadcast(Intent("com.example.tulpa_topic.ACTION_RESTART_SERVICE"))
        } catch (_: Exception) {}
        super.onDestroy()
    }

    // ═══════════════════════════════════════════════════════
    //  应用切换/退出检测 + 弹出式通知
    // ═══════════════════════════════════════════════════════

    private fun detectAppSwitch(newPackage: String) {
        val nowMs = System.currentTimeMillis()
        val isWhitelisted = isWhitelisted(newPackage)
        val isLauncher = isLauncherPackage(newPackage)

        when {
            // 从白名单应用切出（到桌面或其他非白名单应用）
            activeWhitelistedApp != null && (isLauncher || !isWhitelisted) -> {
                val duration = nowMs - activeWhitelistStartMs
                Log.i(TAG, "EXIT_DETECT: left $activeWhitelistedApp after ${duration}ms -> $newPackage")
                pushExitNotification(activeWhitelistedApp!!, duration)
                activeWhitelistedApp = null
            }
            // 进入白名单应用
            isWhitelisted -> {
                if (activeWhitelistedApp != newPackage) {
                    Log.i(TAG, "ENTER_DETECT: entered $newPackage")
                    activeWhitelistedApp = newPackage
                    activeWhitelistStartMs = nowMs
                }
            }
        }
    }

    private fun pushExitNotification(appPackage: String, durationMs: Long) {
        val nowMs = System.currentTimeMillis()
        if (nowMs - lastNotifiedExitMs < MIN_EXIT_INTERVAL_MS) {
            Log.d(TAG, "Skip exit notification: too soon")
            return
        }
        lastNotifiedExitMs = nowMs

        val appLabel = getAppLabel(appPackage)

        // 写入退出触发器文件，Flutter 端会检测并调用 AI 生成话题
        writeExitTrigger(appPackage, appLabel, durationMs)

        Log.i(TAG, "EXIT_DETECT: showing AI popup for $appLabel after ${durationMs}ms")
        showExitPopup(appLabel, durationMs)
    }

    /// 写退出触发器文件（Flutter AttentionTracker 检测用）
    private fun writeExitTrigger(packageName: String, appLabel: String, durationMs: Long) {
        try {
            val json = JSONObject()
                .put("package", packageName)
                .put("appLabel", appLabel)
                .put("durationMs", durationMs)
                .put("timestamp", System.currentTimeMillis())
            File(filesDir, "tulpa_exit_trigger.json").writeText(json.toString())
            Log.i(TAG, "Exit trigger written for $appLabel")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to write exit trigger", e)
        }
    }

    /// 启动弹出式通知对话框（AI 动态话题版）
    /// 初始显示「AI 分析中…」，等待 Flutter 生成话题后更新
    private fun showExitPopup(appLabel: String, durationMs: Long) {
        try {
            val intent = Intent(this, TopicPopupActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(TopicPopupActivity.EXTRA_APP_LABEL, appLabel)
                putExtra(TopicPopupActivity.EXTRA_DURATION_MS, durationMs)
            }
            startActivity(intent)
            Log.i(TAG, "AI Popup Activity started")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start popup Activity, falling back to notification", e)
            try {
                createExitNotificationChannelIfNeeded()
                val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                val pendingIntent = PendingIntent.getActivity(
                    this, 0, launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val notification = Notification.Builder(this, EXIT_NOTIF_CHANNEL_ID).apply {
                    setContentTitle("AI 正在分析浏览内容…")
                    setContentText("刚刚在 $appLabel 浏览了内容，正在生成话题")
                    setSmallIcon(android.R.drawable.ic_dialog_email)
                    setContentIntent(pendingIntent)
                    setAutoCancel(true)
                    setCategory(Notification.CATEGORY_RECOMMENDATION)
                    setWhen(System.currentTimeMillis())
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        setStyle(Notification.BigTextStyle().bigText("刚刚在 $appLabel 浏览了内容，正在生成话题"))
                    }
                }.build()
                val manager = getSystemService(NotificationManager::class.java)
                manager?.notify(EXIT_NOTIF_ID, notification)
                Log.i(TAG, "Fallback AI notification sent")
            } catch (e2: Exception) {
                Log.e(TAG, "Fallback notification also failed", e2)
            }
        }
    }

    // ═══════════════════════════════════════════════════════
    //  前台通知（Android 强制要求，最小化对用户干扰）
    // ═══════════════════════════════════════════════════════

    private fun createForegroundChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(FG_NOTIF_CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            FG_NOTIF_CHANNEL_ID,
            "后台服务",
            NotificationManager.IMPORTANCE_MIN  // 最低优先级，无声音/震动，不在锁屏显示
        ).apply {
            description = "保持无障碍服务在后台运行（Android 强制要求）"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun createExitNotificationChannelIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(EXIT_NOTIF_CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            EXIT_NOTIF_CHANNEL_ID,
            "话题推送",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "检测到注意力释放窗口时推送讨论话题"
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun startAccessibilityForeground() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        createForegroundChannelIfNeeded()

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 最低优先级的通知——用户几乎不会看到，仅满足 Android 前台服务要求
        val notification = Notification.Builder(this, FG_NOTIF_CHANNEL_ID).apply {
            setContentTitle("TulpaTopic")
            setContentText("后台运行中")
            setSmallIcon(android.R.drawable.ic_menu_info_details)
            setContentIntent(pendingIntent)
            setOngoing(true)
            setShowWhen(false)
            setLocalOnly(true)
            setCategory(Notification.CATEGORY_SERVICE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
        }.build()

        try {
            startForeground(FG_NOTIF_ID, notification)
            Log.i(TAG, "Accessibility service started as foreground (silent notification)")
        } catch (e: Exception) {
            Log.w(TAG, "startForeground failed", e)
        }
    }

    // ═══════════════════════════════════════════════════════
    //  动态白名单管理
    // ═══════════════════════════════════════════════════════

    private fun isWhitelisted(packageName: String): Boolean {
        return dynamicWhitelist.contains(packageName)
    }

    private fun isLauncherPackage(packageName: String): Boolean {
        return packageName == "com.android.launcher" ||
            packageName == "com.oplus.launcher" ||
            packageName == "com.coloros.launcher" ||
            packageName == "com.miui.home" ||
            packageName == "com.huawei.android.launcher" ||
            packageName.contains("launcher", ignoreCase = true)
    }

    private fun loadDynamicWhitelist() {
        dynamicWhitelist.clear()

        try {
            val file = File(filesDir, WHITELIST_FILE)
            if (!file.exists()) {
                // 首次运行：把默认白名单写入文件
                dynamicWhitelist.addAll(defaultTextCapturePackages)
                saveWhitelistToFile(dynamicWhitelist.toList())
                Log.i(TAG, "First run: initialized whitelist with ${dynamicWhitelist.size} defaults")
                return
            }
            val content = file.readText()
            val json = JSONArray(content)
            for (i in 0 until json.length()) {
                val pkg = json.optString(i, null)
                if (pkg != null && pkg.isNotBlank()) {
                    dynamicWhitelist.add(pkg)
                }
            }
            Log.i(TAG, "Loaded whitelist: ${dynamicWhitelist.size} apps")
        } catch (e: Exception) {
            Log.w(TAG, "Failed to load whitelist, using defaults", e)
            dynamicWhitelist.addAll(defaultTextCapturePackages)
        }
    }

    private fun startWhitelistObserver() {
        try {
            val file = File(filesDir, WHITELIST_FILE)
            if (!file.exists()) file.createNewFile()

            @Suppress("DEPRECATION")
            whitelistFileObserver = object : FileObserver(file.absolutePath, MODIFY or CLOSE_WRITE) {
                override fun onEvent(event: Int, path: String?) {
                    if (event == MODIFY || event == CLOSE_WRITE) {
                        Log.i(TAG, "Whitelist file changed, reloading...")
                        loadDynamicWhitelist()
                    }
                }
            }
            whitelistFileObserver?.startWatching()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start whitelist observer", e)
        }
    }

    private fun saveWhitelistToFile(packages: List<String>) {
        try {
            val json = JSONArray(packages)
            File(filesDir, WHITELIST_FILE).writeText(json.toString())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to save whitelist", e)
        }
    }

    // ── 节点文本采集 ──────────────────────────────────────
    private fun collectNodeTexts(
        node: AccessibilityNodeInfo,
        out: MutableList<NodeText>,
        depth: Int
    ) {
        if (depth > 8 || !node.isVisibleToUser) return
        if (isSensitiveInput(node)) return

        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val nodeTexts = listOfNotNull(
            normalizeText(node.text?.toString()),
            normalizeText(node.contentDescription?.toString())
        ).distinct()

        if (bounds.right > bounds.left && bounds.bottom > bounds.top) {
            for (text in nodeTexts) {
                out.add(
                    NodeText(
                        text,
                        bounds.top,
                        bounds.left,
                        bounds.bottom,
                        bounds.right,
                        node.isClickable,
                        node.className?.toString(),
                        node.viewIdResourceName
                    )
                )
            }
        }

        for (i in 0 until node.childCount) {
            node.getChild(i)?.let { child ->
                try {
                    collectNodeTexts(child, out, depth + 1)
                } finally {
                    child.recycle()
                }
            }
        }
    }

    // ── 标题选择评分 ──────────────────────────────────────
    private fun chooseTitle(
        texts: List<NodeText>,
        appLabel: String,
        targetPackageName: String
    ): String? {
        val unique = texts
            .filter { isUsefulText(it, appLabel, targetPackageName) }
            .distinctBy { it.text }

        return unique
            .map { ScoredText(it, scoreTitleCandidate(it, targetPackageName)) }
            .filter { it.score >= 18 }
            .sortedWith(
                compareByDescending<ScoredText> { it.score }
                    .thenBy { it.item.top }
                    .thenBy { it.item.left }
                    .thenByDescending { it.item.text.length }
            )
            .firstOrNull()
            ?.item
            ?.text
    }

    private fun scoreTitleCandidate(item: NodeText, targetPackageName: String): Int {
        val text = item.text
        var score = 12

        score -= lowValuePenalty(text, targetPackageName)
        if (score < -40) return score

        score += when (item.top) {
            in 80..520 -> 18
            in 521..1000 -> 10
            in 1001..1500 -> 3
            else -> -8
        }
        if (!item.clickable) score += 4
        if (item.right > item.left && item.bottom > item.top) {
            val width = item.right - item.left
            val height = item.bottom - item.top
            if (width >= 120 && height >= 24) score += 3
        }

        score += when (text.length) {
            in 4..32 -> 10
            in 2..3 -> 4
            in 33..48 -> 2
            else -> -8
        }
        if (containsReadableLetter(text)) score += 6

        if (targetPackageName == "tv.danmaku.bili" && looksLikeVideoTitle(text)) {
            score += 10
            val viewId = item.viewId.orEmpty()
            if (viewId.endsWith(":id/title") || viewId.endsWith("/title")) score += 28
            if (viewId.contains("name") || viewId.contains("fans") || viewId.contains("avatar")) {
                score -= 22
            }
        }
        if (targetPackageName == "com.tencent.mobileqq" && looksLikeChatTitle(text)) {
            score += 8
            val viewId = item.viewId.orEmpty().lowercase()
            if (looksLikeProfileCardText(text)) score -= 120
            if (viewId.contains("avatar") ||
                viewId.contains("head") ||
                viewId.contains("face") ||
                viewId.contains("profile") ||
                viewId.contains("card")
            ) {
                score -= 60
            }
            score += when (item.top) {
                in 90..300 -> 38
                in 301..430 -> 4
                else -> -36
            }
        }
        if (isBrowserPackage(targetPackageName) && !looksLikeUrl(text)) {
            score += 4
        }

        return score
    }

    // ── 文本规范化 ────────────────────────────────────────
    private fun normalizeText(value: String?): String? {
        if (value == null) return null
        val normalized = stripLeadingVisualNoise(value
            .replace("[\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069\\uFEFF]".toRegex(), "")
            .replace("\\s+".toRegex(), " ")
            .trim())
        if (normalized.isBlank() || normalized == "null") return null
        if (isEphemeralControlText(normalized)) return null
        return normalized
            .replace("\\s+\\d+(\\.\\d+)?[亿万]?播放$".toRegex(), "")
            .trim()
    }

    private fun isCommentContext(packageName: String, texts: List<NodeText>): Boolean {
        if (packageName != "tv.danmaku.bili") return false
        return texts.any { it ->
            it.text == "热门评论" ||
                it.text == "按热度" ||
                it.text == "回复" ||
                it.text.startsWith("回复 ") ||
                it.text.contains("评论区等你") ||
                it.text.matches(Regex("^评论\\s*[（(]?\\d+[万千百]?"))
        }
    }

    // ── 敏感输入过滤（不抓输入框/密码） ────────────────────
    private fun isSensitiveInput(node: AccessibilityNodeInfo): Boolean {
        if (node.isPassword || node.isEditable) return true

        val className = node.className?.toString().orEmpty()
        if (className.contains("EditText", ignoreCase = true)) return true

        val viewId = node.viewIdResourceName.orEmpty()
        if (viewId.contains("password", ignoreCase = true)) return true
        if (viewId.contains("passwd", ignoreCase = true)) return true
        if (viewId.contains("pwd", ignoreCase = true)) return true

        val inputType = node.inputType
        if (inputType == 0) return false
        val inputClass = inputType and InputType.TYPE_MASK_CLASS
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        if (inputClass == InputType.TYPE_CLASS_TEXT) {
            return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
        }
        if (inputClass == InputType.TYPE_CLASS_NUMBER) {
            return variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        }
        return false
    }

    // ── 有用文本判断 ──────────────────────────────────────
    private fun isUsefulText(item: NodeText, appLabel: String, targetPackageName: String): Boolean {
        val text = item.text
        if (text.length > 80) return false
        if (text == appLabel) return false
        if (text == targetPackageName) return false
        if (text == packageName) return false
        if (text.matches(Regex("^\\d+$"))) return false
        if (text.matches(Regex("^\\d{1,2}:\\d{2}$"))) return false
        if (text.matches(Regex("^\\d+%$"))) return false
        if (looksLikeSystemStatusText(text)) return false
        if (looksLikePackageOrActivity(text)) return false
        if (isEphemeralControlText(text)) return false
        if (ignoredTexts.contains(text)) return false
        return true
    }

    private fun isEphemeralControlText(text: String): Boolean {
        val compact = text.replace("\\s+".toRegex(), "")
        if (compact in setOf(
                "播放", "暂停", "播放/暂停",
                "倍速", "倍速中", "加载中",
                "正在加载", "缓冲中", "重播",
                "点击重试", "拖动到此处锁定倍速", "发送中...", "一键已读",
                "Play", "Pause", "Paused", "Playing"
            )
        ) return true
        if (compact.matches(Regex("^\\d+(\\.\\d+)?x$", RegexOption.IGNORE_CASE))) return true
        if (compact.matches(Regex("^\\d+(\\.\\d+)?倍$"))) return true
        if (compact.contains("倍速") && compact.length <= 8) return true
        return false
    }

    private fun stripLeadingVisualNoise(text: String): String {
        var index = 0
        while (index < text.length) {
            val cp = text.codePointAt(index)
            val isNoise = cp in 0x2800..0x28FF ||
                cp in 0x1F300..0x1FAFF ||
                cp == 0x231B || cp == 0x23F3 || cp == 0x25CC ||
                cp in 0x25D0..0x25D3 || cp == 0x25E6 || cp == 0x25EF ||
                cp == 0x2705 || cp == 0x2713 || cp == 0x2714 ||
                cp == 0x2726 || cp == 0x2728 || cp == 0x2733 || cp == 0x2734 ||
                cp == 0x2747 || cp == 0x274C || cp == 0xFFFD
            if (!isNoise && !Character.isWhitespace(cp)) break
            index += Character.charCount(cp)
        }
        return text.substring(index).trim()
    }

    private fun looksLikeSystemStatusText(text: String): Boolean {
        if (text.contains("信号") || text.contains("电量") || text.contains("蓝牙")) return true
        if (text.contains("闹钟") || text.contains("勿扰")) return true
        if (text.contains("Wi-Fi", ignoreCase = true) || text.contains("WLAN", ignoreCase = true)) return true
        if (text.endsWith("满格")) return true
        return false
    }

    private fun lowValuePenalty(text: String, targetPackageName: String): Int {
        var penalty = 0
        if (ignoredTexts.contains(text)) penalty += 80
        if (isEphemeralControlText(text)) penalty += 120
        if (looksLikeSystemStatusText(text)) penalty += 80
        if (looksLikePackageOrActivity(text)) penalty += 90
        if (looksLikeUrl(text)) penalty += 40
        if (text.contains("输入框")) penalty += 100
        if (text.startsWith("添加") && text.length <= 8) penalty += 90
        if (text.matches(Regex("^\\(?\\d+\\)?$"))) penalty += 70
        if (text.matches(Regex("^\\d+(\\.\\d+)?[万亿千百]?$"))) penalty += 80
        if (text.matches(Regex("^LV\\d+\\s*.+$"))) penalty += 90
        if (text.matches(Regex("^\\d+\\s*/\\s*\\d+$"))) penalty += 70
        if (text.matches(Regex("^(上午|下午|凌晨|早上|晚上)?\\d{1,2}:\\d{2}$"))) penalty += 70
        if (text.matches(Regex("^\\d{4}年\\d{1,2}月\\d{1,2}日.*$"))) penalty += 90
        if (text.matches(Regex("^评论[（(]\\d+[）)]$"))) penalty += 90
        if (text.matches(Regex("^\\d+条评论$"))) penalty += 90
        if (text.matches(Regex("^\\d+(\\.\\d+)?[万亿千百]?粉丝$"))) penalty += 90
        if (text.contains("人正在看") || text.contains("人在观看")) penalty += 80
        if (text.contains("条新消息") || text.contains("未读")) penalty += 50

        if (targetPackageName == "tv.danmaku.bili") {
            if (bilibiliLowValueTexts.contains(text)) penalty += 90
            if (text.matches(Regex("^\\d+(\\.\\d+)?[万亿]?人?(正在看|在看|观看)$"))) penalty += 90
        }
        if (targetPackageName == "com.tencent.mobileqq") {
            if (qqLowValueTexts.contains(text)) penalty += 90
            if (looksLikeProfileCardText(text)) penalty += 120
        }
        return penalty
    }

    private fun looksLikeVideoTitle(text: String): Boolean {
        if (text.length < 4) return false
        if (text.contains("正在看") || text.contains("观看")) return false
        if (bilibiliLowValueTexts.contains(text)) return false
        return containsReadableLetter(text)
    }

    private fun looksLikeChatTitle(text: String): Boolean {
        if (text.length < 2) return false
        if (qqLowValueTexts.contains(text)) return false
        if (looksLikeProfileCardText(text)) return false
        if (text.matches(Regex("^(上午|下午|凌晨|早上|晚上)?\\d{1,2}:\\d{2}$"))) return false
        return containsReadableLetter(text)
    }

    private fun looksLikeProfileCardText(text: String): Boolean {
        if (text == "资料卡" || text == "个人资料卡") return true
        if (text.contains("的资料卡") || text.contains("的个人资料")) return true
        if (text.startsWith("查看") && text.contains("资料")) return true
        return false
    }

    private fun containsReadableLetter(text: String): Boolean {
        return text.any { ch ->
            Character.UnicodeScript.of(ch.code) == Character.UnicodeScript.HAN || ch.isLetter()
        }
    }

    private fun looksLikeUrl(text: String): Boolean {
        return text.startsWith("http://", ignoreCase = true) ||
            text.startsWith("https://", ignoreCase = true)
    }

    private fun looksLikePackageOrActivity(text: String): Boolean {
        if (text.contains("/") && text.contains(".")) return true
        return text.matches(Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*){2,}.*$"))
    }

    private fun isBrowserPackage(packageName: String): Boolean {
        return browserPackages.contains(packageName)
    }

    private fun getAppLabel(packageName: String): String {
        val knownLabel = knownAppLabels[packageName]
        return try {
            val info = packageManager.getApplicationInfo(packageName, 0)
            val label = packageManager.getApplicationLabel(info).toString()
            if (label.isNotBlank() && label != packageName) label else knownLabel ?: packageName
        } catch (_: Exception) {
            knownLabel ?: packageName
        }
    }

    private data class NodeText(
        val text: String,
        val top: Int,
        val left: Int,
        val bottom: Int,
        val right: Int,
        val clickable: Boolean,
        val className: String?,
        val viewId: String?
    )

    private data class ScoredText(val item: NodeText, val score: Int)
}
