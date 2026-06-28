import 'dart:io';

import 'package:flutter/material.dart';

import '../shared/models/models.dart';
import '../shared/storage/database.dart';
import '../shared/engine/profile_engine.dart';
import '../shared/services/background_service.dart';

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key});

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  List<RoleProfile> _profiles = [];
  List<ChatRole> _roles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final roles = await LocalDatabase.getAllRoles();
    final profiles = await LocalDatabase.getAllProfiles();
    if (mounted) {
      setState(() {
        _roles = roles;
        _profiles = profiles;
        _loading = false;
      });
    }
  }

  RoleProfile? _getProfileForRole(int roleId) {
    return _profiles.where((p) => p.roleId == roleId).firstOrNull;
  }

  Future<void> _compileAllProfiles() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在归纳档案…'), duration: Duration(seconds: 1)),
      );
    }
    await ProfileEngine.compileAllProfiles();
    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ 档案已更新'), duration: Duration(seconds: 1)),
      );
    }
  }

  void _editProfile(RoleProfile profile) {
    final controller = TextEditingController(text: profile.profileText);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.edit_note, size: 24, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('编辑 ${profile.roleName} 档案',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 15,
                minLines: 10,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace', height: 1.5),
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  hintText: '使用 Markdown 格式编写档案…',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () async {
                      final text = controller.text.trim();
                      if (text.isEmpty) return;
                      await LocalDatabase.upsertProfile(profile.copyWith(profileText: text));
                      Navigator.pop(ctx);
                      await _loadData();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('✅ 档案已保存'), duration: Duration(seconds: 1)),
                        );
                      }
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) => controller.dispose());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _loadData,
            child: _roles.isEmpty
                ? _buildEmpty(cs)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    itemCount: _roles.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: ActionChip(
                            avatar: const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('更新所有档案'),
                            onPressed: _compileAllProfiles,
                          ),
                        );
                      }
                      final roleIdx = i - 1;
                      return _ProfileCard(
                        role: _roles[roleIdx],
                        profile: _getProfileForRole(_roles[roleIdx].id ?? 0),
                        cs: cs,
                        onEdit: () {
                          final profile = _getProfileForRole(_roles[roleIdx].id ?? 0);
                          if (profile != null) _editProfile(profile);
                        },
                        onRefresh: _loadData,
                      );
                    },
                  ),
          );
  }

  Widget _buildEmpty(ColorScheme cs) => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.3),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.person_outline, size: 40, color: cs.onPrimaryContainer),
      ),
      const SizedBox(height: 20),
      Text('暂无成员档案', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
      const SizedBox(height: 8),
      Text('开始对话后，点击右上角更新按钮生成档案', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
    ]),
  );
}

// ═══════════════════════════════════════════════════════════
//  档案卡片
// ═══════════════════════════════════════════════════════════

class _ProfileCard extends StatelessWidget {
  final ChatRole role;
  final RoleProfile? profile;
  final ColorScheme cs;
  final VoidCallback onEdit;
  final VoidCallback onRefresh;

  const _ProfileCard({
    required this.role,
    required this.profile,
    required this.cs,
    required this.onEdit,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: cs.outlineVariant, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 角色头部
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // 头像
                SizedBox(
                  width: 44, height: 44,
                  child: ClipOval(
                    child: role.avatarPath != null && role.avatarPath!.isNotEmpty
                        ? Image.file(
                            File(role.avatarPath!),
                            width: 44, height: 44,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildAvatarFallback(role, cs),
                          )
                        : _buildAvatarFallback(role, cs),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(role.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        profile != null
                            ? '${profile!.profileText.length} 字符 · ${_formatDate(profile!.updatedAt)}'
                            : '暂无档案',
                        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                // 编辑按钮
                Material(
                  color: cs.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onEdit,
                    child: Container(
                      width: 36, height: 36,
                      alignment: Alignment.center,
                      child: Icon(Icons.edit_outlined, size: 20, color: cs.onPrimaryContainer),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 档案内容预览
          if (profile != null) ...{
            Divider(height: 1, indent: 16, endIndent: 16, color: cs.outlineVariant),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                profile!.profileText.length > 500
                    ? '${profile!.profileText.substring(0, 500)}…'
                    : profile!.profileText,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
          },
        ],
      ),
    );
  }

  Widget _buildAvatarFallback(ChatRole role, ColorScheme cs) {
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(child: Text(role.avatar, style: const TextStyle(fontSize: 22))),
    );
  }

  String _formatDate(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${dt.month}/${dt.day}';
  }
}
