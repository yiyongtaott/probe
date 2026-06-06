// ═══════════════════════════════════════════════════════════════
// App B — 全功能 App（网页版 CF 超集）
// 对标 worker.js 前端所有功能 + 后台静默上报
// 通过 Isolate 分离 UI 和上报引擎
// ═══════════════════════════════════════════════════════════════
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'shared/background/reporter_service.dart';
import 'shared/utils/device_info.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 在后台 Isolate 中运行上报引擎（不卡 UI 线程）
  await Isolate.spawn((message) {
    final reporter = ReporterService(
      deviceId: 'phone',
      serverBase: DeviceInfo.defaultServerBase,
    );
    reporter.startContinuousLoop();
  }, null);

  // 主 Isolate：全功能 UI
  runApp(const ProviderScope(child: ProbeFullApp()));
}

class ProbeFullApp extends StatelessWidget {
  const ProbeFullApp({super.key});

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
      home: const DashboardPage(),
    );
  }
}

// ── 主页占位（后续填充完整 UI） ─────────────────────────────
class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UltraLightProbe')),
      body: const Center(
        child: Text(
          'Dashboard — 待对接完整 UI',
          style: TextStyle(color: Colors.white38),
        ),
      ),
    );
  }
}
