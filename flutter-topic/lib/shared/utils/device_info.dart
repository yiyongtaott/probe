import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemEvent, Platform;

import 'package:flutter/services.dart';

/// 前台窗口监控 — 改编自原 probe 项目
/// 仅收集：页面标题、页面 App 来源、时间（design2.md 第五节）
class DeviceInfo {
  static const MethodChannel _native = MethodChannel('tulpa_topic/native');
  static const String _accessibilityWindowFile =
      'tulpa_accessibility_window.json';
  static const String _androidDeviceStateFile = 'tulpa_device_state.json';
  static const String androidScreenOffWindow = '系统息屏';
  static const String androidLockedWindow = '系统锁屏';

  static const List<String> _accessibilityWindowPaths = <String>[
    '/data/user/0/com.example.tulpa_topic/files/$_accessibilityWindowFile',
    '/data/data/com.example.tulpa_topic/files/$_accessibilityWindowFile',
  ];
  static const List<String> _androidWatchedDirectories = <String>[
    '/data/user/0/com.example.tulpa_topic/files',
    '/data/data/com.example.tulpa_topic/files',
  ];
  static const Duration _accessibilityMaxAge = Duration(minutes: 4);

  /// ── 隐私白名单：只有这些包名允许抓取页面标题 ──────────
  /// design2.md: 不保存页面正文/图片/视频/用户输入/聊天内容
  static const Set<String> _textCapturePackages = <String>{
    'com.tencent.mobileqq',
    'tv.danmaku.bili',
    'com.zhihu.android',
    'com.sina.weibo',
    'com.ss.android.article.news',
    'com.tencent.mm',
  };

  /// ── App 名称映射（非白名单只显示应用名） ──────────────
  static const Map<String, String> _knownAppLabels = <String, String>{
    'com.example.tulpa_topic': 'TulpaTopic',
    'com.android.launcher': '系统桌面',
    'com.oplus.launcher': '系统桌面',
    'com.coloros.launcher': '系统桌面',
    'com.android.settings': '设置',
    'com.microsoft.emmx': 'Edge',
    'com.android.chrome': 'Chrome',
    'com.heytap.browser': '浏览器',
    'com.tencent.mobileqq': 'QQ',
    'com.tencent.mm': '微信',
    'tv.danmaku.bili': '哔哩哔哩',
    'com.zhihu.android': '知乎',
    'com.sina.weibo': '微博',
    'com.ss.android.article.news': '今日头条',
    'com.netease.cloudmusic': '网易云音乐',
    'com.tencent.qqlive': '腾讯视频',
    'com.youku.phone': '优酷',
    'com.taobao.taobao': '淘宝',
    'com.eg.android.AlipayGphone': '支付宝',
  };

  /// ── 获取当前前台窗口信息 ─────────────────────────────
  static Future<ForegroundWindow?> getForegroundWindow() async {
    if (!Platform.isAndroid) return null;
    return _readAccessibilityForegroundWindow();
  }

  /// ── 获取前台应用显示名称 ─────────────────────────────
  static Future<String> getForegroundApp() async {
    final window = await getForegroundWindow();
    return window?.display ?? 'unknown';
  }

