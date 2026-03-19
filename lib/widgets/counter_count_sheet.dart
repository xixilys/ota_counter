import 'dart:async';

import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../services/idol_database_service.dart';
import '../models/idol_database_models.dart';
import 'no_autofill_text_field.dart';

class CounterRecordTarget {
  final String key;
  final String label;
  final CounterModel counter;

  const CounterRecordTarget({
    required this.key,
    required this.label,
    required this.counter,
  });
}

class CounterCountSheet extends StatefulWidget {
  final CounterModel counter;
  final List<CounterModel> allCounters;
  final Future<CounterModel> Function(
    CounterModel updatedCounter,
    DateTime occurredAt,
  ) onCounterChanged;

  const CounterCountSheet({
    super.key,
    required this.counter,
    required this.allCounters,
    required this.onCounterChanged,
  });

  @override
  State<CounterCountSheet> createState() => _CounterCountSheetState();
}

class _CounterCountSheetState extends State<CounterCountSheet> {
  late CounterModel _counter;
  late DateTime _occurredAt;
  late List<CounterRecordTarget> _targets;
  late String _selectedTargetKey;
  bool _enableUnsignedOptions = false;
  bool _targetsLoading = false;

  @override
  void initState() {
    super.initState();
    _counter = widget.counter;
    _occurredAt = DateTime.now();
    _targets = [
      _buildTarget(
        widget.counter,
        labelOverride: _buildTargetLabel(
          widget.counter.groupName,
          widget.counter.name,
          isCurrent: true,
        ),
      ),
    ];
    _selectedTargetKey = _targets.first.key;
    _loadUnsignedOptions();
    _loadRecordTargets();
  }

  Future<void> _loadUnsignedOptions() async {
    final pricing =
        await DatabaseService.getGroupPricingByName(_counter.groupName) ??
            GroupPricingModel.unconfigured(_counter.groupName);
    if (!mounted) {
      return;
    }
    setState(() {
      _enableUnsignedOptions = pricing.enableUnsignedOptions;
    });
  }

  String _normalizeLookupValue(String value) {
    return value.trim().toLowerCase();
  }

  String _groupKey(String groupName) {
    return _normalizeLookupValue(groupName);
  }

  bool _hasExplicitCounterIdentity(CounterModel counter) {
    return counter.personId != null || counter.personName.trim().isNotEmpty;
  }

  String _explicitCounterPersonName(CounterModel counter) {
    final personName = counter.personName.trim();
    if (personName.isNotEmpty) {
      return personName;
    }
    if (counter.personId != null) {
      return counter.name.trim();
    }
    return '';
  }

  String _resolvedMemberPersonName(IdolMember member) {
    final personName = member.resolvedPersonName.trim();
    if (personName.isNotEmpty) {
      return personName;
    }
    return member.displayName.trim();
  }

  String _buildTargetLabel(
    String groupName,
    String memberName, {
    required bool isCurrent,
  }) {
    final segments = <String>[
      if (groupName.trim().isNotEmpty) groupName.trim() else '未分组',
      if (memberName.trim().isNotEmpty) memberName.trim(),
      if (isCurrent) '当前卡片',
    ];
    return segments.join(' · ');
  }

  CounterRecordTarget _buildTarget(
    CounterModel counter, {
    String? labelOverride,
  }) {
    return CounterRecordTarget(
      key: _groupKey(counter.groupName),
      label: labelOverride ??
          _buildTargetLabel(
            counter.groupName,
            counter.name,
            isCurrent: _groupKey(counter.groupName) ==
                _groupKey(widget.counter.groupName),
          ),
      counter: counter,
    );
  }

  bool _memberMatchesCounter(IdolMember member) {
    if (!_hasExplicitCounterIdentity(widget.counter)) {
      return false;
    }

    final counterPersonId = widget.counter.personId;
    if (counterPersonId != null && member.personId != null) {
      return member.personId == counterPersonId;
    }

    return _normalizeLookupValue(_resolvedMemberPersonName(member)) ==
        _normalizeLookupValue(_explicitCounterPersonName(widget.counter));
  }

  bool _counterMatchesWidgetCounter(CounterModel counter) {
    if (!_hasExplicitCounterIdentity(widget.counter) ||
        !_hasExplicitCounterIdentity(counter)) {
      return false;
    }

    if (counter.id != null &&
        widget.counter.id != null &&
        counter.id == widget.counter.id) {
      return false;
    }

    final currentPersonId = widget.counter.personId;
    final candidatePersonId = counter.personId;
    if (currentPersonId != null &&
        candidatePersonId != null &&
        currentPersonId == candidatePersonId) {
      return true;
    }

    final currentPersonName = _explicitCounterPersonName(widget.counter);
    if (currentPersonName.isEmpty) {
      return false;
    }

    return _normalizeLookupValue(_explicitCounterPersonName(counter)) ==
        _normalizeLookupValue(currentPersonName);
  }

