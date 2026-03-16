import 'package:flutter/material.dart';
import '../models/idol_database_models.dart';
import '../models/counter_model.dart';
import '../services/idol_database_service.dart';
import 'color_picker_dialog.dart';

class AddCounterDialog extends StatefulWidget {
  final CounterModel? initialData;

  const AddCounterDialog({
    super.key,
    this.initialData,
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
  bool _useIdolDatabase = true;
  int? _selectedIdolGroupId;
  int? _selectedIdolMemberId;

  @override
  void initState() {
    super.initState();
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
    final members = await IdolDatabaseService.getMembers();

    int? selectedGroupId;
    int? selectedMemberId;

    _idolGroups = groups;
    _idolMembers = members;

    if (widget.initialData != null && widget.initialData!.groupName.isNotEmpty) {
      final matchedGroup = _findGroupByName(widget.initialData!.groupName);
      selectedGroupId = matchedGroup?.id;

      final matchedMember = _findMemberByNames(
        widget.initialData!.groupName,
        widget.initialData!.name,
      );
      selectedMemberId = matchedMember?.id;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedIdolGroupId = selectedGroupId;
      _selectedIdolMemberId = selectedMemberId;
      _useIdolDatabase = groups.isNotEmpty;
      _idolLoading = false;
    });
  }

  List<IdolMember> get _filteredIdolMembers {
    return _idolMembers
        .where(
          (member) =>
              _selectedIdolGroupId == null ||
              member.groupId == _selectedIdolGroupId,
        )
        .toList();
  }

  IdolGroup? _findGroupById(int? id) {
    for (final group in _idolGroups) {
      if (group.id == id) {
        return group;
      }
    }
    return null;
  }

  IdolGroup? _findGroupByName(String name) {
    for (final group in _idolGroups) {
      if (group.name == name) {
        return group;
      }
    }
    return null;
  }

  IdolMember? _findMemberById(int? id) {
    for (final member in _filteredIdolMembers) {
      if (member.id == id) {
        return member;
      }
    }
    return null;
  }

  IdolMember? _findMemberByNames(String groupName, String memberName) {
    for (final member in _idolMembers) {
      if (member.groupName == groupName && member.name == memberName) {
        return member;
      }
    }
    return null;
  }

  void _applySelectedIdol(IdolMember member) {
    _nameController.text = member.name;
    _groupController.text = member.groupName;
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

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialData != null;

    return AlertDialog(
      title: Text(isEditing ? '编辑计数器' : '添加新计数器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: '成员名称',
                hintText: '请输入成员名称',
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _groupController,
              decoration: const InputDecoration(
                labelText: '所属团体',
                hintText: '可选，便于区分同名成员',
              ),
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
                      subtitle: const Text('可从中国偶像 Wiki 快照中选择成员'),
                      value: _useIdolDatabase,
                      onChanged: (value) {
                        setState(() {
                          _useIdolDatabase = value;
                        });
                      },
                    ),
                    if (_useIdolDatabase) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int?>(
                        initialValue: _selectedIdolGroupId,
                        decoration: const InputDecoration(
                          labelText: '偶像库团体',
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('先选择团体'),
                          ),
                          ..._idolGroups.where((group) => group.id != null).map(
                                (group) => DropdownMenuItem<int?>(
                                  value: group.id!,
                                  child: Text(group.name),
                                ),
                              ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _selectedIdolGroupId = value;
                            _selectedIdolMemberId = null;
                          });

                          final group = _findGroupById(value);
                          _groupController.text = group?.name ?? '';
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int?>(
                        initialValue: _selectedIdolMemberId,
                        decoration: const InputDecoration(
                          labelText: '偶像库成员',
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('再选择成员'),
                          ),
                          ..._filteredIdolMembers
                              .where((member) => member.id != null)
                              .map(
                                (member) => DropdownMenuItem<int?>(
                                  value: member.id!,
                                  child: Text(
                                    member.status.isEmpty
                                        ? member.name
                                        : '${member.name} · ${member.status}',
                                  ),
                                ),
                              ),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _selectedIdolMemberId = value;
                          });

                          final member = _findMemberById(value);
                          if (member != null) {
                            _applySelectedIdol(member);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '规格计数（留空默认 0）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final fieldWidth = constraints.maxWidth > 360
                    ? (constraints.maxWidth - 12) / 2
                    : constraints.maxWidth;

                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: CounterCountField.values.map((field) {
                    return SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: _countControllers[field.key],
                        decoration: InputDecoration(
                          labelText: field.label,
                          hintText: '0',
                          errorText: _countErrors[field.key],
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    );
                  }).toList(),
                );
              },
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
                child: const Icon(Icons.color_lens, color: Colors.white),
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
            if (!_validate()) return;

            final name = _nameController.text.trim();

            Navigator.of(context).pop(
              CounterModel(
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
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
