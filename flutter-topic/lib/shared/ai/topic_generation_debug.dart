import 'dart:convert';
import '../models/models.dart';

/// ── 话题生成中间数据（调试可视化用） ────────────────────
class TopicGenerationDebug {
  /// 发送给 AI 的 System Prompt
  final String systemPrompt;

  /// 发送给 AI 的 User Prompt
  final String userPrompt;

  /// 原始素材列表（去重排序前的原始数据）
  final List<MaterialItem> rawMaterials;

  /// 经过算法合并压缩后的聚类数据
  final List<TopicCluster> rankedClusters;

  /// AI 返回的结果
  final String? result;

  /// 话题建议（如果生成成功）
  final TopicSuggestion? suggestion;

  const TopicGenerationDebug({
    required this.systemPrompt,
    required this.userPrompt,
    required this.rawMaterials,
    required this.rankedClusters,
    this.result,
    this.suggestion,
  });

  /// 格式化原始素材 JSON 用于展示
  String get formattedRawMaterials {
    final list = rawMaterials.map((m) => {
      'title': m.title,
      'sourceApp': m.sourceApp,
      'weight': m.weight,
      'time': DateTime.fromMillisecondsSinceEpoch(m.timestamp)
          .toIso8601String()
          .substring(11, 19),
    }).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }

  /// 格式化聚类数据 JSON 用于展示
  String get formattedRankedClusters {
    final list = rankedClusters.map((c) => {
      'topic': c.topic,
      'score': double.parse(c.totalWeight.toStringAsFixed(2)),
      'count': c.count,
      'sources': c.sourceApps.toList(),
      'lastSeen': DateTime.fromMillisecondsSinceEpoch(c.lastSeen)
          .toIso8601String()
          .substring(11, 19),
    }).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }
}
