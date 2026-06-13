import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, FileSystemEvent, Platform;

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
  static const String _androidDeviceStateFile = 'probe_device_state.json';
  static const String androidScreenOffWindow = '系统息屏';
  static const String androidLockedWindow = '系统锁屏';
  static const List<String> _accessibilityWindowPaths = <String>[
    '/data/user/0/com.example.probe_app/files/$_accessibilityWindowFile',
    '/data/data/com.example.probe_app/files/$_accessibilityWindowFile',
  ];
  static const List<String> _androidDeviceStatePaths = <String>[
    '/data/user/0/com.example.probe_app/files/$_androidDeviceStateFile',
    '/data/data/com.example.probe_app/files/$_androidDeviceStateFile',
  ];
  static const List<String> _androidWatchedDirectories = <String>[
    '/data/user/0/com.example.probe_app/files',
    '/data/data/com.example.probe_app/files',
  ];
  static const Duration _accessibilityMaxAge = Duration(minutes: 4);
  static const Duration _freshAccessibilityAge = Duration(seconds: 20);
  static const Set<String> _androidTextCapturePackages = <String>{
    'com.tencent.mobileqq',
    'tv.danmaku.bili',
  };
  static const Map<String, String> _knownAndroidAppLabels = <String, String>{
    'com.example.probe_app': 'UltraLightProbe',
    'com.android.launcher': '系统桌面',
    'com.oplus.launcher': '系统桌面',
    'com.coloros.launcher': '系统桌面',
    'com.android.settings': '设置',
    'com.android.settings.intelligence': '设置',
    'com.microsoft.emmx': 'Microsoft Edge',
    'com.android.chrome': 'Chrome',
    'com.chrome.beta': 'Chrome Beta',
    'com.heytap.browser': '浏览器',
    'com.coloros.browser': '浏览器',
    'com.quark.browser': '夸克',
    'com.tencent.mobileqq': 'QQ',
    'com.tencent.mm': '微信',
    'tv.danmaku.bili': '哔哩哔哩',
    'com.coloros.note': '便签',
    'com.heytap.note': '便签',
    'com.oplus.note': '便签',
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

  static Future<AndroidDeviceState> getAndroidDeviceState() async {
    if (!Platform.isAndroid) return AndroidDeviceState.userPresent();

    try {
      final data = await _native.invokeMapMethod<String, dynamic>(
        'getAndroidDeviceState',
      );
      if (data != null) return AndroidDeviceState.fromMap(data);
    } catch (_) {}

    final fileState = await _readAndroidDeviceStateFile();
    return fileState ?? AndroidDeviceState.userPresent();
  }

  static Future<bool> canSendKeepaliveFor(String app) async {
    if (!Platform.isAndroid) return true;
    if (isAndroidSystemStateWindow(app)) return false;
    final state = await getAndroidDeviceState();
    return state.isUserPresent;
  }

  static bool isAndroidSystemStateWindow(String app) {
    return app == androidScreenOffWindow || app == androidLockedWindow;
  }

  static Stream<String> watchAndroidForegroundChanges({
    Duration fallbackInterval = const Duration(seconds: 5),
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

      if (subscriptions.isEmpty) {
        fallbackTimer = Timer.periodic(fallbackInterval, (_) {
          controller.add('fallback');
        });
      }
    }

    controller.onListen = () {
      unawaited(start());
    };
    controller.onCancel = () async {
      fallbackTimer?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  static Future<String> _getAndroidForegroundApp() async {
    final deviceState = await getAndroidDeviceState();
    if (!deviceState.isInteractive) return androidScreenOffWindow;
    if (deviceState.isLocked) return androidLockedWindow;

    final accessibilityWindow = await _readAccessibilityForegroundWindow();
    final now = DateTime.now();
    if (accessibilityWindow != null &&
        now.difference(accessibilityWindow.updatedAt) <=
            _freshAccessibilityAge) {
      return accessibilityWindow.display;
    }

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

  static Future<AndroidDeviceState?> _readAndroidDeviceStateFile() async {
    for (final path in _androidDeviceStatePaths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;

        final stat = await file.stat();
        final content = await file.readAsString();
        final data = jsonDecode(content);
        if (data is! Map<String, dynamic>) continue;
        return AndroidDeviceState.fromMap(
          data,
          fallbackUpdatedAt: stat.modified,
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
    return packageName;
  }

  static String _formatAccessibilityDisplay(
    String packageName,
    String? className,
    String display,
  ) {
    if (_androidTextCapturePackages.contains(packageName)) return display;
    if (display.isNotEmpty &&
        display != packageName &&
        !_looksLikePackageOrActivity(display)) {
      return display;
    }
    return _formatAndroidPackage(packageName, className);
  }

  static bool _looksLikePackageOrActivity(String text) {
    if (text.contains('/') && text.contains('.')) return true;
    return RegExp(
      r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*){2,}.*$',
    ).hasMatch(text);
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

  static String _basename(String path) {
    final slash = path.lastIndexOf('/');
    if (slash >= 0 && slash < path.length - 1) {
      return path.substring(slash + 1);
    }
    final backslash = path.lastIndexOf('\\');
    if (backslash >= 0 && backslash < path.length - 1) {
      return path.substring(backslash + 1);
    }
    return path;
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

class AndroidDeviceState {
  final bool isInteractive;
  final bool isKeyguardLocked;
  final bool isDeviceLocked;
  final String state;
  final String? systemWindow;
  final DateTime updatedAt;

  const AndroidDeviceState({
    required this.isInteractive,
    required this.isKeyguardLocked,
    required this.isDeviceLocked,
    required this.state,
    required this.systemWindow,
    required this.updatedAt,
  });

  factory AndroidDeviceState.userPresent() {
    return AndroidDeviceState(
      isInteractive: true,
      isKeyguardLocked: false,
      isDeviceLocked: false,
      state: 'user_present',
      systemWindow: null,
      updatedAt: DateTime.now(),
    );
  }

  factory AndroidDeviceState.fromMap(
    Map<String, dynamic> data, {
    DateTime? fallbackUpdatedAt,
  }) {
    final isInteractive = data['isInteractive'] != false;
    final isKeyguardLocked = data['isKeyguardLocked'] == true;
    final isDeviceLocked = data['isDeviceLocked'] == true;
    final locked = isKeyguardLocked || isDeviceLocked;
    final state =
        data['state'] as String? ??
        (!isInteractive
            ? 'screen_off'
            : locked
            ? 'locked'
            : 'user_present');
    final systemWindow = data['systemWindow'] as String?;

    return AndroidDeviceState(
      isInteractive: isInteractive,
      isKeyguardLocked: isKeyguardLocked,
      isDeviceLocked: isDeviceLocked,
      state: state,
      systemWindow: systemWindow,
      updatedAt:
          DeviceInfo._parseAndroidWindowUpdatedAt(data['updatedAt']) ??
          fallbackUpdatedAt ??
          DateTime.now(),
    );
  }

  bool get isLocked => isKeyguardLocked || isDeviceLocked;

  bool get isUserPresent => isInteractive && !isLocked;
}
