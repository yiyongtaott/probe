import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, File;

import 'package:flutter/material.dart';

import '../shared/models/models.dart';
import '../shared/services/ai_config_manager.dart';
import '../shared/services/background_service.dart';
import '../shared/services/notification_service.dart';
import '../shared/storage/database.dart';
import '../shared/utils/device_info.dart';
import '../shared/utils/app_log.dart';
import '../shared/ai/ai_provider.dart';
import '../shared/ai/topic_prompt_config.dart';
import '../shared/ai/topic_generation_debug.dart';
import '../shared/engine/profile_engine.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({super.key});

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  bool _accessibilityOk = false;
  ForegroundWindow? _foregroundWindow;
  int _materialCount = 0;
  String _currentApp = '';
  int _currentAppDuration = 0;
  String? _accessibilityJsonRaw;
  bool _busy = false;
  Timer? _refreshTimer;
  final List<String> _logLines = [];
  static const int _maxLogLines = 50;
  static const int _displayLogLines = 30;

  // ── 话题提示词配置 ──────────────────────────────────────
  String _customPrompt = '';
  late final TextEditingController _promptController;
  bool _promptSaving = false;

  // ── 话题生成调试数据折叠状态 ─────────────────────────────
  bool _debugSectionExpanded = false;
  bool _debugPromptExpanded = false;
  bool _debugRawExpanded = false;
  bool _debugRankedExpanded = false;
  bool _debugResultExpanded = false;

  // ── 白名单配置 ────────────────────────────────────────
  List<InstalledApp> _installedApps = [];
  List<String> _whitelist = [];
  bool _loadingApps = false;
  String _appSearchQuery = '';

  /// 排序后的应用列表：开启的排前面
  List<InstalledApp> get _sortedApps {
    final filtered = _appSearchQuery.isEmpty
        ? _installedApps
        : _installedApps.where((a) =>
            a.appName.toLowerCase().contains(_appSearchQuery.toLowerCase()) ||
            a.packageName.toLowerCase().contains(_appSearchQuery.toLowerCase())).toList();
    filtered.sort((a, b) {
      final aOn = _whitelist.contains(a.packageName) ? 0 : 1;
      final bOn = _whitelist.contains(b.packageName) ? 0 : 1;
      if (aOn != bOn) return aOn.compareTo(bOn);
      return a.appName.compareTo(b.appName);
    });
    return filtered;
  }

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _refreshAll());
    _refreshAll();
    _loadWhitelistData();
    _loadPrompt();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadPrompt() async {
    final prompt = await TopicPromptConfig.load();
    if (mounted) {
      setState(() {
        _customPrompt = prompt;
        _promptController.text = prompt;
      });
    }
    _addLog('话题提示词已加载 (${prompt.length} 字符)');
  }

  Future<void> _savePrompt() async {
    setState(() => _promptSaving = true);
    final text = _promptController.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('提示词不能为空'), duration: Duration(seconds: 1)),
        );
      }
      setState(() => _promptSaving = false);
      return;
    }
    await TopicPromptConfig.save(text);
    setState(() {
      _customPrompt = text;
      _promptSaving = false;
    });
    _addLog('✅ 话题提示词已保存');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('话题提示词已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _resetPrompt() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('恢复默认提示词？'),
        content: const Text('会将话题生成提示词恢复为系统默认值。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('恢复默认')),
        ],
      ),
    );
    if (confirm != true) return;
    await TopicPromptConfig.reset();
    final defaultPrompt = TopicPromptConfig.defaultPrompt;
    setState(() {
      _promptController.text = defaultPrompt;
      _customPrompt = defaultPrompt;
    });
    _addLog('✅ 已恢复默认话题提示词');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已恢复默认提示词'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _loadWhitelistData() async {
    if (!Platform.isAndroid) return;
    setState(() => _loadingApps = true);
    try {
      final whitelist = await DeviceInfo.getWhitelist();
      final apps = await DeviceInfo.getInstalledApps();
      if (mounted) {
        setState(() {
          _whitelist = whitelist;
          _installedApps = apps;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingApps = false);
    }
  }

  Future<void> _toggleWhitelist(String packageName, bool add) async {
    final updated = List<String>.from(_whitelist);
    if (add) {
      if (!updated.contains(packageName)) updated.add(packageName);
    } else {
      updated.remove(packageName);
    }
    final ok = await DeviceInfo.setWhitelist(updated);
    if (ok && mounted) {
      setState(() => _whitelist = updated);
      _addLog('白名单已更新: ${updated.length} 个应用');
    }
  }

  Future<void> _refreshAll() async {
    if (!mounted) return;

    // 无障碍状态
    final hasAccess = Platform.isAndroid
        ? await DeviceInfo.hasAccessibilityAccess()
        : true;

    // 前台窗口
    final window = await DeviceInfo.getForegroundWindow();

    // 素材数量
    final count = await LocalDatabase.getTodayMaterialCount();

    // 注意力状态
    final snapshot = BackgroundOrchestrator.instance.isRunning
        ? BackgroundOrchestrator.instance.attentionSnapshot
        : null;

    // 原始 JSON
    String? raw;
    if (Platform.isAndroid) {
      raw = await _readAccessibilityJson();
    }

    if (mounted) {
      setState(() {
        _accessibilityOk = hasAccess;
        _foregroundWindow = window;
        _materialCount = count;
        _currentApp = snapshot?.app ?? '';
        _currentAppDuration = snapshot?.durationMs ?? 0;
        _accessibilityJsonRaw = raw;
      });
    }
  }

  Future<String?> _readAccessibilityJson() async {
    const paths = <String>[
      '/data/user/0/com.example.tulpa_topic/files/tulpa_accessibility_window.json',
      '/data/data/com.example.tulpa_topic/files/tulpa_accessibility_window.json',
    ];
    for (final path in paths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final content = await file.readAsString();
        final data = jsonDecode(content);
        return const JsonEncoder.withIndent('  ').convert(data);
      } catch (_) {}
    }
    return null;
  }

  void _addLog(String msg) {
    setState(() {
      _logLines.insert(0,
          '${DateTime.now().toIso8601String().substring(11, 19)} $msg');
      if (_logLines.length > _maxLogLines) {
        _logLines.removeRange(_maxLogLines, _logLines.length);
      }
    });
    AppLog.info('[DEBUG] $msg');
  }

  Future<void> _forceAddTestMaterial() async {
    final controller = TextEditingController(text: '[测试素材] 手动添加的调试标题');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('添加测试素材'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '素材名称',
            helperText: '输入要添加到素材池的测试标题',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await LocalDatabase.insertMaterial(MaterialItem(
      title: name,
      sourceApp: '调试',
      timestamp: now,
      weight: 1.0,
    ));
    _addLog('已添加测试素材: $name');
    _refreshAll();
  }

  Future<void> _forceNotification() async {
    await NotificationService.showTopicNotification(
      title: '测试通知',
      body: '这是一条调试用的测试通知',
      payload: 'test',
    );
    _addLog('已发送测试通知');
  }

  Future<void> _testAiConnection() async {
    if (_busy) return;
    setState(() => _busy = true);
    _addLog('🔌 测试 AI 连接...');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在测试 AI 连接…'), duration: Duration(seconds: 1)),
      );
    }
    try {
      final config = await AiConfigManager.load();
      if (!config.isConfigured) {
        _addLog('⚠️ AI 未配置，请先在设置页填写 API 信息');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('⚠️ AI 未配置'), duration: Duration(seconds: 2)),
          );
        }
        setState(() => _busy = false);
        return;
      }
      final provider = createAiProvider(config);
      _addLog('请求: POST ${config.baseUrl}/chat/completions');
      _addLog('模型: ${config.model}');
      final result = await provider.chatCompletion(
        systemPrompt: '你是一个助手。',
        userPrompt: '用一句话回复"测试成功"。',
        maxTokens: 50,
      );
      final lastErr = provider.lastError;
      provider.dispose();
      if (result != null) {
        _addLog('✅ AI 连接成功: ${result.length} 字符');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ AI 连接成功: $result'), duration: Duration(seconds: 3)),
          );
        }
      } else if (lastErr != null) {
        _addLog('❌ AI 连接失败: $lastErr');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('❌ $lastErr'), duration: Duration(seconds: 4)),
          );
        }
      } else {
        _addLog('❌ AI 连接失败（未知错误）');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ AI 连接失败'), duration: Duration(seconds: 2)),
          );
        }
      }
    } catch (e) {
      _addLog('❌ AI 连接错误: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ AI 连接错误: $e'), duration: Duration(seconds: 3)),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _forceCompileProfiles() async {
    if (_busy) return;
    setState(() => _busy = true);
    _addLog('👤 更新成员档案...');
    await ProfileEngine.compileAllProfiles();
    _addLog('✅ 档案已更新');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _forceGenerateTopic() async {
    if (_busy) return;
    setState(() => _busy = true);
    _addLog('🤖 手动生成话题...');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在生成话题…'), duration: Duration(seconds: 1)),
      );
    }
    try {
      if (!BackgroundOrchestrator.instance.isRunning) {
        _addLog('⚠️ 后台服务未运行，尝试直接生成…');
      }
      final suggestion = await BackgroundOrchestrator.instance.generateTopicNow();
      if (suggestion != null) {
        _addLog('✅ 话题已生成: ${suggestion.question}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ ${suggestion.question}'), duration: Duration(seconds: 3)),
          );
        }
      } else {
        final err = BackgroundOrchestrator.lastAiError;
        if (err != null) {
          _addLog('❌ 话题生成失败: $err');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('❌ $err'), duration: Duration(seconds: 4)),
            );
          }
        } else {
          _addLog('❌ 话题生成失败（素材不足或 AI 返回空）');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('❌ 话题生成失败'), duration: Duration(seconds: 2)),
            );
          }
        }
      }
    } catch (e) {
      _addLog('❌ 生成话题错误: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ 错误: $e'), duration: Duration(seconds: 3)),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
    _refreshAll();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('调试面板'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ═══════════ 无障碍状态 ═══════════
          _SectionHeader(icon: Icons.accessibility_new, title: '无障碍服务'),
          const SizedBox(height: 8),
          _StatusBadge(
            label: _accessibilityOk ? '服务运行中' : '未启用',
            color: _accessibilityOk ? cs.primary : cs.error,
            icon: _accessibilityOk ? Icons.check_circle : Icons.warning_amber_rounded,
          ),
          const SizedBox(height: 20),

          // ═══════════ 当前前台窗口 ═══════════
          _SectionHeader(icon: Icons.window, title: '前台窗口'),
          const SizedBox(height: 8),
          _InfoCard(items: [
            _InfoItem('显示', _foregroundWindow?.display ?? '—'),
            _InfoItem('包名', _foregroundWindow?.packageName ?? '—'),
            _InfoItem('标题', _foregroundWindow?.title ?? '(无标题)'),
            _InfoItem('App', _foregroundWindow?.appLabel ?? '—'),
            _InfoItem('更新时间',
                _foregroundWindow != null
                    ? _foregroundWindow!.updatedAt.toIso8601String()
                    : '—',
                mono: true),
          ]),
          const SizedBox(height: 20),

          // ═══════════ 运行状态 ═══════════
          _SectionHeader(icon: Icons.monitor_heart_outlined, title: '运行状态'),
          const SizedBox(height: 8),
          _InfoCard(items: [
            _InfoItem('今日素材', '$_materialCount 条'),
            _InfoItem('当前 App', _currentApp.isEmpty ? '—' : _currentApp),
            _InfoItem('持续时长',
                _currentAppDuration > 0 ? '${_currentAppDuration ~/ 1000}s' : '—'),
            _InfoItem('后台服务',
                BackgroundOrchestrator.instance.isRunning ? '运行中' : '已停止'),
          ]),
          const SizedBox(height: 20),

          // ═══════════ 测试按钮 ═══════════
          _SectionHeader(icon: Icons.science_outlined, title: '手动测试'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _TestChip(
                label: '添加测试素材',
                icon: Icons.add_circle_outline,
                onPressed: _forceAddTestMaterial,
                cs: cs,
              ),
              _TestChip(
                label: '发送测试通知',
                icon: Icons.notifications_outlined,
                onPressed: _forceNotification,
                cs: cs,
              ),
              _TestChip(
                label: '测试 AI 连接',
                icon: _busy ? null : Icons.wifi_find,
                loading: _busy,
                onPressed: _testAiConnection,
                cs: cs,
              ),
              _TestChip(
                label: '手动生成话题',
                icon: Icons.auto_awesome,
                onPressed: _forceGenerateTopic,
                cs: cs,
              ),
              _TestChip(
                label: '更新成员档案',
                icon: Icons.person_outline,
                onPressed: _forceCompileProfiles,
                cs: cs,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ═══════════ 话题生成调试数据 ═══════════
          _SectionHeader(icon: Icons.visibility, title: '话题生成数据'),
          const SizedBox(height: 8),
          _buildTopicDebugData(cs),
          const SizedBox(height: 24),

          // ═══════════ 话题提示词配置 ═══════════
          _SectionHeader(icon: Icons.edit_note, title: '话题提示词配置'),
          const SizedBox(height: 4),
          _buildPromptConfig(cs),
          const SizedBox(height: 24),

          // ═══════════ 白名单配置 ═══════════
          _SectionHeader(icon: Icons.shield_outlined, title: '抓取白名单'),
          const SizedBox(height: 8),
          _WhitelistCard(
            apps: _sortedApps,
            whitelist: _whitelist,
            loading: _loadingApps,
            searchQuery: _appSearchQuery,
            onSearchChanged: (v) => setState(() => _appSearchQuery = v),
            onToggle: _toggleWhitelist,
            onRefresh: _loadWhitelistData,
            cs: cs,
          ),
          const SizedBox(height: 24),

          // ═══════════ 无障碍原始 JSON ═══════════
          _SectionHeader(icon: Icons.code, title: '原始无障碍 JSON'),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: cs.outlineVariant, width: 0.5),
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              child: SelectableText(
                _accessibilityJsonRaw ?? '（无法读取）',
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ═══════════ 日志 ═══════════
          _SectionHeader(icon: Icons.history, title: '调试日志'),
          const SizedBox(height: 8),
          if (_logLines.isNotEmpty)
            Row(
              children: [
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _logLines.clear()),
                  icon: const Icon(Icons.cleaning_services, size: 16),
                  label: const Text('清空', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          const SizedBox(height: 4),
          if (_logLines.isEmpty)
            _buildEmptyLog(cs)
          else
            Card(
              elevation: 0,
              color: cs.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: cs.outlineVariant, width: 0.5),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _logLines
                      .take(_displayLogLines)
                      .map((line) => Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: SelectableText(
                              line,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: cs.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Widget _buildEmptyLog(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(Icons.inbox_outlined, size: 36, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Text(
              '暂无日志',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  /// ── 话题生成调试数据可视化 ──────────────────────────────
  Widget _buildTopicDebugData(ColorScheme cs) {
    final debug = BackgroundOrchestrator.lastTopicDebug;
    if (debug == null) {
      return Card(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: cs.outlineVariant, width: 0.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(Icons.hourglass_empty, size: 32, color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
              const SizedBox(height: 8),
              Text('点击「手动生成话题」后显示',
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        children: [
          // 📝 AI 提示词
          _DebugDataTile(
            icon: Icons.auto_awesome,
            title: 'AI 提示词',
            subtitle: 'System Prompt + User Prompt',
            expanded: _debugPromptExpanded,
            cs: cs,
            onToggle: () => setState(() => _debugPromptExpanded = !_debugPromptExpanded),
            content: '''╔═ System Prompt ═╗
${debug.systemPrompt}

╔═ User Prompt ═╗
${debug.userPrompt}''',
          ),
          Divider(height: 1, indent: 56, color: cs.outlineVariant),
          // 📦 原始素材
          _DebugDataTile(
            icon: Icons.inventory_2,
            title: '原始素材',
            subtitle: '${debug.rawMaterials.length} 条去噪后的素材',
            expanded: _debugRawExpanded,
            cs: cs,
            onToggle: () => setState(() => _debugRawExpanded = !_debugRawExpanded),
            content: debug.formattedRawMaterials,
          ),
          Divider(height: 1, indent: 56, color: cs.outlineVariant),
          // 🔗 合并压缩后
          _DebugDataTile(
            icon: Icons.compress,
            title: '合并压缩后',
            subtitle: '${debug.rankedClusters.length} 个聚类（算法合并）',
            expanded: _debugRankedExpanded,
            cs: cs,
            onToggle: () => setState(() => _debugRankedExpanded = !_debugRankedExpanded),
            content: debug.formattedRankedClusters,
          ),
          Divider(height: 1, indent: 56, color: cs.outlineVariant),
          // 🤖 AI 返回
          _DebugDataTile(
            icon: Icons.smart_toy,
            title: 'AI 返回结果',
            subtitle: debug.result != null
                ? '${debug.result!.length} 字符'
                : '（空 — 生成失败）',
            expanded: _debugResultExpanded,
            cs: cs,
            onToggle: () => setState(() => _debugResultExpanded = !_debugResultExpanded),
            content: debug.result ?? 'AI 返回为空或生成失败',
          ),
        ],
      ),
    );
  }

  /// ── 话题提示词配置 ──────────────────────────────────────
  Widget _buildPromptConfig(ColorScheme cs) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '全局提示词（System Prompt）',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: cs.onSurfaceVariant),
                  ),
                ),
                Text(
                  '${_customPrompt.length} 字符',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '修改后影响所有话题生成（调试页 + 对话页）',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.7)),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _promptController,
              maxLines: 8,
              minLines: 5,
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                contentPadding: const EdgeInsets.all(14),
              ),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace', height: 1.4),
              onChanged: (v) => setState(() => _customPrompt = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _resetPrompt,
                  icon: const Icon(Icons.restore, size: 16),
                  label: const Text('恢复默认', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _promptSaving ? null : _savePrompt,
                  icon: _promptSaving
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 16),
                  label: Text(_promptSaving ? '保存中…' : '保存提示词', style: const TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: cs.onPrimaryContainer),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  const _StatusBadge({required this.label, required this.color, required this.icon});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
          const Spacer(),
          Icon(Icons.refresh, size: 16, color: cs.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _InfoItem {
  final String label;
  final String value;
  final bool mono;
  _InfoItem(this.label, this.value, {this.mono = false});
}

class _InfoCard extends StatelessWidget {
  final List<_InfoItem> items;
  const _InfoCard({required this.items});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: items.map((item) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 64,
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item.value,
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: item.mono ? 'monospace' : null,
                        fontWeight: FontWeight.w500,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _TestChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool loading;
  final VoidCallback? onPressed;
  final ColorScheme cs;
  const _TestChip({
    required this.label,
    this.icon,
    this.loading = false,
    required this.onPressed,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      onPressed: loading ? null : onPressed,
      backgroundColor: cs.secondaryContainer.withValues(alpha: 0.4),
      side: BorderSide(color: cs.outlineVariant, width: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  话题生成调试数据卡片
// ═══════════════════════════════════════════════════════════

class _DebugDataTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool expanded;
  final ColorScheme cs;
  final VoidCallback onToggle;
  final String content;

  const _DebugDataTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.expanded,
    required this.cs,
    required this.onToggle,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        color: expanded ? cs.primaryContainer.withValues(alpha: 0.08) : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: expanded
                          ? cs.primary.withValues(alpha: 0.1)
                          : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 18, color: expanded ? cs.primary : cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subtitle,
                          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.expand_more, size: 20, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    content,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              crossFadeState: expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  白名单卡片
// ═══════════════════════════════════════════════════════════

class _WhitelistCard extends StatelessWidget {
  final List<InstalledApp> apps;
  final List<String> whitelist;
  final bool loading;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final void Function(String, bool) onToggle;
  final VoidCallback onRefresh;
  final ColorScheme cs;

  const _WhitelistCard({
    required this.apps,
    required this.whitelist,
    required this.loading,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onToggle,
    required this.onRefresh,
    required this.cs,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '已启用 ${whitelist.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                if (loading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: onRefresh,
                    tooltip: '刷新应用列表',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              decoration: InputDecoration(
                hintText: '搜索应用名称或包名…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
              ),
              onChanged: onSearchChanged,
            ),
            const SizedBox(height: 8),
            if (apps.isEmpty && !loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    '点击刷新按钮加载已安装应用',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: apps.length,
                  itemBuilder: (context, index) {
                    final app = apps[index];
                    final isOn = whitelist.contains(app.packageName);
                    return Container(
                      margin: const EdgeInsets.only(bottom: 2),
                      decoration: BoxDecoration(
                        color: isOn
                            ? cs.primaryContainer.withValues(alpha: 0.15)
                            : null,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        leading: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isOn ? cs.primary : cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            isOn ? Icons.check_circle : Icons.circle_outlined,
                            color: isOn ? cs.primary : cs.outline,
                            size: 18,
                          ),
                        ),
                        title: Text(
                          app.appName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isOn ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          app.packageName,
                          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Switch(
                          value: isOn,
                          onChanged: (v) => onToggle(app.packageName, v),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
