import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/idol_database_models.dart';
import '../services/idol_database_service.dart';
import 'color_picker_dialog.dart';
import 'no_autofill_text_field.dart';

class CounterDialogResult {
  final CounterModel counter;
  final DateTime occurredAt;

  const CounterDialogResult({
    required this.counter,
    required this.occurredAt,
  });
}

class AddCounterDialog extends StatefulWidget {
  final CounterModel? initialData;
  final DateTime? initialOccurredAt;

  const AddCounterDialog({
    super.key,
    this.initialData,
    this.initialOccurredAt,
  });

  @override
  State<AddCounterDialog> createState() => _AddCounterDialogState();
}

class _AddCounterDialogState extends State<AddCounterDialog> {
  final _nameController = TextEditingController();
  final _groupController = TextEditingController();
  late final Map<String, TextEditingController> _countControllers;
  Color _selectedColor = const Color(0xFFFFE135);
  String? _nameError;
  final Map<String, String?> _countErrors = {};
  List<IdolGroup> _idolGroups = [];
  List<IdolMember> _idolMembers = [];
  bool _idolLoading = false;
  bool _idolMemberLoading = false;
  bool _useIdolDatabase = true;
  int? _selectedIdolGroupId;
  int? _selectedIdolMemberId;
  late DateTime _occurredAt;

