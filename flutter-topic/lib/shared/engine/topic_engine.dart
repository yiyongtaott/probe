import 'dart:convert';

import '../models/models.dart';
import '../storage/database.dart';
import '../ai/ai_provider.dart';
import '../ai/topic_prompt_config.dart';
import '../ai/topic_generation_debug.dart';
import '../utils/app_log.dart';
import '../utils/activity_filter.dart';

/// ── Topic Engine（核心模块） ────────────────────────────
/// design2.md 第七节：这是整个产品最重要的模块
/// 输入：今日素材池 → 输出：一个值得讨论的话题
///
/// 两个核心算法：
///   Algorithm 1: Material Ranking（浏览内容排序）
///   Algorithm 2: Topic Generation（话题生成）
class TopicEngine {
  final AiProvider _ai;

  TopicEngine(this._ai);

  // ════════════════════════════════════════════════════
  //  Algorithm 1: Material Ranking
  // ════════════════════════════════════════════════════
  // design2.md 第十三节：
  //   考虑：浏览次数、停留时间（可选）、最近浏览时间、来源类型、是否重复出现
  //   输出：Top N 素材

  /// 对素材池进行排序，返回 Top N
  static List<TopicCluster> rankMaterials(List<MaterialItem> materials) {
    if (materials.isEmpty) return [];

    // 按标题聚类（同标题 = 同主题候选）
    final titleGroups = <String, List<MaterialItem>>{};
    for (final m in materials) {
      final key = m.title.trim().toLowerCase();
      titleGroups.putIfAbsent(key, () => []).add(m);
    }

    final clusters = <TopicCluster>[];
    titleGroups.forEach((key, items) {
      if (items.isEmpty) return;
      final first = items.first;
      final count = items.length;
      final totalWeight = items.fold<double>(
        0,
        (sum, item) => sum + item.weight,
      );
      final lastSeen = items
          .map((e) => e.timestamp)
          .reduce((a, b) => a > b ? a : b);

      // ── 权重计算 ──────────────────────────────────────
      // 浏览次数：count
      // 最近浏览时间：越近权重越高
      // 来源类型：不同 App 来源更有价值
      // 重复出现：多次浏览加权
      final recencyBonus = _recencyScore(lastSeen);
      final sourceDiversity = items.map((e) => e.sourceApp).toSet().length;
      final score =
          count * 2.0 + totalWeight + recencyBonus + sourceDiversity * 0.5;

      clusters.add(TopicCluster(
        topic: first.title,
        count: count,
        totalWeight: score,
        lastSeen: lastSeen,
        sampleTitles: items.map((e) => e.title).take(5).toList(),
        sourceApps: items.map((e) => e.sourceApp).toSet(),
      ));
    });

    // 按综合权重排序
    clusters.sort((a, b) => b.totalWeight.compareTo(a.totalWeight));
    return clusters;
  }

  /// 获取今日 Top N 素材（先清理噪声再排序）
  static Future<List<TopicCluster>> getTodayTopN({int n = 8}) async {
    final materials = await LocalDatabase.getTodayMaterials();
    // 额外的安全过滤：确保 AI 收到的素材不含噪声
    final clean = materials.where((m) =>
        ActivityFilter.isMeaningfulForMaterial(m.title)).toList();
    final ranked = rankMaterials(clean);
    return ranked.take(n).toList();
  }

