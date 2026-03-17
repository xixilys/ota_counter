import 'package:flutter/material.dart';

import '../models/idol_database_models.dart';
import '../services/idol_database_service.dart';
import '../widgets/no_autofill_text_field.dart';

class IdolDatabasePage extends StatefulWidget {
  const IdolDatabasePage({super.key});

  @override
  State<IdolDatabasePage> createState() => _IdolDatabasePageState();
}

class _IdolDatabasePageState extends State<IdolDatabasePage> {
  final TextEditingController _searchController = TextEditingController();

  List<IdolGroup> _groups = [];
  List<IdolPerson> _people = [];
  List<IdolMember> _allMembers = [];
  Map<String, String> _meta = {};
  int? _selectedGroupId;
  bool _showMembers = true;
  bool _loading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
    });

    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final people = await IdolDatabaseService.getPeople();
    final groups = await IdolDatabaseService.getGroups();
    final members = await IdolDatabaseService.getMembers();
    final meta = await IdolDatabaseService.getMeta();

    if (!mounted) {
      return;
    }

    setState(() {
      _people = people;
      _groups = groups;
      _allMembers = members;
      _meta = meta;
      _loading = false;
    });
  }

  List<IdolMember> get _filteredMembers {
    return _allMembers.where((member) {
      final matchesGroup =
          _selectedGroupId == null || member.groupId == _selectedGroupId;
      if (!matchesGroup) {
        return false;
      }

      return member.matchesQuery(_searchQuery);
    }).toList();
  }

  Future<void> _restoreBuiltInData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复内置偶像库'),
        content: const Text('这会清空你当前编辑过的团体和成员，恢复为内置 Wiki 快照。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await IdolDatabaseService.restoreBuiltInData();
    await _loadData();
  }

  Future<void> _showGroupDialog({IdolGroup? initialGroup}) async {
    final controller = TextEditingController(text: initialGroup?.name ?? '');

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(initialGroup == null ? '添加团体' : '编辑团体'),
        content: NoAutofillTextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '团体名称',
            hintText: '请输入团体名称',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                return;
              }

              await IdolDatabaseService.upsertGroup(
                IdolGroup(
                  id: initialGroup?.id,
                  name: name,
                  source: initialGroup?.source ?? 'manual',
                  isBuiltIn: false,
                ),
              );

              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    controller.dispose();
    await _loadData();
  }

  Future<void> _showMemberDialog({IdolMember? initialMember}) async {
    final nameController =
        TextEditingController(text: initialMember?.name ?? '');
    final personController = TextEditingController(
      text: initialMember?.resolvedPersonName ?? '',
    );
    final statusController = TextEditingController(
      text: initialMember?.status ?? '',
    );
    var selectedGroupId = initialMember?.groupId ??
        (_groups.isNotEmpty ? _groups.first.id : null);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(initialMember == null ? '添加成员' : '编辑成员'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int?>(
                  initialValue: selectedGroupId,
                  decoration: const InputDecoration(labelText: '所属团体'),
                  items: _groups
                      .where((group) => group.id != null)
                      .map(
                        (group) => DropdownMenuItem(
                          value: group.id!,
                          child: Text(group.name),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    setDialogState(() {
                      selectedGroupId = value;
                    });
                  },
                ),
                const SizedBox(height: 12),
                NoAutofillTextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '成员名称',
                    hintText: '请输入成员名称',
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                NoAutofillTextField(
                  controller: personController,
                  decoration: const InputDecoration(
                    labelText: '真人主档名',
                    hintText: '同一真人跨团/时期请保持一致',
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                NoAutofillTextField(
                  controller: statusController,
                  decoration: const InputDecoration(
                    labelText: '状态',
                    hintText: '例如：正式成员 / 研修生 / 前成员',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '提示：状态或名称里写“蓝色担当 / 紫色担当”等字样，会自动识别成员担当色。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty || selectedGroupId == null) {
                  return;
                }

                final group = _groups.firstWhere(
                  (item) => item.id == selectedGroupId,
                );

                await IdolDatabaseService.upsertMember(
                  IdolMember(
                    id: initialMember?.id,
                    groupId: selectedGroupId!,
                    groupName: group.name,
                    personId: initialMember?.personId,
                    personName: personController.text.trim(),
                    name: name,
                    status: statusController.text.trim(),
                    source: initialMember?.source ?? 'manual',
                    isBuiltIn: false,
                  ),
                );

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    personController.dispose();
    statusController.dispose();
    await _loadData();
  }

  Future<void> _deleteGroup(IdolGroup group) async {
    if (group.id == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除团体'),
        content: Text('删除“${group.name}”后，旗下成员也会一起被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await IdolDatabaseService.deleteGroup(group.id!);
    if (_selectedGroupId == group.id) {
      _selectedGroupId = null;
    }
    await _loadData();
  }

  Future<void> _deleteMember(IdolMember member) async {
    if (member.id == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除成员'),
        content: Text('确定删除“${member.groupName} / ${member.name}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    await IdolDatabaseService.deleteMember(member.id!);
    await _loadData();
  }

  Color? _colorFromHex(String? hex) {
    if (hex == null || !hex.startsWith('#') || hex.length != 7) {
      return null;
    }

    try {
      return Color(int.parse('FF${hex.substring(1)}', radix: 16));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sourceLabel = _meta['source_label'];
    final generatedAt = _meta['generated_at'];
    final totalMembers =
        _groups.fold<int>(0, (sum, group) => sum + group.memberCount);

    return Scaffold(
      appBar: AppBar(
        title: const Text('偶像数据库'),
        actions: [
          IconButton(
            tooltip: '恢复内置 Wiki 快照',
            onPressed: _restoreBuiltInData,
            icon: const Icon(Icons.restart_alt),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (_showMembers) {
            _showMemberDialog();
          } else {
            _showGroupDialog();
          }
        },
        icon: Icon(_showMembers ? Icons.person_add : Icons.group_add),
        label: Text(_showMembers ? '添加成员' : '添加团体'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '共 ${_groups.length} 个团体 / $totalMembers 条团籍 / ${_people.length} 位真人',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          sourceLabel == null
                              ? '当前使用本地可编辑偶像库'
                              : '当前内置源：$sourceLabel',
                        ),
                        if ((generatedAt ?? '').isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text('快照时间：$generatedAt'),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('成员'),
                        icon: Icon(Icons.person),
                      ),
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('团体'),
                        icon: Icon(Icons.groups),
                      ),
                    ],
                    selected: {_showMembers},
                    onSelectionChanged: (value) {
                      setState(() {
                        _showMembers = value.first;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 12),
                if (_showMembers)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        NoAutofillTextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: _searchQuery.isEmpty
                                ? null
                                : IconButton(
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() {
                                        _searchQuery = '';
                                      });
                                    },
                                    icon: const Icon(Icons.clear),
                                  ),
                            labelText: '搜索成员 / 团体 / 拼音',
                          ),
                          onChanged: (value) {
                            setState(() {
                              _searchQuery = value;
                            });
                          },
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<int?>(
                          initialValue: _selectedGroupId,
                          decoration: const InputDecoration(
                            labelText: '按团体筛选',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('全部团体'),
                            ),
                            ..._groups.where((group) => group.id != null).map(
                                  (group) => DropdownMenuItem<int?>(
                                    value: group.id!,
                                    child: Text(group.name),
                                  ),
                                ),
                          ],
                          onChanged: (value) {
                            setState(() {
                              _selectedGroupId = value;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: _showMembers
                      ? ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                          itemCount: _filteredMembers.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final member = _filteredMembers[index];
                            final memberColor = _colorFromHex(
                              member.themeColorHex,
                            );
                            final themeColorLabel = member.themeColorLabel;
                            final subtitleParts = <String>[
                              member.groupName,
                              if (member.resolvedPersonName.isNotEmpty &&
                                  member.resolvedPersonName !=
                                      member.displayName)
                                '真人 ${member.resolvedPersonName}',
                              if (member.status.isNotEmpty) member.status,
                              if (themeColorLabel != null &&
                                  !member.status.contains(themeColorLabel))
                                themeColorLabel,
                            ];
                            return Card(
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: memberColor ??
                                      Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                  foregroundColor: memberColor == null ||
                                          memberColor.computeLuminance() > 0.55
                                      ? Colors.black87
                                      : Colors.white,
                                  child: Text(
                                    member.displayName.isEmpty
                                        ? '?'
                                        : member.displayName.substring(0, 1),
                                  ),
                                ),
                                title: Text(member.displayName),
                                subtitle: Text(
                                  subtitleParts.join(' · '),
                                ),
                                trailing: Wrap(
                                  spacing: 4,
                                  children: [
                                    IconButton(
                                      onPressed: () => _showMemberDialog(
                                        initialMember: member,
                                      ),
                                      icon: const Icon(Icons.edit),
                                    ),
                                    IconButton(
                                      onPressed: () => _deleteMember(member),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                          itemCount: _groups.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final group = _groups[index];
                            return Card(
                              child: ListTile(
                                title: Text(group.name),
                                subtitle: Text(
                                  '${group.memberCount} 名成员'
                                  '${group.isBuiltIn ? ' · 内置' : ''}',
                                ),
                                trailing: Wrap(
                                  spacing: 4,
                                  children: [
                                    IconButton(
                                      onPressed: () => _showGroupDialog(
                                        initialGroup: group,
                                      ),
                                      icon: const Icon(Icons.edit),
                                    ),
                                    IconButton(
                                      onPressed: () => _deleteGroup(group),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}
