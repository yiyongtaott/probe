import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../shared/models/models.dart';
import '../shared/storage/database.dart';
import '../shared/engine/topic_engine.dart';
import '../shared/ai/ai_provider.dart';
import '../shared/ai/topic_prompt_config.dart';
import '../shared/services/ai_config_manager.dart';
import '../shared/utils/device_info.dart';

final GlobalKey<ChatPageState> chatPageKey = GlobalKey<ChatPageState>();

/// 输入模式
enum _InputMode { chat, topic }

class ChatPage extends StatefulWidget {
  final String? initialTopic;
  final int? suggestionId;
  final String? existingSessionId;

  const ChatPage({
    super.key,
    this.initialTopic,
    this.suggestionId,
    this.existingSessionId,
  });

  @override
  State<ChatPage> createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  String _sessionId = '';
  String _topic = '';
  List<ConversationMessage> _messages = [];
  List<ChatRole> _roles = [];
  int? _currentRoleId;
  Timer? _refreshTimer;
  bool _selectMode = false;
  final Set<int> _selectedIds = {};

  // ── 引入话题模式 ──────────────────────────────────────
  _InputMode _inputMode = _InputMode.chat;
  bool _useHistoryTopics = true;
  bool _useTopicPrompt = true;
  bool _useConversationContext = true;
  bool _topicGenerating = false;
  bool _showAutocomplete = false;
  bool _useProfiles = true;
  late FocusNode _inputFocusNode;

