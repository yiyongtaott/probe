import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:usage_stats/usage_stats.dart' as usage_stats;

class DeviceInfo {
  static const String defaultServerBase =
      'http://9.3.0.1.9.1.0.0.0.7.4.0.1.0.0.2.ip6.arpa';
  static const String fallbackServerBase = 'https://flandretiamat.dpdns.org';
  static const MethodChannel _native = MethodChannel('probe/native');
  static const String _accessibilityWindowFile =
      'probe_accessibility_window.json';
  static const List<String> _accessibilityWindowPaths = <String>[
    '/data/user/0/com.example.probe_app/files/$_accessibilityWindowFile',
    '/data/data/com.example.probe_app/files/$_accessibilityWindowFile',
  ];
  static const Duration _accessibilityMaxAge = Duration(minutes: 4);
  static const Set<String> _androidTextCapturePackages = <String>{
    'com.tencent.mobileqq',
    'tv.danmaku.bili',
  };
  static const Map<String, String> _knownAndroidAppLabels = <String, String>{
    'com.example.probe_app': 'UltraLightProbe',
    'com.android.launcher': '系统桌面',
    'com.oplus.launcher': '系统桌面',
    'com.coloros.launcher': '系统桌面',
    'com.microsoft.emmx': 'Microsoft Edge',
    'com.android.chrome': 'Chrome',
    'com.chrome.beta': 'Chrome Beta',
    'com.heytap.browser': '浏览器',
    'com.coloros.browser': '浏览器',
    'com.tencent.mobileqq': 'QQ',
    'tv.danmaku.bili': '哔哩哔哩',
  };

  static Future<String> detectDeviceId() async {
    try {
      if (Platform.isWindows) return _detectWindowsDeviceId();
      if (Platform.isAndroid || Platform.isIOS) return 'phone';
    } catch (_) {}

    const dartDefine = String.fromEnvironment('device');
    if (dartDefine.isNotEmpty) return dartDefine;
    return 'notebook';
  }

  static String detectDeviceIdSync() {
    try {
      if (Platform.isWindows) return _detectWindowsDeviceId();
      if (Platform.isAndroid || Platform.isIOS) return 'phone';
    } catch (_) {}

    const dartDefine = String.fromEnvironment('device');
    if (dartDefine.isNotEmpty) return dartDefine;
    return 'notebook';
  }

  static String _detectWindowsDeviceId() {
    final exe = Platform.resolvedExecutable;
    final base = exe.split(RegExp(r'[/\\]')).last;
    final stem =
        base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    final dash = stem.lastIndexOf('-');
    if (dash >= 0 && dash < stem.length - 1) {
      return stem.substring(dash + 1);
    }
    return 'notebook';
  }

  static Future<String> getForegroundApp() async {
    try {
      if (Platform.isAndroid) return await _getAndroidForegroundApp();
      if (Platform.isIOS) return 'iOS background monitor';
    } catch (_) {}
    return 'unknown';
  }

  static Future<bool> hasAndroidAccessibilityAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      final hasAccess = await _native.invokeMethod<bool>(
        'hasAccessibilityAccess',
      );
      if (hasAccess == true) return true;
    } catch (_) {}
    return await _readAccessibilityForegroundWindow() != null;
  }

  static Future<void> openAndroidAccessibilitySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _native.invokeMethod<void>('openAccessibilitySettings');
    } catch (_) {}
  }

  static Future<bool> hasAndroidUsageAccess() async {
    if (!Platform.isAndroid) return true;
    return await usage_stats.UsageStats.checkUsagePermission() ?? false;
  }

  static Future<void> openAndroidUsageAccessSettings() async {
    if (!Platform.isAndroid) return;
    await usage_stats.UsageStats.grantUsagePermission();
  }

  static Future<String> _getAndroidForegroundApp() async {
    final accessibilityWindow = await _readAccessibilityForegroundWindow();

    final usageWindow = await _queryAndroidUsageForegroundWindow();
    if (usageWindow != null) {
      if (accessibilityWindow != null &&
          accessibilityWindow.packageName == usageWindow.packageName) {
        return accessibilityWindow.display;
      }
      return _formatAndroidPackage(
        usageWindow.packageName,
        usageWindow.className,
      );
    }

    if (accessibilityWindow != null) return accessibilityWindow.display;
    if (!await hasAndroidUsageAccess()) return 'UsageStats permission missing';
    return 'unknown';
  }

  static Future<_AndroidForegroundWindow?>
  _readAccessibilityForegroundWindow() async {
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
        final trimmedPackageName = packageName.trim();
        final className = data['className'] as String?;
        final updatedAt = _parseAndroidWindowUpdatedAt(data['updatedAt']);
        if (now.difference(updatedAt ?? stat.modified) > _accessibilityMaxAge) {
          continue;
        }
        return _AndroidForegroundWindow(
          packageName: trimmedPackageName,
          className: className,
          display: _formatAccessibilityDisplay(
            trimmedPackageName,
            className,
            display.trim(),
          ),
          updatedAt: updatedAt ?? stat.modified,
        );
      } catch (_) {}
    }
    return null;
  }

  static Future<_AndroidForegroundWindow?>
  _queryAndroidUsageForegroundWindow() async {
    final hasPermission = await hasAndroidUsageAccess();
    if (!hasPermission) return null;

    final end = DateTime.now();
    final start = end.subtract(const Duration(minutes: 30));
    final events = await usage_stats.UsageStats.queryEvents(start, end);

    String? packageName;
    String? className;
    for (final event in events) {
      if (event.eventType != '1') continue;
      final pkg = event.packageName;
      if (pkg == null || pkg.isEmpty || pkg == 'null') continue;

      packageName = pkg;
      final cls = event.className;
      className = cls == null || cls.isEmpty || cls == 'null' ? null : cls;
    }

    if (packageName == null) return null;
    return _AndroidForegroundWindow(
      packageName: packageName,
      className: className,
      display: _formatAndroidPackage(packageName, className),
      updatedAt: end,
    );
  }

  static String _formatAndroidPackage(String packageName, String? className) {
    final label = _knownAndroidAppLabels[packageName];
    if (label != null) return label;
    if (packageName.contains('launcher')) return '系统桌面';
    if (packageName.contains('browser')) return '浏览器';
    if (className == null || className == packageName) return packageName;
    return '$packageName/$className';
  }

  static String _formatAccessibilityDisplay(
    String packageName,
    String? className,
    String display,
  ) {
    if (_androidTextCapturePackages.contains(packageName)) return display;
    return _formatAndroidPackage(packageName, className);
  }

  static DateTime? _parseAndroidWindowUpdatedAt(Object? value) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is double) {
      return DateTime.fromMillisecondsSinceEpoch(value.round());
    }
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) {
        return DateTime.fromMillisecondsSinceEpoch(parsed);
      }
    }
    return null;
  }

  static Future<(String, String)> getNetworkInfo() async {
    try {
      final info = NetworkInfo();
      final wifi = await info.getWifiName() ?? 'unknown';
      final ip = await info.getWifiIP() ?? 'unknown';
      return (wifi, ip);
    } catch (_) {
      return ('unknown', 'unknown');
    }
  }

  static Future<String> getBattery() async {
    try {
      final batt = Battery();
      final level = await batt.batteryLevel;
      final state = await batt.batteryState;
      final status = switch (state) {
        BatteryState.charging => 'charging',
        BatteryState.full => 'full',
        BatteryState.discharging => 'discharging',
        _ => level >= 100 ? 'full' : 'discharging',
      };
      return '$level% - $status';
    } catch (_) {
      return 'unknown';
    }
  }
}

class _AndroidForegroundWindow {
  final String packageName;
  final String? className;
  final String display;
  final DateTime updatedAt;

  const _AndroidForegroundWindow({
    required this.packageName,
    required this.className,
    required this.display,
    required this.updatedAt,
  });
}