  /// ── 检查无障碍服务是否已启用 ─────────────────────────
  static Future<bool> hasAccessibilityAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      final hasAccess = await _native.invokeMethod<bool>(
        'hasAccessibilityAccess',
      );
      if (hasAccess == true) return true;
    } catch (_) {}
    return await _readAccessibilityForegroundWindow() != null;
  }

  /// ── 打开无障碍设置页 ─────────────────────────────────
  static Future<void> openAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _native.invokeMethod<void>('openAccessibilitySettings');
    } catch (_) {}
  }

  /// ── 监听前台窗口变化（文件事件驱动，与原项目一致） ────
  static Stream<String> watchForegroundChanges({
    Duration fallbackInterval = const Duration(seconds: 30),
    bool enableFallback = true,
  }) {
    if (!Platform.isAndroid) return const Stream<String>.empty();

    final controller = StreamController<String>();
    final subscriptions = <StreamSubscription<FileSystemEvent>>[];
    Timer? fallbackTimer;

    Future<void> start() async {
      for (final dirPath in _androidWatchedDirectories.toSet()) {
        try {
          final dir = Directory(dirPath);
          if (!await dir.exists()) continue;
          final subscription = dir
              .watch(
                events:
                    FileSystemEvent.create |
                    FileSystemEvent.modify |
                    FileSystemEvent.move |
                    FileSystemEvent.delete,
              )
              .listen((event) {
                final name = _basename(event.path);
                if (name == _accessibilityWindowFile ||
                    name == _androidDeviceStateFile) {
                  controller.add(name);
                }
              }, onError: (_) {});
          subscriptions.add(subscription);
        } catch (_) {}
      }

      if (enableFallback) {
        fallbackTimer = Timer.periodic(fallbackInterval, (_) {
          controller.add('fallback');
        });
      }
    }

    controller.onListen = () => unawaited(start());
    controller.onCancel = () async {
      fallbackTimer?.cancel();
      for (final s in subscriptions) {
        await s.cancel();
      }
    };
    return controller.stream;
  }

  // ── 内部方法 ──────────────────────────────────────────

  static Future<ForegroundWindow?> _readAccessibilityForegroundWindow() async {
    for (final path in _accessibilityWindowPaths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;

        final stat = await file.stat();
        final now = DateTime.now();
        if (now.difference(stat.modified) > _accessibilityMaxAge) continue;

        final content = await file.readAsString();
        final data = jsonDecode(content);
        if (data is! Map<String, dynamic>) continue;

        final display = data['display'] as String?;
        if (display == null || display.trim().isEmpty) continue;
        final packageName = data['packageName'] as String?;
        if (packageName == null || packageName.trim().isEmpty) continue;
        final title = data['title'] as String?;
        final appLabel = data['appLabel'] as String?;
        final updatedAt = _parseTimestamp(data['updatedAt']) ?? stat.modified;

        if (now.difference(updatedAt) > _accessibilityMaxAge) continue;

        return ForegroundWindow(
          packageName: packageName.trim(),
          display: display.trim(),
          title: title,
          appLabel: appLabel,
          updatedAt: updatedAt,
        );
      } catch (_) {}
    }
    return null;
  }

  static DateTime? _parseTimestamp(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is double) {
      return DateTime.fromMillisecondsSinceEpoch(value.round());
    }
    return null;
  }

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    if (slash >= 0 && slash < path.length - 1) {
      return path.substring(slash + 1);
    }
    return path;
  }

  /// 获取 App 友好名称
  static String getAppLabel(String packageName) {
    return _knownAppLabels[packageName] ?? packageName;
  }

  /// 是否为可抓取标题的白名单 App
  static bool isTextCapturePackage(String packageName) {
    return _textCapturePackages.contains(packageName);
  }

  /// ── 获取已安装应用列表（仅非系统应用） ───────────────────
  static Future<List<InstalledApp>> getInstalledApps() async {
    if (!Platform.isAndroid) return [];
    try {
      final list = await _native.invokeMethod<List<dynamic>>('getInstalledApps');
      if (list == null) return [];
      return list
          .map((e) => InstalledApp(
                packageName: (e as Map)['packageName'] as String,
                appName: e['appName'] as String,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// ── 获取当前白名单 ─────────────────────────────────────
  static Future<List<String>> getWhitelist() async {
    if (!Platform.isAndroid) return _textCapturePackages.toList();
    try {
      final list = await _native.invokeMethod<List<dynamic>>('getWhitelist');
      if (list == null || list.isEmpty) return _textCapturePackages.toList();
      return list.cast<String>();
    } catch (_) {
      return _textCapturePackages.toList();
    }
  }

  /// ── 设置白名单 ─────────────────────────────────────────
  static Future<bool> setWhitelist(List<String> packages) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _native.invokeMethod<bool>('setWhitelist', {
        'packages': packages,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}

/// 已安装应用信息
class InstalledApp {
  final String packageName;
  final String appName;

  const InstalledApp({
    required this.packageName,
    required this.appName,
  });
}

/// 前台窗口快照
class ForegroundWindow {
  final String packageName;
  final String display;    // 显示文本（"App名 - 标题" 或 "App名"）
  final String? title;     // 抓取到的页面标题（仅白名单 App）
  final String? appLabel;  // App 友好名称
  final DateTime updatedAt;

  const ForegroundWindow({
    required this.packageName,
    required this.display,
    this.title,
    this.appLabel,
    required this.updatedAt,
  });
}