  @override
  void initState() {
    super.initState();
    _inputFocusNode = FocusNode();
    _inputFocusNode.addListener(_onFocusChange);
    _inputController.addListener(_onTextChanged);
    _initSession();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) => _loadMessages());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _inputController.removeListener(_onTextChanged);
    _inputController.dispose();
    _inputFocusNode.removeListener(_onFocusChange);
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_inputFocusNode.hasFocus) {
      setState(() => _showAutocomplete = false);
    }
  }

  void _onTextChanged() {
    final text = _inputController.text;
    // 检测 / 自动补全
    final startsWithSlash = text.startsWith('/');
    if (startsWithSlash && !text.startsWith('/topic') && _inputMode != _InputMode.topic) {
      setState(() => _showAutocomplete = true);
    } else {
      setState(() => _showAutocomplete = false);
    }
    // 检测 /topic 前缀
    if (text.startsWith('/topic')) {
      if (_inputMode != _InputMode.topic) {
        setState(() {
          _inputMode = _InputMode.topic;
          _useHistoryTopics = true;
          _useTopicPrompt = true;
          _useConversationContext = true;
          _useProfiles = true;
          _showAutocomplete = false;
        });
      }
    } else if (_inputMode == _InputMode.topic && !text.startsWith('/topic')) {
      // 用户删除了 /topic 前缀，退出话题模式
      setState(() {
        _inputMode = _InputMode.chat;
      });
    }
  }

  void _selectAutocomplete(String value) {
    _inputController.text = value;
    _inputController.selection = TextSelection.collapsed(offset: value.length);
    setState(() => _showAutocomplete = false);
  }

  Future<void> startNewSession(String topic, int? suggestionId) async {
    _topic = topic;
    _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    await LocalDatabase.insertConversation(Conversation(
      sessionId: _sessionId,
      topic: _topic,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (suggestionId != null) await LocalDatabase.markSuggestionUsed(suggestionId);
    await _loadRoles();
    await _loadMessages();
  }

  Future<void> _initSession() async {
    await _loadRoles();
    if (widget.existingSessionId != null) {
      _sessionId = widget.existingSessionId!;
      final conv = await LocalDatabase.getConversation(_sessionId);
      _topic = conv?.topic ?? widget.initialTopic ?? '自由对话';
      await _loadMessages();
      return;
    }
    _topic = widget.initialTopic ?? '自由对话';
    _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    await LocalDatabase.insertConversation(Conversation(
      sessionId: _sessionId, topic: _topic,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    if (widget.suggestionId != null) await LocalDatabase.markSuggestionUsed(widget.suggestionId!);
    await _loadMessages();
  }

  Future<void> _loadRoles() async {
    var roles = await LocalDatabase.getAllRoles();
    if (roles.isEmpty) {
      await LocalDatabase.initDefaultRoles();
      roles = await LocalDatabase.getAllRoles();
    }
    if (mounted) setState(() {
      _roles = roles;
      if (_currentRoleId == null && roles.isNotEmpty) _currentRoleId = roles.first.id;
    });
  }

  int _lastMsgCount = 0;
  Future<void> _loadMessages({bool forceScroll = false}) async {
    final msgs = await LocalDatabase.getMessages(_sessionId);
    if (mounted) {
      setState(() {
        final newMsgCount = msgs.length;
        final shouldScroll = forceScroll || newMsgCount > _lastMsgCount;
        _messages = msgs;
        _lastMsgCount = newMsgCount;
        if (shouldScroll) _scrollToBottom();
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    if (_inputMode == _InputMode.topic) {
      await _sendTopicMessage(text);
      return;
    }

    await LocalDatabase.insertMessage(ConversationMessage(
      sessionId: _sessionId, text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      roleId: _currentRoleId,
    ));
    _inputController.clear();
    await _loadMessages(forceScroll: true);
  }

  /// ── 引入话题模式 ──────────────────────────────────────
  Future<void> _sendTopicMessage(String rawText) async {
    // 去掉 /topic 前缀
    final requirement = rawText.replaceFirst(RegExp(r'^/topic\s*'), '').trim();

    setState(() {
      _topicGenerating = true;
    });

    // 先写入用户消息
    final displayText = requirement.isNotEmpty
        ? '/topic $requirement'
        : '/topic';
    await LocalDatabase.insertMessage(ConversationMessage(
      sessionId: _sessionId, text: displayText,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      roleId: _currentRoleId,
    ));
    _inputController.clear();

    try {
      final config = await AiConfigManager.load();
      if (!config.isConfigured) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('AI 未配置，请先在设置页填写 API 信息'), duration: Duration(seconds: 2)),
          );
        }
        setState(() {
          _topicGenerating = false;
        });
        await _loadMessages();
        return;
      }

      // 收集素材
      final clusters = await TopicEngine.getTodayTopN(n: 8);
      final materialList = clusters
          .map((c) =>
              '- ${c.topic}（来源：${c.sourceApps.length > 1 ? '多来源' : '单一来源'}，出现 ${c.count} 次）')
          .join('\n');

      // 历史话题
      String historyContext = '';
      if (_useHistoryTopics) {
        final suggestions = await LocalDatabase.getUnusedSuggestions();
        if (suggestions.isNotEmpty) {
          final historyLines = suggestions
              .take(5)
              .map((s) => '- ${s.question}')
              .join('\n');
          historyContext = '历史话题参考：\n$historyLines\n\n';
        }
      }

      // 对话上下文
      String conversationContext = '';
      if (_useConversationContext && _messages.length >= 2) {
        final recentMsgs = _messages
            .where((m) => m.roleId == _currentRoleId || m.roleId == null)
            .toList()
            .reversed
            .take(6)
            .toList()
            .reversed
            .toList();
        if (recentMsgs.isNotEmpty) {
          final convLines = recentMsgs
              .map((m) => '- ${m.text.length > 60 ? '${m.text.substring(0, 60)}…' : m.text}')
              .join('\n');
          conversationContext = '当前对话上下文：\n$convLines\n\n';
        }
      }

      // 角色档案信息
      String profilesContext = '';
      if (_useProfiles) {
        final allProfiles = await LocalDatabase.getAllProfiles();
        if (allProfiles.isNotEmpty) {
          final activeRole = _getRole(_currentRoleId);
          // 按优先级排序：当前角色在前
          allProfiles.sort((a, b) {
            if (a.roleId == _currentRoleId) return -1;
            if (b.roleId == _currentRoleId) return 1;
            return 0;
          });
          final buf = StringBuffer('## 系统成员档案\n\n');
          for (final p in allProfiles.take(5)) {
            buf.writeln('### ${p.roleName}${p.roleId == _currentRoleId ? '（当前活动角色）' : ''}');
            buf.writeln();
            final text = p.profileText.length > 300
                ? '${p.profileText.substring(0, 300)}…'
                : p.profileText;
            buf.writeln(text);
            buf.writeln();
          }
          profilesContext = buf.toString();
        }
      }

      // 前台 App 信息
      String foregroundApp = '';
      try {
        foregroundApp = await DeviceInfo.getForegroundApp();
      } catch (_) {}

      // 构建提示词
      final activeRole = _getRole(_currentRoleId);
      final activeRoleName = activeRole?.name ?? '宿主';
      String systemPrompt;
      if (_useTopicPrompt) {
        final defaultPrompt = await TopicPromptConfig.load();
        if (requirement.isNotEmpty) {
          // 有明确要求：使用带优先级的提示词
          systemPrompt = TopicPromptConfig.defaultChatTopicPrompt
              .replaceAll('{requirement}', requirement)
              .replaceAll('{activeRoleName}', activeRoleName);
        } else {
          systemPrompt = defaultPrompt;
        }
      } else {
        systemPrompt = '你是一个话题发动机。请根据素材生成一个值得讨论的话题问题。';
      }

      final foregroundContext = foregroundApp.isNotEmpty
          ? '当前前台 App: $foregroundApp\n\n'
          : '';
      final extraCtx = requirement.isNotEmpty
          ? '用户额外要求: $requirement\n\n'
          : '';

      final userPrompt = '今天宿主浏览了以下内容（已按关注度排序）：\n\n'
          '$materialList\n\n'
          '${historyContext}${conversationContext}${profilesContext}${foregroundContext}${extraCtx}'
          '请融合这些素材，生成一个值得讨论的话题问题。';

      // 调用 AI
      final provider = createAiProvider(config);
      final result = await provider.chatCompletion(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        temperature: 0.85,
        maxTokens: 200,
      );
      final err = provider.lastError;
      provider.dispose();

      if (result != null && result.trim().isNotEmpty) {
        final question = result.trim()
            .replaceAll(RegExp(r'^["""「]|["""」]$'), '');
        // 保存为 AI 回复
        await LocalDatabase.insertMessage(ConversationMessage(
          sessionId: _sessionId,
          text: '💡 $question',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      } else if (err != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('❌ $err'), duration: Duration(seconds: 3)),
          );
        }
        await LocalDatabase.insertMessage(ConversationMessage(
          sessionId: _sessionId,
          text: '❌ 话题生成失败: $err',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('素材不足或 AI 返回空'), duration: Duration(seconds: 2)),
          );
        }
        await LocalDatabase.insertMessage(ConversationMessage(
          sessionId: _sessionId,
          text: '❌ 话题生成失败（素材不足或 AI 返回空）',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ));
      }

      // 退出话题模式
      setState(() {
        _topicGenerating = false;
        _inputMode = _InputMode.chat;
      });
      await _loadMessages();      } catch (e) {
      setState(() => _topicGenerating = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ 错误: $e'), duration: Duration(seconds: 3)),
        );
      }
      await LocalDatabase.insertMessage(ConversationMessage(
        sessionId: _sessionId,
        text: '❌ 话题生成错误: $e',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
      await _loadMessages();
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    await LocalDatabase.deleteMessages(_selectedIds.toList());
    setState(() { _selectedIds.clear(); _selectMode = false; });
    await _loadMessages();
  }

  Future<void> _deleteConversation() async {
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('删除整个对话？'),
      content: const Text('此操作不可恢复。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          child: const Text('删除'),
        ),
      ],
    ));
    if (confirm == true) {
      await LocalDatabase.deleteConversation(_sessionId);
      if (mounted) {
        setState(() {
          _sessionId = '';
          _topic = '自由对话';
          _messages = [];
        });
        _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
        await LocalDatabase.insertConversation(Conversation(
          sessionId: _sessionId, topic: '自由对话',
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
        await _loadMessages();
      }
    }
  }

  void _onMessageLongPress(ConversationMessage msg) {
    if (msg.id == null) return;
    setState(() {
      if (!_selectMode) { _selectMode = true; _selectedIds.add(msg.id!); }
      else {
        if (_selectedIds.contains(msg.id!)) {
          _selectedIds.remove(msg.id!);
          if (_selectedIds.isEmpty) _selectMode = false;
        } else _selectedIds.add(msg.id!);
      }
    });
  }

  void _onMessageTap(ConversationMessage msg) {
    if (!_selectMode) return;
    _onMessageLongPress(msg);
  }

  ChatRole? _getRole(int? roleId) =>
      roleId == null ? null : _roles.where((r) => r.id == roleId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final currentRole = _getRole(_currentRoleId);

    return Scaffold(
      appBar: _selectMode ? _buildSelectAppBar(cs) : _buildNormalAppBar(cs),
      body: Column(
        children: [
          if (_roles.isNotEmpty && currentRole != null) _buildRoleSelector(cs, currentRole),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyChat(cs)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (ctx, i) => _MessageBubble(
                      message: _messages[i],
                      role: _getRole(_messages[i].roleId),
                      isMe: _messages[i].roleId != null && _messages[i].roleId == _currentRoleId,
                      cs: cs,
                      selectMode: _selectMode,
                      selected: _messages[i].id != null && _selectedIds.contains(_messages[i].id!),
                      showTime: i == 0 || _messages[i].timestamp - _messages[i - 1].timestamp > 300000,
                      onLongPress: () => _onMessageLongPress(_messages[i]),
                      onTap: () => _onMessageTap(_messages[i]),
                    ),
                  ),
          ),
          if (_inputMode == _InputMode.topic) _buildTopicModeOptions(cs),
          _buildInputBar(cs),
          if (_topicGenerating) _buildGeneratingIndicator(cs),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar(ColorScheme cs) => AppBar(
    title: Text(_topic, maxLines: 1, overflow: TextOverflow.ellipsis),
    centerTitle: true,
    actions: [
      IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: _deleteConversation, tooltip: '删除对话',
      ),
      IconButton(
        icon: const Icon(Icons.person_add_alt_1),
        onPressed: _showRoleEditor, tooltip: '管理角色',
      ),
    ],
  );

  PreferredSizeWidget _buildSelectAppBar(ColorScheme cs) => AppBar(
    leading: IconButton(
      icon: const Icon(Icons.close),
      onPressed: () => setState(() { _selectMode = false; _selectedIds.clear(); }),
    ),
    title: Text('已选 ${_selectedIds.length} 条'),
    centerTitle: true,
    actions: _selectedIds.isNotEmpty
        ? [IconButton(icon: Icon(Icons.delete_outline, color: cs.error), onPressed: _deleteSelected)]
        : [],
  );

  Widget _buildRoleSelector(ColorScheme cs, ChatRole currentRole) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: _roles.map((role) {
          final isActive = role.id == _currentRoleId;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => setState(() => _currentRoleId = role.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isActive ? cs.primary : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: isActive ? cs.primary : cs.outlineVariant, width: isActive ? 1.5 : 0.5),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  _buildRoleAvatar(role, 20),
                  const SizedBox(width: 4),
                  Text(role.name, style: TextStyle(
                    fontSize: 13, fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                    color: isActive ? cs.onPrimary : cs.onSurface,
                  )),
                  if (isActive) Icon(Icons.check, size: 14, color: cs.onPrimary),
                ]),
              ),
            ),
          );
        }).toList()),
      ),
    );
  }

  Widget _buildRoleAvatar(ChatRole role, double size) {
    if (role.avatarPath != null && role.avatarPath!.isNotEmpty) {
      return ClipOval(
        child: Image.file(
          File(role.avatarPath!),
          width: size, height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Text(role.avatar, style: TextStyle(fontSize: size * 0.8)),
        ),
      );
    }
    return Text(role.avatar, style: TextStyle(fontSize: size * 0.8));
  }

  void _showRoleEditor() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _RoleEditorSheet(
        roles: _roles,
        onRolesChanged: () { _loadRoles(); },
      ),
    );
  }

  Widget _buildEmptyChat(ColorScheme cs) => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 80, height: 80,
        decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.3), shape: BoxShape.circle),
        child: Icon(Icons.edit_note, size: 40, color: cs.onPrimaryContainer),
      ),
      const SizedBox(height: 20),
      Text('开始记录对话', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
      const SizedBox(height: 8),
      Text('选择一个角色，发送消息', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
    ]),
  );

  /// ── 话题模式选项 ──────────────────────────────────────
  Widget _buildTopicModeOptions(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.1),
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: Row(
        children: [
          _buildToggleChip(
            label: '历史话题',
            value: _useHistoryTopics,
            cs: cs,
            onChanged: (v) => setState(() => _useHistoryTopics = v),
          ),
          const SizedBox(width: 6),
          _buildToggleChip(
            label: '提示词',
            value: _useTopicPrompt,
            cs: cs,
            onChanged: (v) => setState(() => _useTopicPrompt = v),
          ),
          const SizedBox(width: 6),
          _buildToggleChip(
            label: '上下文',
            value: _useConversationContext,
            cs: cs,
            onChanged: (v) => setState(() => _useConversationContext = v),
          ),
          const SizedBox(width: 6),
          _buildToggleChip(
            label: '档案',
            value: _useProfiles,
            cs: cs,
            onChanged: (v) => setState(() => _useProfiles = v),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleChip({
    required String label,
    required bool value,
    required ColorScheme cs,
    required ValueChanged<bool> onChanged,
  }) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: value ? cs.primary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: value ? cs.primary : cs.outlineVariant,
            width: value ? 1.5 : 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.check_circle : Icons.circle_outlined,
              size: 14,
              color: value ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: value ? FontWeight.w600 : FontWeight.normal,
                color: value ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ── 生成中指示器 ──────────────────────────────────────
  Widget _buildGeneratingIndicator(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.15),
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
          const SizedBox(width: 10),
          Text(
            '正在生成话题…',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// ── 输入栏 ────────────────────────────────────────────
  Widget _buildInputBar(ColorScheme cs) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // /topic 自动补全浮层
          if (_showAutocomplete)
            Container(
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
              ),
              child: Material(
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.auto_awesome, size: 18, color: cs.primary),
                  title: Text(
                    '/topic  引入话题',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: cs.primary),
                  ),
                  subtitle: Text(
                    '基于浏览素材生成讨论话题',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('Enter', style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer, fontWeight: FontWeight.w600)),
                  ),
                  onTap: () => _selectAutocomplete('/topic '),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 模式选择按钮
                _buildModeButton(cs),
                const SizedBox(width: 6),
                // 输入框
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    focusNode: _inputFocusNode,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: _inputMode == _InputMode.topic
                          ? '/topic <要求> 可为空'
                          : '输入内容…',
                      hintStyle: TextStyle(
                        color: _inputMode == _InputMode.topic
                            ? cs.primary.withValues(alpha: 0.5)
                            : null,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor: _inputMode == _InputMode.topic
                          ? cs.primaryContainer.withValues(alpha: 0.15)
                          : cs.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                // 发送按钮
                _buildSendButton(cs),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 模式选择按钮
  Widget _buildModeButton(ColorScheme cs) {
    final isTopic = _inputMode == _InputMode.topic;
    return PopupMenuButton<_InputMode>(
      onSelected: (mode) {
        setState(() {
          _inputMode = mode;
          if (mode == _InputMode.topic) {
            _useHistoryTopics = true;
            _useTopicPrompt = true;
            _useConversationContext = true;
            _useProfiles = true;
            _inputController.text = '/topic ';
            _inputController.selection = TextSelection.collapsed(offset: _inputController.text.length);
          }
        });
      },
      offset: const Offset(0, -120),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: _InputMode.chat,
          child: Row(
            children: [
              Icon(
                Icons.chat_bubble_outline,
                size: 18,
                color: _inputMode == _InputMode.chat ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Text(
                '普通对话',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: _inputMode == _InputMode.chat ? FontWeight.w600 : FontWeight.normal,
                  color: _inputMode == _InputMode.chat ? cs.primary : cs.onSurface,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem(
          value: _InputMode.topic,
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 18,
                color: isTopic ? cs.primary : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Text(
                '引入话题',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: isTopic ? FontWeight.w600 : FontWeight.normal,
                  color: isTopic ? cs.primary : cs.onSurface,
                ),
              ),
            ],
          ),
        ),
      ],
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: isTopic
              ? cs.primary.withValues(alpha: 0.15)
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isTopic ? cs.primary : cs.outlineVariant,
            width: isTopic ? 1.5 : 0.5,
          ),
        ),
        child: Icon(
          isTopic ? Icons.auto_awesome : Icons.chat_bubble_outline,
          size: 18,
          color: isTopic ? cs.primary : cs.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 发送按钮（话题模式有独特样式）
  Widget _buildSendButton(ColorScheme cs) {
    final isTopic = _inputMode == _InputMode.topic;
    return Material(
      color: isTopic
          ? cs.primary.withValues(alpha: 0.85)
          : cs.primary,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _topicGenerating ? null : _sendMessage,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: isTopic
                ? [
                    BoxShadow(
                      color: cs.primary.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: _topicGenerating
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: cs.onPrimary,
                  ),
                )
              : Icon(
                  isTopic ? Icons.psychology : Icons.send_rounded,
                  color: cs.onPrimary,
                  size: 22,
                ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  角色编辑底部面板（带图片选择）
// ═══════════════════════════════════════════════════════════

class _RoleEditorSheet extends StatefulWidget {
  final List<ChatRole> roles;
  final VoidCallback onRolesChanged;
  const _RoleEditorSheet({required this.roles, required this.onRolesChanged});

  @override
  State<_RoleEditorSheet> createState() => _RoleEditorSheetState();
}

class _RoleEditorSheetState extends State<_RoleEditorSheet> {
  late List<ChatRole> _roles;
  final _picker = ImagePicker();

  @override
  void initState() { super.initState(); _roles = List.from(widget.roles); }

  /// 把选中的图片复制到 App 私有目录，返回持久路径
  Future<String?> _pickAndSaveImage() async {
    try {
      final xfile = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 256, maxHeight: 256);
      if (xfile == null) return null;
      final dir = await getApplicationDocumentsDirectory();
      final ext = p.extension(xfile.path);
      final dest = p.join(dir.path, 'avatars', 'role_${DateTime.now().millisecondsSinceEpoch}$ext');
      await File(dest).parent.create(recursive: true);
      await File(xfile.path).copy(dest);
      return dest;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选择图片失败'), duration: Duration(seconds: 1)),
        );
      }
      return null;
    }
  }

  Future<void> _addRole() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('新建角色'),
      content: TextField(controller: controller, autofocus: true,
        decoration: const InputDecoration(hintText: '角色名称', border: OutlineInputBorder())),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('创建')),
      ],
    ));
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      final avatarPath = await _pickAndSaveImage();
      await LocalDatabase.insertRole(ChatRole(name: name, avatarPath: avatarPath));
      widget.onRolesChanged();
      if (mounted) { setState(() => _roles = List.from(widget.roles)); }
    }
  }

  void _editRole(ChatRole role) async {
    final nc = TextEditingController(text: role.name);
    String? pendingAvatarPath;

    final result = await showDialog<Map<String, String>>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx2, setDialogState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('编辑角色'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: () async {
              final path = await _pickAndSaveImage();
              if (path != null) {
                pendingAvatarPath = path;
                setDialogState(() {});
              }
            },
            child: Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
              ),
              child: ClipOval(
                child: pendingAvatarPath != null
                    ? Image.file(File(pendingAvatarPath!), width: 80, height: 80, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Icon(Icons.person, size: 40))
                    : (role.avatarPath != null && role.avatarPath!.isNotEmpty
                        ? Image.file(File(role.avatarPath!), width: 80, height: 80, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(Icons.person, size: 40))
                        : Icon(Icons.person, size: 40,
                            color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('点击更换头像', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          TextField(controller: nc, decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, {'name': nc.text.trim(), 'avatarPath': pendingAvatarPath ?? ''}), child: const Text('保存')),
        ],
      ),
    ));
    nc.dispose();
    if (result != null) {
      final newName = result['name']?.isNotEmpty == true ? result['name'] : null;
      final newAvatarPath = result['avatarPath']?.isNotEmpty == true ? result['avatarPath'] : null;
      await LocalDatabase.updateRole(role.copyWith(
        name: newName ?? role.name,
        avatarPath: newAvatarPath ?? role.avatarPath,
      ));
      widget.onRolesChanged();
      if (mounted) setState(() => _roles = List.from(widget.roles));
    } else {
      if (pendingAvatarPath != null) {
        try { await File(pendingAvatarPath!).delete(); } catch (_) {}
      }
    }
  }

  void _deleteRole(ChatRole role) async {
    if (role.isDefault) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('默认角色不能删除'), duration: Duration(seconds: 1)),
      ); return;
    }
    final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('删除角色？'),
      content: Text('删除「${role.name}」后，其消息将变为无角色。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          child: const Text('删除'),
        ),
      ],
    ));
    if (confirm == true && role.id != null) {
      await LocalDatabase.deleteRole(role.id!);
      widget.onRolesChanged();
      if (mounted) setState(() => _roles = List.from(widget.roles));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('管理角色', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const Spacer(),
          TextButton.icon(onPressed: _addRole, icon: const Icon(Icons.add, size: 18), label: const Text('添加')),
        ]),
        const SizedBox(height: 12),
        ..._roles.map((role) => ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: SizedBox(
            width: 44, height: 44,
            child: ClipOval(
              child: role.avatarPath != null && role.avatarPath!.isNotEmpty
                  ? Image.file(File(role.avatarPath!), width: 44, height: 44, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(Icons.person, color: cs.onSurfaceVariant))
                  : Container(
                      color: cs.surfaceContainerHighest,
                      child: Center(child: Text(role.avatar, style: const TextStyle(fontSize: 22))),
                    ),
            ),
          ),
          title: Text(role.name, style: const TextStyle(fontSize: 15)),
          subtitle: role.isDefault
              ? Text('默认角色', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              : null,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _editRole(role)),
            if (!role.isDefault)
              IconButton(icon: Icon(Icons.delete_outline, size: 20, color: cs.error), onPressed: () => _deleteRole(role)),
          ]),
        )),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  QQ 风格消息气泡
