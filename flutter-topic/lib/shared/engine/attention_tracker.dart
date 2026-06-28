import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, File;

import '../models/models.dart';
import '../utils/device_info.dart';
import '../utils/activity_filter.dart';
import '../storage/database.dart';

/// ── 推送算法：注意力释放窗口检测 ────────────────────────
class AttentionTracker {
  static const int _immersionThresholdMs = 5 * 60 * 1000; // 5 分钟

  static const Set<String> _immersiveApps = <String>{
    '抖音', '快手', '哔哩哔哩', '小红书', '微博', '今日头条', 'QQ', '微信',
  };

  final void Function(String reason)? _onAttentionRelease;

  String _currentApp = '';
  int _currentAppStartMs = 0;
  bool _wasImmersive = false;
  StreamSubscription<String>? _subscription;

  AttentionTracker({void Function(String reason)? onAttentionRelease})
      : _onAttentionRelease = onAttentionRelease;

  void start() {
    if (!Platform.isAndroid) return;

    _subscription = DeviceInfo.watchForegroundChanges(
      fallbackInterval: const Duration(seconds: 10), // 10s 快速轮询，更快响应退出
      enableFallback: true,
    ).listen(_onWindowChange);
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _onWindowChange(String _) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await _collectCurrentWindow(nowMs);
  }

  Future<void> _collectCurrentWindow(int nowMs) async {
    final window = await DeviceInfo.getForegroundWindow();
    if (window == null) return;

    final newApp = window.appLabel ?? window.packageName;
    final newDisplay = window.display;

    if (_currentApp.isNotEmpty && newApp != _currentApp) {
      final duration = nowMs - _currentAppStartMs;
      if (_wasImmersive && duration >= _immersionThresholdMs) {
        _onAttentionRelease?.call(
          'attention_release: $_currentApp (${duration ~/ 1000}s)',
        );
      }
      _currentApp = newApp;
      _currentAppStartMs = nowMs;
      _wasImmersive = _isImmersive(newDisplay);
    } else if (_currentApp.isEmpty) {
      _currentApp = newApp;
      _currentAppStartMs = nowMs;
      _wasImmersive = _isImmersive(newDisplay);
    }

    await _insertMaterial(window, nowMs);
  }

  Future<void> _insertMaterial(ForegroundWindow window, int nowMs) async {
    if (window.title != null && window.title!.isNotEmpty) {
      final sanitized = ActivityFilter.sanitize(window.title!);
      if (sanitized != null) {
        await LocalDatabase.insertMaterial(MaterialItem(
          title: sanitized,
          sourceApp: window.appLabel ?? window.packageName,
          timestamp: nowMs,
        ));
      }
      return;
    }

    if (window.appLabel != null && window.appLabel!.isNotEmpty) {
      final sanitized = ActivityFilter.sanitize(window.appLabel!);
      if (sanitized != null) {
        await LocalDatabase.insertMaterial(MaterialItem(
          title: sanitized,
          sourceApp: window.packageName,
          timestamp: nowMs,
          weight: 0.5,
        ));
      }
    }
  }

  bool _isImmersive(String display) {
    for (final app in _immersiveApps) {
      if (display.contains(app)) return true;
    }
    return false;
  }

  AttentionSnapshot get currentSnapshot => AttentionSnapshot(
        app: _currentApp,
        startedAt: _currentAppStartMs,
        durationMs: _currentApp.isNotEmpty
            ? DateTime.now().millisecondsSinceEpoch - _currentAppStartMs
            : 0,
      );

  static Future<bool> hasEnoughMaterial() async {
    final count = await LocalDatabase.getTodayMaterialCount();
    return count >= 3;
  }

  /// ── AI 话题写入文件，供 Kotlin 弹窗读取 ────────────────
  /// 在 BackgroundOrchestrator 生成话题后调用
  static Future<void> writeAiTopicToFile(String topicText, String appName) async {
    try {
      final content = jsonEncode({
        'topic': topicText,
        'app': appName,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      // 写入文件，供 TopicPopupActivity 读取
      final file = File('/data/user/0/com.example.tulpa_topic/files/tulpa_ai_topic.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    } catch (_) {
      // 写入失败不影响主要功能
    }
  }
}