  int _compareTargetGroups(String aGroupName, String bGroupName) {
    final aIsCurrent =
        _groupKey(aGroupName) == _groupKey(widget.counter.groupName);
    final bIsCurrent =
        _groupKey(bGroupName) == _groupKey(widget.counter.groupName);
    if (aIsCurrent != bIsCurrent) {
      return aIsCurrent ? -1 : 1;
    }
    return aGroupName.toLowerCase().compareTo(bGroupName.toLowerCase());
  }

  CounterModel? _findExistingCounterForMember(IdolMember member) {
    final targetGroupKey = _groupKey(member.groupName);

    for (final counter in widget.allCounters) {
      if (_groupKey(counter.groupName) != targetGroupKey) {
        continue;
      }

      if (widget.counter.personId != null && counter.personId != null) {
        if (counter.personId == widget.counter.personId) {
          return counter;
        }
        continue;
      }

      if (_normalizeLookupValue(_explicitCounterPersonName(counter)) ==
          _normalizeLookupValue(_resolvedMemberPersonName(member))) {
        return counter;
      }
    }

    return null;
  }

  CounterModel _buildDraftCounterForMember(IdolMember member) {
    return CounterModel(
      name: member.displayName.trim().isEmpty
          ? widget.counter.name
          : member.displayName,
      groupName: member.groupName.trim(),
      personId: member.personId ?? widget.counter.personId,
      personName: member.resolvedPersonName.trim().isEmpty
          ? _explicitCounterPersonName(widget.counter)
          : member.resolvedPersonName.trim(),
      color: widget.counter.color,
    );
  }

  Future<void> _loadRecordTargets() async {
    final hasPersonId = widget.counter.personId != null;
    final hasPersonName = widget.counter.personName.trim().isNotEmpty;
    if (!hasPersonId && !hasPersonName) {
      return;
    }

    setState(() {
      _targetsLoading = true;
    });

    try {
      await IdolDatabaseService.initializeBuiltInDataIfNeeded();
      final members = await IdolDatabaseService.getMembers();
      final matchedMembers = members.where(_memberMatchesCounter).toList()
        ..sort((a, b) {
          final aIsCurrent =
              _groupKey(a.groupName) == _groupKey(widget.counter.groupName);
          final bIsCurrent =
              _groupKey(b.groupName) == _groupKey(widget.counter.groupName);
          if (aIsCurrent != bIsCurrent) {
            return aIsCurrent ? -1 : 1;
          }
          if (a.isActiveAffiliation != b.isActiveAffiliation) {
            return a.isActiveAffiliation ? -1 : 1;
          }
          return a.groupName.toLowerCase().compareTo(b.groupName.toLowerCase());
        });

      if (!mounted) {
        return;
      }

      final targetsByKey = <String, CounterRecordTarget>{
        _targets.first.key: _targets.first,
      };

      final relatedCounters = widget.allCounters
          .where(_counterMatchesWidgetCounter)
          .toList()
        ..sort((a, b) => _compareTargetGroups(a.groupName, b.groupName));

      for (final counter in relatedCounters) {
        final key = _groupKey(counter.groupName);
        targetsByKey[key] = _buildTarget(
          counter,
          labelOverride: _buildTargetLabel(
            counter.groupName,
            counter.name,
            isCurrent: key == _groupKey(widget.counter.groupName),
          ),
        );
      }

      for (final member in matchedMembers) {
        final existingCounter = _findExistingCounterForMember(member);
        final targetCounter =
            existingCounter ?? _buildDraftCounterForMember(member);
        final key = _groupKey(targetCounter.groupName);
        targetsByKey[key] = _buildTarget(
          targetCounter,
          labelOverride: _buildTargetLabel(
            targetCounter.groupName,
            targetCounter.name,
            isCurrent: key == _groupKey(widget.counter.groupName),
          ),
        );
      }

      final nextTargets = targetsByKey.values.toList()
        ..sort((a, b) {
          final aIsCurrent = a.key == _groupKey(widget.counter.groupName);
          final bIsCurrent = b.key == _groupKey(widget.counter.groupName);
          if (aIsCurrent != bIsCurrent) {
            return aIsCurrent ? -1 : 1;
          }
          return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        });

      setState(() {
        _targets = nextTargets;
      });
    } finally {
      if (mounted) {
        setState(() {
          _targetsLoading = false;
        });
      }
    }
  }

  void _selectTarget(String key) {
    final targetIndex = _targets.indexWhere((entry) => entry.key == key);
    if (targetIndex == -1) {
      return;
    }
    final target = _targets[targetIndex];

    setState(() {
      _selectedTargetKey = key;
      _counter = target.counter;
    });
    unawaited(_loadUnsignedOptions());
  }