// ═══════════════════════════════════════════════════════════

class _MessageBubble extends StatelessWidget {
  final ConversationMessage message;
  final ChatRole? role;
  final bool isMe;
  final ColorScheme cs;
  final bool selectMode;
  final bool selected;
  final bool showTime;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  const _MessageBubble({
    required this.message, required this.role, required this.isMe,
    required this.cs, required this.selectMode, required this.selected,
    required this.showTime, required this.onLongPress, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(message.timestamp);
    final timeStr = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    final fullDate = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $timeStr';
    final maxW = MediaQuery.of(context).size.width * 0.65;
    final avatarSize = 40.0;

    return Column(
      children: [
        if (showTime)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                child: Text(fullDate, style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(top: 4),
          child: isMe ? _buildMeRow(avatarSize, maxW, timeStr) : _buildOtherRow(avatarSize, maxW, timeStr),
        ),
      ],
    );
  }

  Widget _buildMeRow(double avatarSize, double maxW, String timeStr) {
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(left: 50),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (role != null)
              Padding(
                padding: EdgeInsets.only(right: avatarSize + 8, bottom: 2),
                child: Text(role!.name,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                    color: cs.onSurfaceVariant)),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Flexible(
                  child: Container(
                    constraints: BoxConstraints(maxWidth: maxW),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? cs.primary.withValues(alpha: 0.3) : cs.primaryContainer,
                      borderRadius: BorderRadius.circular(16).copyWith(
                        bottomRight: const Radius.circular(6),
                      ),
                      border: selected ? Border.all(color: cs.primary, width: 1.5) : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(message.text,
                          style: TextStyle(fontSize: 15, color: cs.onPrimaryContainer, height: 1.4)),
                        const SizedBox(height: 3),
                        Text(timeStr,
                          style: TextStyle(fontSize: 11,
                            color: cs.onPrimaryContainer.withValues(alpha: 0.6))),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _buildAvatar(avatarSize),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOtherRow(double avatarSize, double maxW, String timeStr) {
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(right: 50),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Column(
              children: [
                SizedBox(height: 4),
                _buildAvatar(avatarSize),
              ],
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (role != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 2),
                      child: Text(role!.name,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                          color: cs.onSurfaceVariant)),
                    ),
                  Container(
                    constraints: BoxConstraints(maxWidth: maxW),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? cs.secondary.withValues(alpha: 0.3) : cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16).copyWith(
                        bottomLeft: const Radius.circular(6),
                      ),
                      border: selected ? Border.all(color: cs.secondary, width: 1.5) : null,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(message.text,
                          style: TextStyle(fontSize: 15, color: cs.onSurface, height: 1.4)),
                        const SizedBox(height: 3),
                        Text(timeStr,
                          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(double size) {
    if (role == null) {
      return SizedBox(width: size, height: size);
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: role!.avatarPath != null && role!.avatarPath!.isNotEmpty
            ? Image.file(File(role!.avatarPath!), width: size, height: size, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildFallbackAvatar(size))
            : _buildFallbackAvatar(size),
      ),
    );
  }

  Widget _buildFallbackAvatar(double size) {
    return Container(
      color: isMe ? cs.primary : cs.surfaceContainerHighest,
      child: Center(
        child: role != null
            ? Text(role!.avatar, style: TextStyle(fontSize: size * 0.55))
            : Icon(Icons.person, size: size * 0.5, color: cs.onSurfaceVariant),
      ),
    );
  }
}
