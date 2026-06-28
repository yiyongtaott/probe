import 'dart:async';

import '../engine/attention_tracker.dart';
import '../engine/topic_engine.dart';
import '../models/models.dart';
import '../storage/database.dart';
import '../ai/ai_provider.dart';
import '../ai/topic_generation_debug.dart';
import 'notification_service.dart';
import 'ai_config_manager.dart';

/// ── 后台服务编排器 ──────────────────────────────────────
class BackgroundOrchestrator {
  static BackgroundOrchestrator? _instance;
  static BackgroundOrchestrator get instance =>
      _instance ??= BackgroundOrchestrator._();

  BackgroundOrchestrator._();

  /// 最后一次 AI 操作的错误（供调试面板读取）
  static String? lastAiError;

  /// 最后一次话题生成的调试数据（供调试面板可视化展示）
  static TopicGenerationDebug? lastTopicDebug;

  final AttentionTracker _attention = AttentionTracker(
    onAttentionRelease: _onAttentionRelease,
  );

  bool _running = false;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    await NotificationService.init();
    _attention.start();

    Timer.periodic(const Duration(hours: 24), (_) {
      LocalDatabase.cleanupOldMaterials(keepDays: 7);
    });
  }

  void stop() {
    _attention.stop();
    _running = false;
  }

  /// ── 注意力释放回调：生成话题 + 写入文件供弹窗读取 ──────
  static Future<void> _onAttentionRelease(String reason) async {
    if (!await AttentionTracker.hasEnoughMaterial()) return;

    final config = await AiConfigManager.load();
    if (!config.isConfigured) return;

    final provider = createAiProvider(config);
    final engine = TopicEngine(provider);
    final suggestion = await engine.generateTopic();
    provider.dispose();

    if (suggestion == null) return;

    // 写入 AI 话题文件，供 Kotlin TopicPopupActivity 读取
    // 从 reason 中提取 app 名称
    final appMatch = RegExp(r'attention_release: (.+) \(\d+s\)').firstMatch(reason);
    final appName = appMatch?.group(1) ?? '浏览';
    await AttentionTracker.writeAiTopicToFile(suggestion.question, appName);

    // 发送系统通知
    await NotificationService.showTopicNotification(
      title: '今天的话题',
      body: suggestion.question,
      payload: suggestion.id?.toString(),
    );
  }

  Future<TopicSuggestion?> generateTopicNow() async {
    final config = await AiConfigManager.load();
    if (!config.isConfigured) {
      lastAiError = 'AI 未配置';
      lastTopicDebug = null;
      return null;
    }

    final provider = createAiProvider(config);
    final engine = TopicEngine(provider);
    final debug = await engine.generateTopicWithDebug();
    lastAiError = provider.lastError;
    lastTopicDebug = debug;
    provider.dispose();
    return debug?.suggestion;
  }

  Future<List<String>> clusterMaterialsNow() async {
    final config = await AiConfigManager.load();
    if (!config.isConfigured) return [];

    final provider = createAiProvider(config);
    final engine = TopicEngine(provider);
    final topics = await engine.clusterTodayMaterials();
    provider.dispose();
    return topics;
  }

  bool get isRunning => _running;

  AttentionSnapshot get attentionSnapshot => _attention.currentSnapshot;
}
