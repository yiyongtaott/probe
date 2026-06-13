package com.example.probe_app

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.text.InputType
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import java.io.File

class ProbeAccessibilityService : AccessibilityService() {
    private var lastLoggedDisplay: String? = null
    private val lastMeaningfulTitles = mutableMapOf<String, String>()

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        val eventType = event.eventType
        if (eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOWS_CHANGED
        ) {
            return
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

        val activeRoot = root?.takeIf { rootPackageName == packageName }
        val className = event.className?.toString()?.takeIf { it.isNotBlank() }
            ?: activeRoot?.className?.toString()?.takeIf { it.isNotBlank() }
        val appLabel = getAppLabel(packageName)
        val canCaptureText = textCapturePackages.contains(packageName)
        val texts = mutableListOf<NodeText>()

        if (canCaptureText) activeRoot?.let {
            collectNodeTexts(it, texts, 0)
        }

        val shouldReusePreviousTitle = isBilibiliCommentContext(packageName, texts)
        val chosenTitle = if (canCaptureText && !shouldReusePreviousTitle) {
            chooseTitle(texts, appLabel, packageName)
        } else {
            null
        }
        if (chosenTitle != null) {
            lastMeaningfulTitles[packageName] = chosenTitle
        }
        val title = chosenTitle ?: if (canCaptureText) lastMeaningfulTitles[packageName] else null
        val display = when {
            title != null && title != appLabel -> "$appLabel - $title"
            appLabel.isNotBlank() -> appLabel
            className != null -> "$packageName/$className"
            else -> packageName
        }

        val json = JSONObject()
            .put("display", display)
            .put("packageName", packageName)
            .put("className", className)
            .put("appLabel", appLabel)
            .put("title", title)
            .put("updatedAt", System.currentTimeMillis())

        File(filesDir, ACCESSIBILITY_WINDOW_FILE).writeText(json.toString())
        if (lastLoggedDisplay != display) {
            lastLoggedDisplay = display
            Log.i(TAG, "display=$display package=$packageName")
        }
    }

    override fun onInterrupt() = Unit

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

        if (targetPackageName == "tv.danmaku.bili" && looksLikeBilibiliTitle(text)) {
            score += 10
        }
        if (targetPackageName == "tv.danmaku.bili") {
            val viewId = item.viewId.orEmpty()
            if (viewId.endsWith(":id/title") || viewId.endsWith("/title")) score += 28
            if (viewId.contains("name") || viewId.contains("fans") || viewId.contains("avatar")) {
                score -= 22
            }
        }
        if (targetPackageName == "com.tencent.mobileqq" && looksLikeQqTitle(text)) {
            score += 8
        }
        if (targetPackageName == "com.tencent.mobileqq") {
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

    private fun normalizeText(value: String?): String? {
        if (value == null) return null
        val normalized = value
            .replace("[\\u200E\\u200F\\u202A-\\u202E\\u2066-\\u2069]".toRegex(), "")
            .replace("\\s+".toRegex(), " ")
            .trim()
        if (normalized.isBlank() || normalized == "null") return null
        return normalized
            .replace("\\s+\\d+(\\.\\d+)?[万亿]?播放$".toRegex(), "")
            .trim()
    }

    private fun isBilibiliCommentContext(
        packageName: String,
        texts: List<NodeText>
    ): Boolean {
        if (packageName != "tv.danmaku.bili") return false
        return texts.any {
            it.text == "热门评论" ||
                it.text == "按热度" ||
                it.text == "回复" ||
                it.text.startsWith("回复 ") ||
                it.text.contains("评论区在等你") ||
                it.text.matches(Regex("^评论\\s*[（(]?\\d+[万千百]?"))
        }
    }

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

    private fun isUsefulText(
        item: NodeText,
        appLabel: String,
        targetPackageName: String
    ): Boolean {
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
        if (ignoredTexts.contains(text)) return false
        return true
    }

    private fun looksLikeSystemStatusText(text: String): Boolean {
        if (text.contains("信号")) return true
        if (text.contains("电量")) return true
        if (text.contains("蓝牙")) return true
        if (text.contains("闹钟")) return true
        if (text.contains("勿扰")) return true
        if (text.contains("Wi-Fi", ignoreCase = true)) return true
        if (text.contains("WLAN", ignoreCase = true)) return true
        if (text.endsWith("满格")) return true
        return false
    }

    private fun lowValuePenalty(text: String, targetPackageName: String): Int {
        var penalty = 0
        if (ignoredTexts.contains(text)) penalty += 80
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
            if (text.matches(Regex("^\\d+(\\.\\d+)?[万亿]?人?(正在看|在看|观看)$"))) {
                penalty += 90
            }
        }

        if (targetPackageName == "com.tencent.mobileqq") {
            if (qqLowValueTexts.contains(text)) penalty += 90
        }

        return penalty
    }

