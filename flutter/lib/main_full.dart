// ═══════════════════════════════════════════════════════════════
// App B — 全功能 App
// Windows: Flutter 壳 + 原生 C probe 后台线程 + WebView2 控制台
// Android/iOS/macOS: Flutter 壳 + Dart ReporterService + WebView 控制台
// ═══════════════════════════════════════════════════════════════
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile_webview;
import 'package:webview_windows/webview_windows.dart' as windows_webview;
import 'package:workmanager/workmanager.dart';

import 'shared/api/server_selector.dart';
import 'shared/background/reporter_service.dart';
import 'shared/utils/device_info.dart';
import 'shared/utils/probe_log.dart';

/// 全局服务器 URL（启动时探测决定主/备）
String activeServerBase = ServerSelector.primary;

@pragma('vm:entry-point')
void _reporterIsolate(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final reporter = ReporterService(deviceId: args[0], serverBase: args[1]);
  unawaited(reporter.startContinuousLoop());
}

@pragma('vm:entry-point')
void _androidWorkmanagerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    try {
      final deviceId =
          inputData?['deviceId'] as String? ?? DeviceInfo.detectDeviceIdSync();
      final serverBase =
          inputData?['serverBase'] as String? ??
          await ServerSelector().probeAndFailover();
      await ProbeLog.info('workmanager task=$task device=$deviceId');

      final reporter = ReporterService(
        deviceId: deviceId,
        serverBase: serverBase,
      );
      await reporter.onWake();
      return true;
    } catch (e, st) {
      await ProbeLog.error('workmanager failed', e, st);
      return false;
    }
  });
}

@pragma('vm:entry-point')
Future<void> _androidServiceOnStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final deviceId = DeviceInfo.detectDeviceIdSync();
  final serverBase = await ServerSelector().probeAndFailover();
  final reporter = ReporterService(deviceId: deviceId, serverBase: serverBase);

  Future<void> runOnce(String reason) async {
    try {
      await ProbeLog.info('service wake reason=$reason device=$deviceId');
      await reporter.onWake();
      if (service is AndroidServiceInstance) {
        await service.setForegroundNotificationInfo(
          title: 'UltraLightProbe',
          content: '最近上报: ${DateTime.now().toLocal()}',
        );
      }
    } catch (e, st) {
      await ProbeLog.error('service wake failed', e, st);
    }
  }

  if (service is AndroidServiceInstance) {
    try {
      await service.setAutoStartOnBootMode(true);
    } catch (e, st) {
      await ProbeLog.error('enable boot autostart failed', e, st);
    }
  }

  service.on('stopService').listen((_) {
    service.stopSelf();
  });
  service.on('runNow').listen((_) {
    unawaited(runOnce('manual'));
  });

  await runOnce('start');
  Timer.periodic(const Duration(seconds: 120), (_) {
    unawaited(runOnce('timer'));
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 探测服务器地址（主优先，不通则切到备用）
  final selector = ServerSelector();
  activeServerBase = await selector.probeAndFailover();
  final deviceId = await DeviceInfo.detectDeviceId();

  runApp(ProbeFullApp(deviceId: deviceId));

  if (Platform.isAndroid) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_promptAndroidMonitoringAccessIfNeeded());
      unawaited(_deferInitializeAndroidReporter(deviceId, activeServerBase));
    });
  } else if (!Platform.isWindows) {
    unawaited(
      Isolate.spawn<List<String>>(_reporterIsolate, <String>[
        deviceId,
        activeServerBase,
      ]),
    );
  }
}

Future<void> _promptAndroidMonitoringAccessIfNeeded() async {
  try {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!await DeviceInfo.hasAndroidAccessibilityAccess()) {
      await ProbeLog.warn('accessibility permission missing');
      await DeviceInfo.openAndroidAccessibilitySettings();
      return;
    }

    if (await DeviceInfo.hasAndroidUsageAccess()) return;
    await ProbeLog.warn('usage access permission missing');
    await DeviceInfo.openAndroidUsageAccessSettings();
  } catch (e, st) {
    await ProbeLog.error('open usage access settings failed', e, st);
  }
}

Future<void> _deferInitializeAndroidReporter(
  String deviceId,
  String serverBase,
) async {
  await Future<void>.delayed(const Duration(seconds: 2));
  await _initializeAndroidReporter(deviceId, serverBase);
}

Future<void> _initializeAndroidReporter(
  String deviceId,
  String serverBase,
) async {
  final inputData = <String, dynamic>{
    'deviceId': deviceId,
    'serverBase': serverBase,
  };

  try {
    await ProbeLog.info('initialize android reporter device=$deviceId');

    await Workmanager().initialize(_androidWorkmanagerDispatcher);
    await Workmanager().registerOneOffTask(
      'probe_android_startup_report',
      'probeReport',
      existingWorkPolicy: ExistingWorkPolicy.replace,
      initialDelay: const Duration(seconds: 8),
      constraints: Constraints(networkType: NetworkType.connected),
      inputData: inputData,
    );
    await Workmanager().registerPeriodicTask(
      'probe_android_periodic_report',
      'probeReport',
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      constraints: Constraints(networkType: NetworkType.connected),
      inputData: inputData,
    );
  } catch (e, st) {
    await ProbeLog.error('initialize workmanager failed', e, st);
  }

  try {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _androidServiceOnStart,
        autoStart: false,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: 'probe_reporter',
        initialNotificationTitle: 'UltraLightProbe',
        initialNotificationContent: '后台监控启动中',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
    if (!await service.isRunning()) {
      await service.startService();
    }
    service.invoke('runNow');
  } catch (e, st) {
    await ProbeLog.error('initialize foreground service failed', e, st);
  }
}

