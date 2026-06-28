import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../shared/models/models.dart';
import '../shared/services/ai_config_manager.dart';
import '../shared/ai/ai_provider.dart';
import '../shared/storage/database.dart';
import '../shared/utils/device_info.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AiConfig _config = AiConfig.defaultOpenAi();
  bool _hasAccessibility = false;
  int _materialCount = 0;
  bool _fetchingModels = false;

  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  bool _controllersReady = false;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController();
    _apiKeyController = TextEditingController();
    _modelController = TextEditingController();
    _loadData();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final config = await AiConfigManager.load();
    final hasAccess = Platform.isAndroid
        ? await DeviceInfo.hasAccessibilityAccess()
        : true;
    final count = await LocalDatabase.getTodayMaterialCount();
    if (mounted) {
      setState(() {
        _config = config;
        _hasAccessibility = hasAccess;
        _materialCount = count;
        if (!_controllersReady) {
          _baseUrlController.text = config.baseUrl;
          _apiKeyController.text = config.apiKey;
          _modelController.text = config.model;
          _controllersReady = true;
        }
      });
    }
  }

  void _switchProvider(String? v) {
    if (v == null) return;
    final preset = AiConfigManager.presets.firstWhere(
      (p) => p.provider == v,
      orElse: () => AiConfig(
        provider: v,
        baseUrl: _config.baseUrl,
        apiKey: _config.apiKey,
        model: _config.model,
      ),
    );
    setState(() {
      _config = preset;
      _baseUrlController.text = preset.baseUrl;
      _apiKeyController.text = preset.apiKey;
      _modelController.text = preset.model;
    });
  }

  Future<void> _fetchModels() async {
    if (_fetchingModels) return;
    setState(() => _fetchingModels = true);
    try {
      final provider = createAiProvider(_config);
      if (provider is! OpenAiCompatibleProvider) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('仅 OpenRouter/OpenAI 兼容 API 支持获取模型'), duration: Duration(seconds: 2)),
          );
        }
        setState(() => _fetchingModels = false);
        return;
      }
      final models = await provider.fetchModels();
      provider.dispose();
      if (!mounted) { setState(() => _fetchingModels = false); return; }
      setState(() => _fetchingModels = false);
      if (models.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取模型列表为空: ${provider.lastError ?? '无错误'}'), duration: Duration(seconds: 3)),
        );
        return;
      }
      // 弹出模型选择对话框
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('选择模型'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: models.length,
              itemBuilder: (ctx, i) => ListTile(
                title: Text(models[i], style: const TextStyle(fontSize: 14)),
                onTap: () => Navigator.pop(ctx, models[i]),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ],
        ),
      );
      if (selected != null && mounted) {
        _modelController.text = selected;
        final updated = AiConfig(
          provider: _config.provider,
          baseUrl: _config.baseUrl,
          apiKey: _config.apiKey,
          model: selected,
        );
        setState(() => _config = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已选择模型: $selected'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _fetchingModels = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取模型失败: $e'), duration: Duration(seconds: 3)),
        );
      }
    }
  }

  Future<void> _saveConfig(AiConfig config) async {
    await AiConfigManager.save(config);
    setState(() => _config = config);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('AI 配置已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── AI 配置 ──────────────────────────────────────
          _SettingsSection(
            icon: Icons.smart_toy_outlined,
            title: 'AI 配置',
            builder: (ctx) => _AiConfigForm(
              config: _config,
              baseUrlController: _baseUrlController,
              apiKeyController: _apiKeyController,
              modelController: _modelController,
              cs: cs,
              fetchingModels: _fetchingModels,
              onProviderChanged: _switchProvider,
              onConfigChanged: (c) => setState(() => _config = c),
              onFetchModels: _fetchModels,
              onSave: () => _saveConfig(_config),
            ),
          ),
          const SizedBox(height: 20),

          // ── 无障碍服务 ────────────────────────────────────
          if (Platform.isAndroid) ...[
            _SettingsSection(
              icon: Icons.accessibility_new,
              title: '无障碍服务',
              builder: (ctx) => _AccessibilityCard(
                hasAccess: _hasAccessibility,
                materialCount: _materialCount,
                cs: cs,
                onTap: () => DeviceInfo.openAccessibilitySettings(),
              ),
            ),
            const SizedBox(height: 20),
          ],

          // ── 数据管理 ──────────────────────────────────────
          _SettingsSection(
            icon: Icons.storage_outlined,
            title: '数据管理',
            builder: (ctx) => _DataManagementCard(
              cs: cs,
              onCleanup: () async {
                final deleted = await LocalDatabase.cleanupOldMaterials();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已清理 $deleted 条')),);
                }
                _loadData();
              },
              onClearAll: () => _confirmClearAll(),
            ),
          ),
          const SizedBox(height: 20),

          // ── 关于 ──────────────────────────────────────────
          _SettingsSection(
            icon: Icons.info_outline,
            title: '关于',
            builder: (ctx) => _AboutCard(cs: cs),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  void _confirmClearAll() {
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, color: cs.error, size: 24),
            const SizedBox(width: 10),
            const Flexible(child: Text('确认清除所有数据？', style: TextStyle(fontSize: 18))),
          ],
        ),
        content: const Text('此操作不可恢复，对话记录、素材池和所有数据将被永久删除。',
          style: TextStyle(fontSize: 14, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx, true);
              await LocalDatabase.clearAll();
              _loadData();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('所有数据已清除'), duration: Duration(seconds: 2)),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            child: Text('确认清除', style: TextStyle(color: cs.onError)),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════