    private fun looksLikeBilibiliTitle(text: String): Boolean {
        if (text.length < 4) return false
        if (text.contains("正在看") || text.contains("观看")) return false
        if (bilibiliLowValueTexts.contains(text)) return false
        return containsReadableLetter(text)
    }

    private fun looksLikeQqTitle(text: String): Boolean {
        if (text.length < 2) return false
        if (qqLowValueTexts.contains(text)) return false
        if (text.matches(Regex("^(上午|下午|凌晨|早上|晚上)?\\d{1,2}:\\d{2}$"))) return false
        return containsReadableLetter(text)
    }

    private fun containsReadableLetter(text: String): Boolean {
        return text.any { ch ->
            Character.UnicodeScript.of(ch.code) == Character.UnicodeScript.HAN ||
                ch.isLetter()
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

    private data class ScoredText(
        val item: NodeText,
        val score: Int
    )

    companion object {
        const val ACCESSIBILITY_WINDOW_FILE = "probe_accessibility_window.json"
        private const val TAG = "ProbeAccessibility"

        private val ignoredPackages = setOf(
            "com.android.systemui",
            "com.coloros.smartsidebar",
            "com.oplus.smartsidebar",
            "com.iflytek.inputmethod"
        )

        private val textCapturePackages = setOf(
            "com.tencent.mobileqq",
            "tv.danmaku.bili"
        )

        private val ignoredTexts = setOf(
            "返回",
            "Back",
            "更多",
            "More",
            "搜索",
            "Search",
            "刷新",
            "取消",
            "确定",
            "完成",
            "关闭",
            "开启",
            "转到上一层级",
            "发送",
            "发布",
            "添加表情",
            "添加图片",
            "点我发弹幕",
            "弹幕输入框",
            "查看表情",
            "表情",
            "图片",
            "语音",
            "消息",
            "联系人",
            "动态",
            "转到动态",
            "评论详情",
            "简介",
            "首页",
            "推荐",
            "热门",
            "频道",
            "我的",
            "会员购",
            "直播",
            "动画",
            "番剧",
            "国创",
            "影视",
            "关注",
            "发现",
            "附近",
            "电话",
            "群聊",
            "小世界",
            "账户及设置",
            "UltraLightProbe"
        )

        private val bilibiliLowValueTexts = setOf(
            "简介",
            "评论详情",
            "转到动态",
            "转到上一层级",
            "UP主头像",
            "热门评论",
            "按热度",
            "发布",
            "添加表情",
            "添加图片",
            "评论区在等你",
            "天青色等烟雨，评论区在等你",
            "评论走一走",
            "宫廷玉液酒，评论走一走",
            "点我发弹幕",
            "弹幕输入框",
            "评论",
            "评论区",
            "直播",
            "推荐",
            "热门",
            "关注",
            "弹幕",
            "发弹幕",
            "关闭弹幕",
            "点赞",
            "投币",
            "收藏",
            "分享",
            "关注UP主"
        )

        private val qqLowValueTexts = setOf(
            "账户及设置",
            "查看表情",
            "听筒模式",
            "在线 - 4G",
            "在线",
            "4G",
            "你加入了群聊",
            "表情",
            "图片",
            "语音",
            "发送",
            "消息",
            "联系人",
            "动态",
            "电话",
            "群聊",
            "小世界"
        )

        private val knownAppLabels = mapOf(
            "com.tencent.mobileqq" to "QQ",
            "tv.danmaku.bili" to "哔哩哔哩",
            "com.microsoft.emmx" to "Microsoft Edge",
            "com.android.chrome" to "Chrome",
            "com.heytap.browser" to "浏览器",
            "com.coloros.browser" to "浏览器"
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
}