class ProbeFullApp extends StatefulWidget {
  final String deviceId;
  const ProbeFullApp({super.key, required this.deviceId});

  @override
  State<ProbeFullApp> createState() => _ProbeFullAppState();
}

class _ProbeFullAppState extends State<ProbeFullApp>
    with WidgetsBindingObserver {
  bool _showWebView = false;
  bool _openingWebView = false;
  String? _webViewError;
  String? _reportStatus;
  Timer? _statusTimer;

  mobile_webview.WebViewController? _mobileController;
  windows_webview.WebviewController? _windowsController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshReportStatus());
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshReportStatus());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    unawaited(_disposeWebView(updateState: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_showWebView) {
        unawaited(_disposeWebView());
      }
    }
  }

  Future<void> _openWebView() async {
    if (_openingWebView) return;
    if (_showWebView) return;

    setState(() {
      _openingWebView = true;
      _webViewError = null;
    });

    try {
      if (Platform.isWindows) {
        await _openWindowsWebView();
      } else {
        await _openMobileWebView();
      }
      if (!mounted) return;
      setState(() => _showWebView = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _webViewError = _formatWebViewError(e));
    } finally {
      if (mounted) setState(() => _openingWebView = false);
    }
  }

  Future<void> _openMobileWebView() async {
    if (_mobileController != null) return;

    final controller = mobile_webview.WebViewController();
    await controller.setJavaScriptMode(
      mobile_webview.JavaScriptMode.unrestricted,
    );
    await controller.setNavigationDelegate(
      mobile_webview.NavigationDelegate(
        onPageFinished: (_) {
          unawaited(controller.runJavaScript(_deviceIdScript()));
        },
      ),
    );
    await controller.loadRequest(Uri.parse(activeServerBase));
    _mobileController = controller;
  }

  Future<void> _openWindowsWebView() async {
    if (_windowsController != null) return;

    final version = await windows_webview.WebviewController.getWebViewVersion();
    if (version == null) {
      throw StateError('未检测到 Microsoft Edge WebView2 Runtime。');
    }

    final controller = windows_webview.WebviewController();
    await controller.initialize();
    await controller.setBackgroundColor(const Color(0xFF0A0A0F));
    await controller.setPopupWindowPolicy(
      windows_webview.WebviewPopupWindowPolicy.allow,
    );
    await controller.addScriptToExecuteOnDocumentCreated(_deviceIdScript());
    await controller.loadUrl(activeServerBase);
    _windowsController = controller;
  }

  Future<void> _disposeWebView({bool updateState = true}) async {
    final windowsController = _windowsController;
    final mobileController = _mobileController;
    _windowsController = null;
    _mobileController = null;

    try {
      await mobileController?.clearCache();
    } catch (_) {}

    if (windowsController != null) {
      try {
        await windowsController.clearCache();
      } catch (_) {}
      try {
        await windowsController.dispose();
      } catch (_) {}
    }

    if (updateState && mounted) {
      setState(() => _showWebView = false);
    }
  }

  String _deviceIdScript() {
    final encodedDeviceId = jsonEncode(widget.deviceId);
    return '''
      try {
        localStorage.setItem('fl_device_id', $encodedDeviceId);
      } catch (_) {}
    ''';
  }

  String _formatWebViewError(Object error) {
    if (error is PlatformException) {
      return '控制台打开失败：${error.message ?? error.code}';
    }
    return '控制台打开失败：$error';
  }

  Future<void> _refreshReportStatus() async {
    if (!Platform.isAndroid) return;
    final status = await ProbeLog.lastStatusText();
    if (!mounted || status == _reportStatus) return;
    setState(() => _reportStatus = status);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'UltraLightProbe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF0EA5E9),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: _showWebView ? _buildWebView() : _buildStandbyScreen(),
        floatingActionButton:
            _showWebView
                ? null
                : FloatingActionButton.extended(
                  onPressed: _openingWebView ? null : _openWebView,
                  backgroundColor: const Color(0xFF0EA5E9),
                  icon:
                      _openingWebView
                          ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : const Icon(Icons.open_in_full),
                  label: Text(_openingWebView ? '打开中' : '打开监控面板'),
                ),
      ),
    );
  }

  Widget _buildWebView() {
    if (Platform.isWindows && _windowsController != null) {
      return windows_webview.Webview(_windowsController!);
    }
    if (_mobileController != null) {
      return mobile_webview.WebViewWidget(controller: _mobileController!);
    }
    return _buildStandbyScreen();
  }

  Widget _buildStandbyScreen() {
    return Container(
      color: const Color(0xFF0A0A0F),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x6600FF00),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'UltraLightProbe',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '设备: ${widget.deviceId}',
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0x1FFFFFFF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    Platform.isWindows ? '原生后台监控中' : '后台静默监控中',
                    style: const TextStyle(
                      color: Color(0xFF9CA3AF),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (activeServerBase != ServerSelector.primary)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '已切换到备用服务器',
                  style: TextStyle(
                    color: Colors.orange.withValues(alpha: 0.6),
                    fontSize: 11,
                  ),
                ),
              ),
            if (_webViewError != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Text(
                    _webViewError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFFCA5A5),
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            if (Platform.isAndroid && _reportStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Text(
                    '最近上报: $_reportStatus',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 32),
            Text(
              '点击下方按钮打开监控面板',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