  /// 最近浏览时间评分：1小时内 +3，6小时内 +2，24小时内 +1
  static double _recencyScore(int timestamp) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ageHours = (now - timestamp) / (1000 * 60 * 60);
    if (ageHours < 1) return 3.0;
    if (ageHours < 6) return 2.0;
    if (ageHours < 24) return 1.0;
    return 0;
  }

  // ════════════════════════════════════════════════════
  //  Algorithm 2: Topic Generation
  // ════════════════════════════════════════════════════
  // design2.md 第十三节：
  //   输入：Top N 素材 → 输出：一个自然的问题
  //   要求：不评价宿主、不扮演 Tulpa、不生成设定、只负责打开讨论

  /// 生成讨论话题（含完整中间数据，供调试可视化）
  /// [topClusters] 已排序的 Top N 素材聚类
  /// [customSystemPrompt] 自定义系统提示词（覆盖全局配置）
  /// [extraRequirement] 用户附加要求（对话页引入话题时使用）
  /// [historyContext] 历史话题上下文
  /// [conversationContext] 对话上下文
  /// [foregroundApp] 当前前台 App 信息
  Future<TopicGenerationDebug?> generateTopicWithDebug({
    List<TopicCluster>? topClusters,
    String? customSystemPrompt,
    String? extraRequirement,
    String? historyContext,
    String? conversationContext,
    String? foregroundApp,
  }) async {
    final rawMaterials = await LocalDatabase.getTodayMaterials();
    final cleanMaterials = rawMaterials
        .where((m) => ActivityFilter.isMeaningfulForMaterial(m.title))
        .toList();
    final clusters = topClusters ??
        rankMaterials(cleanMaterials).take(8).toList();
    if (clusters.isEmpty) return null;

    final materialList = clusters
        .map((c) =>
            '- ${c.topic}（来源：${_sourceLabel(c)}，出现 ${c.count} 次）')
        .join('\n');

    // 使用自定义提示词，或从全局配置加载
    final systemPrompt = customSystemPrompt ?? await TopicPromptConfig.load();

    // 构建 user prompt
    final foregroundContext = foregroundApp != null && foregroundApp.isNotEmpty
        ? '当前前台 App: $foregroundApp\n\n'
        : '';
    final extraCtx = extraRequirement != null && extraRequirement.isNotEmpty
        ? '用户额外要求: $extraRequirement\n\n'
        : '';
    final histCtx = historyContext ?? '';
    final convCtx = conversationContext ?? '';

    final userPrompt = '今天宿主浏览了以下内容（已按关注度排序）：\n\n'
        '$materialList\n\n'
        '${histCtx}${convCtx}${foregroundContext}${extraCtx}'
        '请融合这些素材，生成一个值得讨论的话题问题。';

    final result = await _ai.chatCompletion(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: 0.85,
      maxTokens: 200,
    );

    TopicSuggestion? suggestion;
    if (result != null && result.trim().isNotEmpty) {
      final question = result.trim().replaceAll(RegExp(r'^["""「]|["""」]$'), '');

      suggestion = TopicSuggestion(
        topic: clusters.take(3).map((c) => c.topic).join('、'),
        question: question,
        context: materialList,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      final id = await LocalDatabase.insertTopicSuggestion(suggestion);
      suggestion = TopicSuggestion(
        id: id,
        topic: suggestion.topic,
        question: suggestion.question,
        context: suggestion.context,
        createdAt: suggestion.createdAt,
      );
    } else {
      AppLog.info('topic generation returned empty result');
    }

    return TopicGenerationDebug(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      rawMaterials: cleanMaterials,
      rankedClusters: clusters,
      result: result,
      suggestion: suggestion,
    );
  }

  /// 兼容原接口（返回 TopicSuggestion?）
  Future<TopicSuggestion?> generateTopic({
    List<TopicCluster>? topClusters,
  }) async {
    final debug = await generateTopicWithDebug(topClusters: topClusters);
    return debug?.suggestion;
  }

  // ════════════════════════════════════════════════════
  //  素材聚类（AI 职责 2）
  // ════════════════════════════════════════════════════

  /// 对今日素材进行 AI 聚类，生成主题列表
  /// design2.md 第六节：经过聚类后的主题，不是浏览记录
  Future<List<String>> clusterTodayMaterials() async {
    final materials = await LocalDatabase.getTodayMaterials();
    if (materials.isEmpty) return [];

    // 只取有意义的素材，去重排序
    final meaningful = materials
        .where((m) => ActivityFilter.isMeaningfulForMaterial(m.title))
        .map((m) => m.title)
        .toSet()
        .toList();
    if (meaningful.isEmpty) return [];

    final titles = meaningful.take(30).join('\n');

    final systemPrompt = '''你是一个素材聚类引擎。
把浏览标题聚类为简洁的主题词。
- 每个主题词 2-6 个字
- 合并相似内容
- 只输出主题词，每行一个
- 最多输出 10 个主题''';

    final userPrompt = '请对以下浏览标题进行聚类：\n\n$titles';

    final result = await _ai.chatCompletion(
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: 0.3,
      maxTokens: 200,
    );

    if (result == null) {
      AppLog.info('material clustering returned empty result');
      return [];
    }

    final topics = result
        .split('\n')
        .map((s) => s.trim().replaceAll(RegExp(r'^[\d\-.\s]+'), ''))
        .where((s) => s.isNotEmpty && s.length <= 20)
        .take(10)
        .toList();

    // 缓存到数据库
    final dateKey = _todayKey();
    await LocalDatabase.saveDailyTopics(dateKey, jsonEncode(topics));

    return topics;
  }

  String _sourceLabel(TopicCluster c) {
    return c.sourceApps.length > 1 ? '多来源' : '单一来源';
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}
