import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'shared/services/background_service.dart';
import 'shared/services/notification_service.dart';
import 'shared/storage/database.dart';
import 'shared/utils/device_info.dart';
import 'ui/home_page.dart';
import 'ui/material_page.dart';
import 'ui/chat_page.dart';
import 'ui/conversations_page.dart';
import 'ui/settings_page.dart';
import 'ui/debug_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TulpaTopicApp());
}

class TulpaTopicApp extends StatelessWidget {
  const TulpaTopicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tulpa Topic Engine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C5CE7),
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: const MainScaffold(),
    );
  }
}

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _currentIndex = 0;
  final _orchestrator = BackgroundOrchestrator.instance;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    // 初始化数据库
    await LocalDatabase.database;

    // 初始化通知
    await NotificationService.init();

    // 设置通知点击回调
    NotificationService.onTopicNotificationTap = (payload) async {
      if (payload != null) {
        // 切换到对话页并开始新会话
        setState(() => _currentIndex = 2);
        final suggestionId = int.tryParse(payload);
        if (suggestionId != null) {
          // 通过 ID 从数据库查找话题文本（含已使用的）
          final suggestion =
              await LocalDatabase.getSuggestionById(suggestionId);
          final topic = suggestion?.question ?? '通知话题';
          chatPageKey.currentState?.startNewSession(topic, suggestionId);
        } else {
          chatPageKey.currentState?.startNewSession('通知话题', null);
        }
      }
    };

    // Android: 检查无障碍权限并启动后台监控
    if (Platform.isAndroid) {
      final hasAccess = await DeviceInfo.hasAccessibilityAccess();
      if (hasAccess) {
        await _orchestrator.start();
      } else {
        // 延迟提示用户开启无障碍
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _promptAccessibility();
        });
      }
    }
  }

  void _promptAccessibility() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要无障碍服务'),
        content: const Text(
          'Tulpa Topic Engine 需要开启无障碍服务来采集浏览标题。\n\n'
          '仅收集页面标题和 App 来源，不保存正文、图片或输入内容。\n\n'
          '请在设置中找到「TulpaTopic」并开启。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await DeviceInfo.openAccessibilitySettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const HomePage(),
      const MaterialPoolPage(),
      ChatPage(key: chatPageKey),
      const ConversationsPage(),
      const SettingsPage(),
      const DebugPage(),
    ];

    final labels = ['首页', '素材池', '对话', '记录', '设置', '调试'];
    final icons = <IconData>[
      Icons.home_outlined,
      Icons.category_outlined,
      Icons.chat_bubble_outline,
      Icons.history,
      Icons.settings_outlined,
      Icons.bug_report_outlined,
    ];
    final activeIcons = <IconData>[
      Icons.home,
      Icons.category,
      Icons.chat_bubble,
      Icons.history,
      Icons.settings,
      Icons.bug_report,
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: List.generate(labels.length, (i) {
          return NavigationDestination(
            icon: Icon(icons[i]),
            selectedIcon: Icon(activeIcons[i]),
            label: labels[i],
          );
        }),
      ),
    );
  }
}
