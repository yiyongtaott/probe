import 'package:flutter/material.dart';

import '../shared/engine/topic_engine.dart';
import '../shared/models/models.dart';
import '../shared/services/ai_config_manager.dart';
import '../shared/services/background_service.dart';
import '../shared/storage/database.dart';

class MaterialPoolPage extends StatefulWidget {
  const MaterialPoolPage({super.key});

  @override
  State<MaterialPoolPage> createState() => _MaterialPoolPageState();
}

class _MaterialPoolPageState extends State<MaterialPoolPage> {
  List<MaterialItem> _materials = [];
  List<TopicCluster> _clusters = [];
  bool _clustering = false;
  bool _aiConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final materials = await LocalDatabase.getTodayMaterials();
    final clusters = TopicEngine.rankMaterials(materials);
    final config = await AiConfigManager.load();
    if (mounted) {
      setState(() { _materials = materials; _clusters = clusters; _aiConfigured = config.isConfigured; });
    }
  }

  Future<void> _clusterWithAi() async {
    if (!_aiConfigured) { _showSnackBar('请先在设置中配置 AI'); return; }
    setState(() => _clustering = true);
    try {
      final topics = await BackgroundOrchestrator.instance.clusterMaterialsNow();
      _showSnackBar(topics.isNotEmpty ? '聚类完成：${topics.length} 个主题 ✨' : '素材不足或聚类失败');
      await _loadData();
    } finally { if (mounted) setState(() => _clustering = false); }
  }

  void _showSnackBar(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('今日素材池'),
        centerTitle: true,
        actions: [
          AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: _clustering
              ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)))
              : IconButton(key: const ValueKey('cluster'), icon: const Icon(Icons.auto_awesome), onPressed: _clusterWithAi, tooltip: 'AI 聚类')),
        ],
      ),
      body: _materials.isEmpty ? _buildEmpty(cs) : RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_clusters.isNotEmpty) ...[
            _SectionLabel(title: '主题聚类', icon: Icons.category_outlined, cs: cs),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: cs.surfaceContainerLow, borderRadius: BorderRadius.circular(14)),
              child: Wrap(spacing: 8, runSpacing: 8,
                children: _clusters.take(12).map((c) => _ClusterChip(cluster: c, cs: cs)).toList()),
            ),
            const SizedBox(height: 28),
          ],
          Row(children: [
            _SectionLabel(title: '浏览记录', icon: Icons.history, cs: cs),
            const SizedBox(width: 8),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Text('${_materials.length}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSecondaryContainer))),
          ]),
          const SizedBox(height: 10),
          ..._materials.map((m) => _MaterialTile(item: m, cs: cs)),
        ]),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.inbox_outlined, size: 64, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
      const SizedBox(height: 16),
      Text('今日还没有采集到浏览素材', style: TextStyle(fontSize: 16, color: cs.onSurfaceVariant)),
      const SizedBox(height: 8),
      Text('开启无障碍服务后浏览即可自动采集', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String title;
  final IconData icon;
  final ColorScheme cs;
  const _SectionLabel({required this.title, required this.icon, required this.cs});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 18, color: cs.primary),
    const SizedBox(width: 6),
    Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
  ]);
}

class _ClusterChip extends StatelessWidget {
  final TopicCluster cluster;
  final ColorScheme cs;
  const _ClusterChip({required this.cluster, required this.cs});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: cs.primaryContainer.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: cs.outlineVariant, width: 0.5),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      CircleAvatar(
        radius: 11,
        backgroundColor: cs.primary,
        child: Text('${cluster.count}', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: cs.onPrimary)),
      ),
      const SizedBox(width: 6),
      Flexible(child: Text(cluster.topic, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
    ]),
  );
}

class _MaterialTile extends StatelessWidget {
  final MaterialItem item;
  final ColorScheme cs;
  const _MaterialTile({required this.item, required this.cs});

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(item.timestamp);
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.outlineVariant, width: 0.5)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 36, height: 36,
            decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.article_outlined, color: cs.onSecondaryContainer, size: 20)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.apps, size: 13, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(child: Text(item.sourceApp, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 16),
              Icon(Icons.access_time, size: 13, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(timeStr, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ]),
          ])),
          if (item.weight > 1.0)
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: cs.tertiaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Text('×${item.weight.toStringAsFixed(0)}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onTertiaryContainer))),
        ]),
      ),
    );
  }
}