class _SettingsSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget Function(BuildContext) builder;
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
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
          ),
        ),
        builder(context),
      ],
    );
  }
}

class _AiConfigForm extends StatefulWidget {
  final AiConfig config;
  final TextEditingController baseUrlController;
  final TextEditingController apiKeyController;
  final TextEditingController modelController;
  final ColorScheme cs;
  final bool fetchingModels;
  final ValueChanged<String?> onProviderChanged;
  final ValueChanged<AiConfig> onConfigChanged;
  final VoidCallback onFetchModels;
  final VoidCallback onSave;

  const _AiConfigForm({
    required this.config,
    required this.baseUrlController,
    required this.apiKeyController,
    required this.modelController,
    required this.cs,
    required this.fetchingModels,
    required this.onProviderChanged,
    required this.onConfigChanged,
    required this.onFetchModels,
    required this.onSave,
  });

  @override
  State<_AiConfigForm> createState() => _AiConfigFormState();
}

class _AiConfigFormState extends State<_AiConfigForm> {

  @override
  Widget build(BuildContext context) {
    final cs = widget.cs;
    final c = widget.config;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Provider 选择
            _FieldLabel(text: 'AI 提供商'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: c.provider,
              decoration: _inputDecoration(),
              items: AiConfigManager.providerNames.entries.map((e) {
                return DropdownMenuItem(value: e.key, child: Text(e.value));
              }).toList(),
              onChanged: widget.onProviderChanged,
            ),
            const SizedBox(height: 18),

            // Base URL
            _FieldLabel(text: 'API Base URL'),
            const SizedBox(height: 6),
            TextField(
              controller: widget.baseUrlController,
              decoration: _inputDecoration(hint: 'https://api.openai.com/v1'),
              style: const TextStyle(fontSize: 14),
              onChanged: (v) => widget.onConfigChanged(AiConfig(
                provider: c.provider,
                baseUrl: v,
                apiKey: c.apiKey,
                model: c.model,
              )),
            ),
            const SizedBox(height: 18),

            // API Key
            if (c.provider != 'ollama') ...[
              _FieldLabel(text: 'API Key'),
              const SizedBox(height: 6),
              _ApiKeyField(
                controller: widget.apiKeyController,
                onChanged: (v) => widget.onConfigChanged(AiConfig(
                  provider: c.provider,
                  baseUrl: c.baseUrl,
                  apiKey: v,
                  model: c.model,
                )),
              ),
              const SizedBox(height: 18),
            ],

            // Model
            Row(
              children: [
                Expanded(child: _FieldLabel(text: '模型名称')),
                // 一键获取模型按钮
                TextButton.icon(
                  onPressed: widget.fetchingModels ? null : widget.onFetchModels,
                  icon: widget.fetchingModels
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_download_outlined, size: 16),
                  label: Text(widget.fetchingModels ? '获取中…' : '获取模型', style: const TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextField(
              controller: widget.modelController,
              decoration: _inputDecoration(hint: 'gpt-4o-mini'),
              style: const TextStyle(fontSize: 14),
              onChanged: (v) => widget.onConfigChanged(AiConfig(
                provider: c.provider,
                baseUrl: c.baseUrl,
                apiKey: c.apiKey,
                model: v,
              )),
            ),
            const SizedBox(height: 24),

            // 保存按钮 + 状态
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: widget.onSave,
                      icon: const Icon(Icons.save, size: 20),
                      label: const Text('保存配置', style: TextStyle(fontSize: 15)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: c.isConfigured
                        ? cs.primaryContainer.withValues(alpha: 0.5)
                        : cs.errorContainer.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        c.isConfigured ? Icons.check_circle : Icons.warning,
                        size: 14,
                        color: c.isConfigured ? cs.primary : cs.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        c.isConfigured ? '完整' : '不完整',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: c.isConfigured ? cs.primary : cs.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({String? hint}) {
    final cs = widget.cs;
    return InputDecoration(
      hintText: hint,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: cs.outlineVariant),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(text, style: TextStyle(
      fontSize: 13, fontWeight: FontWeight.w500,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ));
  }
}

class _ApiKeyField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _ApiKeyField({required this.controller, required this.onChanged});

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: widget.controller,
      obscureText: _obscured,
      decoration: InputDecoration(
        hintText: 'sk-…',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: cs.outlineVariant)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        filled: true, fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.3),
        suffixIcon: IconButton(
          icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility, size: 20),
          onPressed: () => setState(() => _obscured = !_obscured),
          tooltip: _obscured ? '显示 API Key' : '隐藏 API Key',
        ),
      ),
      style: const TextStyle(fontSize: 14),
      onChanged: widget.onChanged,
    );
  }
}

