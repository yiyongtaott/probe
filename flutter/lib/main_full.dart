// ═══════════════════════════════════════════════════════════════
// App B — 全功能 App
// 架构：Flutter 壳 + WebView 加载 CF 网页 + 后台 Isolate 上报
//
// 内存策略：
//   后台待机时 = 8-12 MB（WebView 销毁，仅 ReporterService 运行）
//   前台打开时  = 临时增加 WebView 内存（+25-35 MB）
//   切回后台   = WebView 立即销毁，内存释放
// ═══════════════════════════════════════════════════════════════
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'shared/background/reporter_service.dart';
import 'shared/utils/device_info.dart';
import 'shared/api/server_selector.dart';

/// 全局服务器 URL（启动时探测决定主/备）
String activeServerBase = ServerSelector.primary;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 探测服务器地址（主优先，不通则切到备用）
  final selector = ServerSelector();
  activeServerBase = await selector.probeAndFailover();
  final deviceId = await DeviceInfo.detectDeviceId();

  // 后台 Isolate：上报引擎（永远存活）
  await Isolate.spawn<Null>((Null _) {
    final reporter = ReporterService(
      deviceId: deviceId,
      serverBase: activeServerBase,
    );
    reporter.startContinuousLoop();
  }, null);

  // 主 Isolate：UI 壳
  runApp(ProbeFullApp(deviceId: deviceId));
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_showWebView) {
        _webController?.clearCache();
        _webController = null;
        setState(() => _showWebView = false);
      }
    }
  }

  WebViewController? _webController;

  Future<void> _openWebView() async {
    if (_webController != null) {
      setState(() => _showWebView = true);
      return;
    }

    final controller = WebViewController();
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            controller.runJavaScript('''
              if (!localStorage.getItem('fl_device_id')) {
                localStorage.setItem('fl_device_id', '${widget.deviceId}');
              }
            ''');
          },
        ),
      );

    _webController = controller;
    if (mounted) setState(() => _showWebView = true);
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
        body: _showWebView && _webController != null
            ? WebViewWidget(controller: _webController!)
            : _buildStandbyScreen(),
        floatingActionButton: _showWebView
            ? null
            : FloatingActionButton.extended(
                onPressed: _openWebView,
                backgroundColor: const Color(0xFF0EA5E9),
                icon: const Icon(Icons.open_in_full),
                label: const Text('打开监控面板'),
              ),
      ),
    );
  }

  Widget _buildStandbyScreen() {
    return Container(
      color: const Color(0xFF0A0A0F),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12, height: 12,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.green,
                boxShadow: [BoxShadow(color: Color(0x6600FF00), blurRadius: 12, spreadRadius: 2)],
              ),
            ),
            const SizedBox(height: 16),
            const Text('UltraLightProbe', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: 2)),
            const SizedBox(height: 8),
            Text('设备: ${widget.deviceId}', style: const TextStyle(color: Color(0xFF6B7280), fontSize: 13, fontFamily: 'monospace')),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(8)),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 16),
                  SizedBox(width: 8),
                  Text('后台静默监控中', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13)),
                ],
              ),
            ),
            if (activeServerBase != ServerSelector.primary)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('⚠ 已切换到备用服务器', style: TextStyle(color: Colors.orange.withValues(alpha: 0.6), fontSize: 11)),
              ),
            const SizedBox(height: 32),
            Text('点击下方按钮打开监控面板', style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