  @override
  void initState() {
    super.initState();
    _occurredAt = widget.initialOccurredAt ?? DateTime.now();
    _countControllers = {
      for (final field in CounterCountField.values)
        field.key: TextEditingController(),
    };

    if (widget.initialData != null) {
      _nameController.text = widget.initialData!.name;
      _groupController.text = widget.initialData!.groupName;
      _selectedColor = widget.initialData!.colorValue;
      for (final field in CounterCountField.values) {
        _countControllers[field.key]!.text =
            widget.initialData!.countForField(field).toString();
      }
    }

    _loadIdolDatabase();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _groupController.dispose();
    for (final controller in _countControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadIdolDatabase() async {
    setState(() {
      _idolLoading = true;
    });

    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final groups = await IdolDatabaseService.getGroups();

    int? selectedGroupId;
    if (widget.initialData != null &&
        widget.initialData!.groupName.trim().isNotEmpty) {
      selectedGroupId = _findGroupIdByName(
        groups,
        widget.initialData!.groupName.trim(),
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _idolGroups = groups;
      _idolMembers = [];
      _selectedIdolGroupId = selectedGroupId;
      _selectedIdolMemberId = null;
      _useIdolDatabase = groups.isNotEmpty;
      _idolLoading = false;
    });

    if (selectedGroupId != null) {
      await _loadMembersForGroup(
        selectedGroupId,
        initialMemberName: widget.initialData?.name,
      );
    }
  }

  Future<void> _loadMembersForGroup(
    int? groupId, {
    String? initialMemberName,
  }) async {
    if (groupId == null) {
      if (!mounted) {
        return;
      }

      setState(() {
        _idolMembers = [];
        _selectedIdolMemberId = null;
        _idolMemberLoading = false;
      });
      return;
    }

    setState(() {
      _idolMemberLoading = true;
      _idolMembers = [];
      _selectedIdolMemberId = null;
    });

    final members = await IdolDatabaseService.getMembers(groupId: groupId);
    if (!mounted || _selectedIdolGroupId != groupId) {
      return;
    }

    int? selectedMemberId;
    final memberName = initialMemberName?.trim();
    if (memberName != null && memberName.isNotEmpty) {
      for (final member in members) {
        if (member.name == memberName) {
          selectedMemberId = member.id;
          break;
        }
      }
    }

    setState(() {
      _idolMembers = members;
      _selectedIdolMemberId = selectedMemberId;
      _idolMemberLoading = false;
    });
  }

  int? _findGroupIdByName(List<IdolGroup> groups, String name) {
    for (final group in groups) {
      if (group.name == name) {
        return group.id;
      }
    }
    return null;
  }

  IdolGroup? _findGroupById(int? id) {
    for (final group in _idolGroups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }

  IdolMember? _findMemberById(int? id) {
    for (final member in _idolMembers) {
      if (member.id == id) {
        return member;
      }
    }
    return null;
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

  String _buildMemberSubtitle(IdolMember member) {
    final themeColorLabel = member.themeColorLabel;
    final segments = <String>[
      member.groupName,
      if (member.status.isNotEmpty) member.status,
      if (themeColorLabel != null && !member.status.contains(themeColorLabel))
        themeColorLabel,
    ];
    return segments.join(' · ');
  }

  String _buildSelectedMemberLabel(IdolMember member) {
    final themeColorLabel = member.themeColorLabel;
    final segments = <String>[
      member.displayName,
      if (themeColorLabel != null && !member.status.contains(themeColorLabel))
        themeColorLabel,
      if (member.status.isNotEmpty) member.status,
    ];
    return segments.join(' · ');
  }

  void _applySelectedIdol(
    IdolMember member, {
    bool applyThemeColor = true,
  }) {
    final themeColor =
        applyThemeColor ? _colorFromHex(member.themeColorHex) : null;

    setState(() {
      _nameController.text = member.displayName;
      _groupController.text = member.groupName;
      if (themeColor != null) {
        _selectedColor = themeColor;
      }
    });
  }

  Future<void> _pickIdolGroup() async {
    final selectedGroup = await _showSearchPicker<IdolGroup>(
      title: '搜索团体',
      searchLabel: '输入团体名称',
      items: _idolGroups,
      titleBuilder: (group) => group.name,
      subtitleBuilder: (group) =>
          '${group.memberCount} 名成员${group.isBuiltIn ? ' · 内置' : ''}',
      matchesQuery: (group, query) {
        final normalized = query.trim().toLowerCase();
        if (normalized.isEmpty) {
          return true;
        }
        return group.name.toLowerCase().contains(normalized);
      },
    );

    if (selectedGroup == null || selectedGroup.id == null || !mounted) {
      return;
    }

    setState(() {
      _selectedIdolGroupId = selectedGroup.id;
      _selectedIdolMemberId = null;
      _groupController.text = selectedGroup.name;
      _nameController.clear();
    });

    await _loadMembersForGroup(selectedGroup.id);
  }

  Future<void> _pickIdolMember() async {
    final groupId = _selectedIdolGroupId;
    if (groupId == null) {
      return;
    }

    if (_idolMembers.isEmpty && !_idolMemberLoading) {
      await _loadMembersForGroup(groupId);
    }

    if (!mounted) {
      return;
    }

    final selectedMember = await _showSearchPicker<IdolMember>(
      title: '搜索成员',
      searchLabel: '输入成员名称 / 拼音 / 状态',
      items: _idolMembers,
      titleBuilder: (member) => member.displayName,
      subtitleBuilder: _buildMemberSubtitle,
      matchesQuery: (member, query) => member.matchesQuery(query),
    );

    if (selectedMember == null || !mounted) {
      return;
    }

    setState(() {
      _selectedIdolMemberId = selectedMember.id;
    });
    _applySelectedIdol(selectedMember, applyThemeColor: true);
  }

  Future<T?> _showSearchPicker<T>({
    required String title,
    required String searchLabel,
    required List<T> items,
    required String Function(T item) titleBuilder,
    required String Function(T item) subtitleBuilder,
    required bool Function(T item, String query) matchesQuery,
  }) async {
    return showModalBottomSheet<T>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _IdolSearchSheet<T>(
        title: title,
        searchLabel: searchLabel,
        items: items,
        titleBuilder: titleBuilder,
        subtitleBuilder: subtitleBuilder,
        matchesQuery: matchesQuery,
      ),
    );
  }

  void _showColorPicker() {
    showDialog(
      context: context,
      builder: (context) => ColorPickerDialog(
        initialColor: _selectedColor,
        onColorChanged: (color) {
          setState(() {
            _selectedColor = color;
          });
        },
      ),
    );
  }

  String _colorToHex(Color color) {
    final hex =
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return hex.toUpperCase();
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) {
      return;
    }

    setState(() {
      _occurredAt = DateTime(
        date.year,
        date.month,
        date.day,
      );
    });
  }

  String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }

  bool _validate() {
    bool isValid = true;
    setState(() {
      _nameError = null;
      _countErrors.clear();

      final name = _nameController.text.trim();
      if (name.isEmpty) {
        _nameError = '请输入名称';
        isValid = false;
      }

      for (final field in CounterCountField.values) {
        final countText = _countControllers[field.key]!.text.trim();
        if (countText.isEmpty) {
          continue;
        }

        final count = int.tryParse(countText);
        if (count == null || count < 0) {
          _countErrors[field.key] = '请输入有效的数值';
          isValid = false;
        }
      }
    });
    return isValid;
  }

  int _parseCount(CounterCountField field) {
    return int.tryParse(_countControllers[field.key]!.text.trim()) ?? 0;
  }

  Widget _buildSearchTile({
    required BuildContext context,
    required String label,
    required String value,
    required String placeholder,
    required VoidCallback? onTap,
    Color? accentColor,
  }) {
    final theme = Theme.of(context);
    final hasAccent = accentColor != null;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      tileColor: hasAccent ? accentColor.withValues(alpha: 0.08) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: hasAccent
              ? accentColor.withValues(alpha: 0.8)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      title: Text(label),
      subtitle: Text(
        value.isEmpty ? placeholder : value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Icon(
        Icons.search,
        color: hasAccent
            ? accentColor.withValues(alpha: 0.95)
            : theme.colorScheme.onSurfaceVariant,
      ),
      enabled: onTap != null,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialData != null;
    final selectedGroup = _findGroupById(_selectedIdolGroupId);
    final selectedMember = _findMemberById(_selectedIdolMemberId);
    final selectedMemberLabel =
        selectedMember == null ? '' : _buildSelectedMemberLabel(selectedMember);
    final selectedMemberColor = _colorFromHex(selectedMember?.themeColorHex);
    final colorIconColor = _selectedColor.computeLuminance() < 0.55
        ? Colors.white
        : Colors.black87;

    return AlertDialog(
      title: Text(isEditing ? '编辑计数器' : '添加新计数器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NoAutofillTextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: '成员名称',
                hintText: '请输入成员名称',
                errorText: _nameError,
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            NoAutofillTextField(
              controller: _groupController,
              decoration: const InputDecoration(
                labelText: '所属团体',
                hintText: '可选，便于区分同名成员',
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            if (_idolLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: LinearProgressIndicator(),
              )
            else if (_idolGroups.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('从内置偶像库快速选择'),
                      subtitle: const Text('先搜索团体，再搜索该团体成员'),
                      value: _useIdolDatabase,
                      onChanged: (value) {
                        setState(() {
                          _useIdolDatabase = value;
                        });
                      },
                    ),
                    if (_useIdolDatabase) ...[
                      const SizedBox(height: 8),
                      _buildSearchTile(
                        context: context,
                        label: '偶像库团体',
                        value: selectedGroup?.name ?? '',
                        placeholder: '点击搜索团体',
                        onTap: _pickIdolGroup,
                      ),
                      const SizedBox(height: 12),
                      if (_idolMemberLoading)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: LinearProgressIndicator(),
                        ),
                      _buildSearchTile(
                        context: context,
                        label: '偶像库成员',
                        value: selectedMemberLabel,
                        placeholder:
                            _selectedIdolGroupId == null ? '请先选择团体' : '点击搜索成员',
                        accentColor: selectedMemberColor,
                        onTap:
                            _selectedIdolGroupId == null || _idolMemberLoading
                                ? null
                                : _pickIdolMember,
                      ),
                      if (selectedMember?.themeColorLabel != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          '已识别 ${selectedMember!.themeColorLabel!}，会自动带入计数器颜色',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('记录日期'),
              subtitle: Text(_formatDate(_occurredAt)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: _pickDateTime,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '规格计数（留空默认 0）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 16),
            Column(
              children: [
                for (final field in CounterCountField.values) ...[
                  NoAutofillTextField(
                    controller: _countControllers[field.key]!,
                    decoration: InputDecoration(
                      labelText: field.label,
                      hintText: '0',
                      errorText: _countErrors[field.key],
                    ),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
            const SizedBox(height: 16),
            const Text('选择颜色:'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _showColorPicker,
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: _selectedColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.grey),
                ),
                child: Icon(Icons.color_lens, color: colorIconColor),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            if (!_validate()) {
              return;
            }

            final name = _nameController.text.trim();

            Navigator.of(context).pop(
              CounterDialogResult(
                occurredAt: _occurredAt,
                counter: CounterModel(
                  id: widget.initialData?.id,
                  name: name,
                  groupName: _groupController.text.trim(),
                  color: _colorToHex(_selectedColor),
                  threeInchCount: _parseCount(CounterCountField.threeInch),
                  fiveInchCount: _parseCount(CounterCountField.fiveInch),
                  groupCutCount: _parseCount(CounterCountField.groupCut),
                  threeInchShukudaiCount: _parseCount(
                    CounterCountField.threeInchShukudai,
                  ),
                  fiveInchShukudaiCount: _parseCount(
                    CounterCountField.fiveInchShukudai,
                  ),
                ),
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _IdolSearchSheet<T> extends StatefulWidget {
  final String title;
  final String searchLabel;
  final List<T> items;
  final String Function(T item) titleBuilder;
  final String Function(T item) subtitleBuilder;
  final bool Function(T item, String query) matchesQuery;

  const _IdolSearchSheet({
    required this.title,
    required this.searchLabel,
    required this.items,
    required this.titleBuilder,
    required this.subtitleBuilder,
    required this.matchesQuery,
  });

  @override
  State<_IdolSearchSheet<T>> createState() => _IdolSearchSheetState<T>();
}

class _IdolSearchSheetState<T> extends State<_IdolSearchSheet<T>> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filteredItems = widget.items
        .where((item) => widget.matchesQuery(item, _query))
        .toList();
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.75,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: widget.searchLabel,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _query = '';
                            });
                          },
                          icon: const Icon(Icons.clear),
                        ),
                ),
                onChanged: (value) {
                  setState(() {
                    _query = value;
                  });
                },
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filteredItems.isEmpty
                    ? Center(
                        child: Text(
                          '没有匹配结果',
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        itemCount: filteredItems.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = filteredItems[index];
                          final subtitle = widget.subtitleBuilder(item);

                          return ListTile(
                            title: Text(widget.titleBuilder(item)),
                            subtitle: subtitle.isEmpty ? null : Text(subtitle),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => Navigator.of(context).pop(item),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