class _AccessibilityCard extends StatelessWidget {
  final bool hasAccess;
  final int materialCount;
  final ColorScheme cs;
  final VoidCallback onTap;
  const _AccessibilityCard({
    required this.hasAccess,
    required this.materialCount,
    required this.cs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
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
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: hasAccess
                      ? cs.primaryContainer
                      : cs.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  hasAccess ? Icons.check_circle : Icons.warning_amber_rounded,
                  color: hasAccess ? cs.onPrimaryContainer : cs.onErrorContainer,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '浏览标题采集',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasAccess
                          ? '服务运行中 · 今日素材 $materialCount 条'
                          : '未开启 · 点击去设置',
                      style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
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

class _DataManagementCard extends StatelessWidget {
  final ColorScheme cs;
  final VoidCallback onCleanup;
  final VoidCallback onClearAll;
  const _DataManagementCard({
    required this.cs,
    required this.onCleanup,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        children: [
          _DataTile(
            icon: Icons.cleaning_services_outlined,
            color: cs.secondary,
            title: '清理过期素材',
            subtitle: '删除 7 天前的浏览记录',
            cs: cs,
            onTap: onCleanup,
          ),
          Divider(height: 1, indent: 60, color: cs.outlineVariant),
          _DataTile(
            icon: Icons.delete_forever,
            color: cs.error,
            title: '清除所有数据',
            subtitle: '素材池、对话记录、事实',
            cs: cs,
            onTap: onClearAll,
          ),
        ],
      ),
    );
  }
}

class _DataTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final ColorScheme cs;
  final VoidCallback onTap;
  const _DataTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.cs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.vertical(
        top: title.startsWith('清理') ? const Radius.circular(14) : Radius.zero,
        bottom: title.startsWith('清除') ? const Radius.circular(14) : Radius.zero,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  final ColorScheme cs;
  const _AboutCard({required this.cs});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [cs.primaryContainer, cs.secondaryContainer],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.lightbulb_outline, color: cs.onPrimaryContainer, size: 22),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Tulpa Topic Engine', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      SizedBox(height: 2),
                      Text('v1.0.0 · 本地运行 · 隐私优先', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, indent: 60, color: cs.outlineVariant),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.shield_outlined, color: cs.primary, size: 20),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('隐私说明', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(
                        '仅采集页面标题和 App 来源\n不保存正文、图片、视频或输入内容\n所有数据本地存储',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
