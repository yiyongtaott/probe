import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import '../shared/models/models.dart';
import '../shared/storage/database.dart';
import 'chat_page.dart';
import 'profiles_page.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({super.key});

  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('记录'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.forum_outlined, size: 18),
                  const SizedBox(width: 6),
                  const Text('对话记录'),
                ],
              ),
            ),
            Tab(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.person_outline, size: 18),
                  const SizedBox(width: 6),
                  const Text('成员档案'),
                ],
              ),
            ),
          ],
          indicatorColor: cs.primary,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          const _ConversationsTab(),
          const ProfilesPage(),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════
//  对话记录 Tab
// ═══════════════════════════════════════════════════════════

class _ConversationsTab extends StatefulWidget {
  const _ConversationsTab();

  @override
  State<_ConversationsTab> createState() => _ConversationsTabState();
}

class _ConversationsTabState extends State<_ConversationsTab> {
  List<Conversation> _conversations = [];
  final Map<String, int> _messageCounts = {};
  bool _selectMode = false;
  final Set<String> _selectedSessionIds = {};

  @override
  void initState() { super.initState(); _loadData(); }

  Future<void> _loadData() async {
    final convs = await LocalDatabase.getAllConversations();
    final counts = <String, int>{};
    for (final c in convs) {
      final msgs = await LocalDatabase.getMessages(c.sessionId);
      counts[c.sessionId] = msgs.length;
    }
    if (mounted) setState(() { _conversations = convs; _messageCounts.clear(); _messageCounts.addAll(counts); });
  }

  Future<void> _deleteSelected() async {
    if (_selectedSessionIds.isEmpty) return;
    for (final sid in _selectedSessionIds) await LocalDatabase.deleteConversation(sid);
    setState(() { _selectMode = false; _selectedSessionIds.clear(); });
    await _loadData();
  }

  void _onLongPress(Conversation conv) {
    setState(() {
      if (!_selectMode) { _selectMode = true; _selectedSessionIds.add(conv.sessionId); }
      else {
        if (_selectedSessionIds.contains(conv.sessionId)) {
          _selectedSessionIds.remove(conv.sessionId);
          if (_selectedSessionIds.isEmpty) _selectMode = false;
        } else _selectedSessionIds.add(conv.sessionId);
      }
    });
  }

  void _onTap(Conversation conv) {
    if (_selectMode) { _onLongPress(conv); return; }
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(existingSessionId: conv.sessionId)))
        .then((_) => _loadData());
  }

  String _formatDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: _selectMode
          ? AppBar(
              leading: IconButton(icon: const Icon(Icons.close),
                onPressed: () => setState(() { _selectMode = false; _selectedSessionIds.clear(); })),
              title: Text('已选 ${_selectedSessionIds.length} 条'),
              centerTitle: true,
              actions: _selectedSessionIds.isNotEmpty
                  ? [IconButton(icon: Icon(Icons.delete_outline, color: cs.error), onPressed: _deleteSelected)]
                  : [],
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: _conversations.isEmpty ? _buildEmpty(cs) : ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          itemCount: _conversations.length,
          itemBuilder: (ctx, i) => _ConversationCard(
            conversation: _conversations[i],
            messageCount: _messageCounts[_conversations[i].sessionId] ?? 0,
            dateStr: _formatDate(_conversations[i].createdAt),
            cs: cs, selected: _selectMode && _selectedSessionIds.contains(_conversations[i].sessionId),
            onTap: () => _onTap(_conversations[i]),
            onLongPress: () => _onLongPress(_conversations[i]),
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(ColorScheme cs) => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 80, height: 80,
        decoration: BoxDecoration(color: cs.primaryContainer.withValues(alpha: 0.3), shape: BoxShape.circle),
        child: Icon(Icons.history, size: 40, color: cs.onPrimaryContainer)),
      const SizedBox(height: 20),
      Text('还没有对话记录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
      const SizedBox(height: 8),
      Text('生成话题后开始对话即可保存记录', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
    ]),
  );
}

class _ConversationCard extends StatelessWidget {
  final Conversation conversation;
  final int messageCount;
  final String dateStr;
  final ColorScheme cs;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ConversationCard({
    required this.conversation, required this.messageCount, required this.dateStr,
    required this.cs, required this.selected, required this.onTap, required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? cs.primary : cs.outlineVariant, width: selected ? 1.5 : 0.5)),
      color: selected ? cs.primaryContainer.withValues(alpha: 0.15) : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap, onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Container(width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [cs.primaryContainer, cs.secondaryContainer],
                  begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(14)),
              child: Icon(Icons.forum_outlined, color: cs.onPrimaryContainer, size: 22)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(conversation.topic, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.access_time, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: 4), Text(dateStr, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const SizedBox(width: 16),
                Icon(Icons.chat_bubble_outline, size: 13, color: cs.onSurfaceVariant),
                const SizedBox(width: 4), Text('$messageCount 条', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ]),
            ])),
            Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}