  void _replaceTargetCounter(CounterModel counter) {
    final nextTarget = _buildTarget(counter);
    final nextTargets = [..._targets];
    final index =
        nextTargets.indexWhere((entry) => entry.key == nextTarget.key);
    if (index == -1) {
      nextTargets.add(nextTarget);
    } else {
      nextTargets[index] = nextTarget;
    }
    _targets = nextTargets;
  }

  Future<void> _persistCounter(
    CounterModel updatedCounter,
    String targetKey,
  ) async {
    final savedCounter =
        await widget.onCounterChanged(updatedCounter, _occurredAt);
    if (!mounted) {
      return;
    }

    setState(() {
      _replaceTargetCounter(savedCounter);
      if (_selectedTargetKey == targetKey) {
        _counter = savedCounter;
      }
    });
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

  void _changeCount(CounterCountField field, int delta) {
    final updatedCounter = _counter.changeCount(field, delta);
    if (updatedCounter.countForField(field) == _counter.countForField(field)) {
      return;
    }
    final targetKey = _selectedTargetKey;

    setState(() {
      _counter = updatedCounter;
      _replaceTargetCounter(updatedCounter);
    });
    unawaited(_persistCounter(updatedCounter, targetKey));
  }

  Future<void> _editCount(CounterCountField field) async {
    final controller = TextEditingController(
      text: _counter.countForField(field).toString(),
    );
    final nextValue = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('修改${field.label}'),
          content: NoAutofillTextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '数量',
              hintText: '请输入新的总数',
            ),
            onSubmitted: (_) {
              final parsed = int.tryParse(controller.text.trim());
              if (parsed == null || parsed < 0) {
                return;
              }
              Navigator.of(dialogContext).pop(parsed);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final parsed = int.tryParse(controller.text.trim());
                if (parsed == null || parsed < 0) {
                  return;
                }
                Navigator.of(dialogContext).pop(parsed);
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    if (!mounted || nextValue == null) {
      return;
    }

    final delta = nextValue - _counter.countForField(field);
    if (delta == 0) {
      return;
    }

    _changeCount(field, delta);
  }

  @override
  Widget build(BuildContext context) {
    final visibleFields = CounterCountField.visibleValues(
      enableUnsigned: _enableUnsignedOptions,
      includeGroupCut: false,
    );
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _counter.name,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '总计 ${_counter.count}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '快捷计数不提供减少按钮；点数字可以直接编辑总数，点按 +1 / +5 / +10 / +50 会立即保存，误点请到最近提交记录里删除对应记录。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('记录日期'),
                subtitle: Text(_formatDate(_occurredAt)),
                trailing: const Icon(Icons.edit_calendar_outlined),
                onTap: _pickDateTime,
              ),
              if (_targetsLoading) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (_targets.length > 1) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _selectedTargetKey,
                  decoration: const InputDecoration(
                    labelText: '记录到团体',
                    helperText: '默认当前卡片所属团体，也可以切到这个真人的其他团籍',
                  ),
                  items: _targets.map((target) {
                    return DropdownMenuItem<String>(
                      value: target.key,
                      child: Text(target.label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value == null || value == _selectedTargetKey) {
                      return;
                    }
                    _selectTarget(value);
                  },
                ),
              ],
              const SizedBox(height: 16),
              ...visibleFields.map((field) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _CountAdjustRow(
                    field: field,
                    value: _counter.countForField(field),
                    onEditValue: () => _editCount(field),
                    onAddOne: () => _changeCount(field, 1),
                    onAddFive: () => _changeCount(field, 5),
                    onAddTen: () => _changeCount(field, 10),
                    onAddFifty: () => _changeCount(field, 50),
                  ),
                );
              }),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ReadOnlyCountRow(
                  field: CounterCountField.groupCut,
                  value: _counter.groupCutCount,
                  helperText: '团切请通过多人切记录处理，这里仅展示当前累计数量。',
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.check),
                  label: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyCountRow extends StatelessWidget {
  final CounterCountField field;
  final int value;
  final String helperText;

  const _ReadOnlyCountRow({
    required this.field,
    required this.value,
    required this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  field.label,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  helperText,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '只读',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$value',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CountAdjustRow extends StatelessWidget {
  final CounterCountField field;
  final int value;
  final VoidCallback onEditValue;
  final VoidCallback onAddOne;
  final VoidCallback onAddFive;
  final VoidCallback onAddTen;
  final VoidCallback onAddFifty;

  const _CountAdjustRow({
    required this.field,
    required this.value,
    required this.onEditValue,
    required this.onAddOne,
    required this.onAddFive,
    required this.onAddTen,
    required this.onAddFifty,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  field.label,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onEditValue,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$value',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _IncrementButton(label: '+1', onPressed: onAddOne),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _IncrementButton(label: '+5', onPressed: onAddFive),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _IncrementButton(label: '+10', onPressed: onAddTen),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _IncrementButton(label: '+50', onPressed: onAddFifty),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IncrementButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _IncrementButton({
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}
