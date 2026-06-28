import 'dart:async';
import 'package:flutter/material.dart';

import '../shared/engine/topic_engine.dart';
import '../shared/models/models.dart';
import '../shared/services/ai_config_manager.dart';
import '../shared/services/background_service.dart';
import '../shared/storage/database.dart';
import '../shared/utils/device_info.dart';
import 'dart:io' show Platform;
import 'chat_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<TopicCluster> _todayTopics = [];
  List<TopicSuggestion> _suggestions = [];
  int _materialCount = 0;
  bool _hasAccessibility = false;
  bool _aiConfigured = false;
  bool _generating = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadData();
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) => _loadData());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    final topics = await TopicEngine.getTodayTopN(n: 6);
    final suggestions = await LocalDatabase.getUnusedSuggestions();
    final count = await LocalDatabase.getTodayMaterialCount();
    final hasAccess = Platform.isAndroid
        ? await DeviceInfo.hasAccessibilityAccess()
        : true;
    final config = await AiConfigManager.load();

    if (mounted) {
      setState(() {
        _todayTopics = topics;
        _suggestions = suggestions;
        _materialCount = count;
        _hasAccessibility = hasAccess;
        _aiConfigured = config.isConfigured;
      });
    }
  }

  Future<void> _generateTopic() async {
    if (!_aiConfigured) {
      _showSnackBar('请先在设置中配置 AI');
      return;
    }
    setState(() => _generating = true);
    try {
      final suggestion =
          await BackgroundOrchestrator.instance.generateTopicNow();
      if (suggestion != null) {
        _showSnackBar('话题已生成 ✨');
      } else {
        _showSnackBar('素材不足或生成失败');
      }
      await _loadData();
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _showSnackBar(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tulpa Topic'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            onPressed: _generating ? null : _generateTopic,
            tooltip: '生成话题',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── 无障碍未启用时显眼引导 ──────────────────────
            if (!_hasAccessibility)
              _AccessibilityGuide(cs: cs, onOpenSettings: () => DeviceInfo.openAccessibilitySettings()),

            // ── 状态卡片 ────────────────────────────────────
            _StatusDashboard(
              materialCount: _materialCount,
              accessibilityOk: _hasAccessibility,
              aiOk: _aiConfigured,
              cs: cs,
            ),
            const SizedBox(height: 24),

            // ── 今日话题建议 ────────────────────────────────
            if (_suggestions.isNotEmpty) ...[
              _SectionLabel(title: '话题建议', icon: Icons.lightbulb_outline, cs: cs),
              const SizedBox(height: 10),
              ..._suggestions.map((s) => _SuggestionCard(
                    suggestion: s,
                    cs: cs,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatPage(
                            initialTopic: s.question,
                            suggestionId: s.id,
                          ),
                        ),
                      ).then((_) => _loadData());
                    },
                  )),
              const SizedBox(height: 24),
            ],

            // ── 今日素材 Top ────────────────────────────────
            _SectionLabel(title: '今日浏览 Top', icon: Icons.trending_up, cs: cs),
            const SizedBox(height: 10),
            if (_todayTopics.isEmpty)
              _EmptyState(cs: cs, text: '还没有采集到浏览素材')
            else
              ..._todayTopics.asMap().entries.map((e) =>
                  _TopicTile(rank: e.key + 1, cluster: e.value, cs: cs)),
          ],
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}

class _AccessibilityGuide extends StatelessWidget {
  final ColorScheme cs;
  final VoidCallback onOpenSettings;
  const _AccessibilityGuide({required this.cs, required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.errorContainer, cs.errorContainer.withValues(alpha: 0.6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: cs.error.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(Icons.accessibility_new, size: 48, color: cs.onErrorContainer),
          const SizedBox(height: 12),
          Text(
            '无障碍服务未启用',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: cs.onErrorContainer,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '需要开启才能自动采集浏览内容，生成讨论话题',
            style: TextStyle(fontSize: 13, color: cs.onErrorContainer),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_accessibility),
              label: const Text('前往系统设置开启', style: TextStyle(fontSize: 16)),
              style: FilledButton.styleFrom(
                backgroundColor: cs.onErrorContainer,
                foregroundColor: cs.errorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDashboard extends StatelessWidget {
  final int materialCount;
  final bool accessibilityOk;
  final bool aiOk;
  final ColorScheme cs;
  const _StatusDashboard({
    required this.materialCount,
    required this.accessibilityOk,
    required this.aiOk,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // 大数字
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.insights, color: cs.primary, size: 28),
                const SizedBox(width: 12),
                Text(
                  '$materialCount',
                  style: TextStyle(
                    fontSize: 42,
                    fontWeight: FontWeight.bold,
                    color: cs.primary,
                    height: 1.1,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '条素材',
                    style: TextStyle(
                      fontSize: 16,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // 状态行
            Row(
              children: [
                _StatusDot(label: '无障碍', ok: accessibilityOk, cs: cs),
                const SizedBox(width: 24),
                _StatusDot(label: 'AI 配置', ok: aiOk, cs: cs),
                const Spacer(),
                Text(
                  '今日',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final String label;
  final bool ok;
  final ColorScheme cs;
  const _StatusDot({required this.label, required this.ok, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: ok ? cs.primary : cs.error,
            shape: BoxShape.circle,
            boxShadow: ok
                ? [BoxShadow(color: cs.primary.withValues(alpha: 0.4), blurRadius: 4)]
                : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  final TopicSuggestion suggestion;
  final ColorScheme cs;
  final VoidCallback onTap;
  const _SuggestionCard({required this.suggestion, required this.cs, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.lightbulb, color: cs.onTertiaryContainer, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      suggestion.question,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      suggestion.topic,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopicTile extends StatelessWidget {
  final int rank;
  final TopicCluster cluster;
  final ColorScheme cs;
  const _TopicTile({required this.rank, required this.cluster, required this.cs});

  @override
  Widget build(BuildContext context) {
    final colors = [cs.primary, cs.tertiary, cs.secondary, cs.error, Color(0xFF6C63FF), Color(0xFFFF6584)];
    final color = colors[(rank - 1) % colors.length];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  '$rank',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    cluster.topic,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${cluster.count} 次 · 权重 ${cluster.totalWeight.toStringAsFixed(1)}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ColorScheme cs;
  final String text;
  const _EmptyState({required this.cs, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              text,
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
