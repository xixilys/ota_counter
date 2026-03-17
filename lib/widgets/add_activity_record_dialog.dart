import 'package:flutter/material.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../models/idol_database_models.dart';
import '../services/idol_database_service.dart';
import 'no_autofill_text_field.dart';

class ActivityRecordDraft {
  final ActivityRecordType type;
  final CounterModel? counter;
  final DateTime occurredAt;
  final String note;
  final Map<CounterCountField, int> counterDeltas;
  final String duoGroupName;
  final String primaryMemberName;
  final String secondaryMemberName;
  final int duoQuantity;
  final double duoUnitPrice;
  final String eventName;
  final String sessionLabel;
  final int ticketQuantity;
  final double ticketUnitPrice;

  const ActivityRecordDraft({
    required this.type,
    required this.occurredAt,
    this.counter,
    this.note = '',
    this.counterDeltas = const {},
    this.duoGroupName = '',
    this.primaryMemberName = '',
    this.secondaryMemberName = '',
    this.duoQuantity = 0,
    this.duoUnitPrice = 0,
    this.eventName = '',
    this.sessionLabel = '',
    this.ticketQuantity = 0,
    this.ticketUnitPrice = 0,
  });
}

class AddActivityRecordDialog extends StatefulWidget {
  final List<CounterModel> counters;
  final List<GroupPricingModel> pricings;

  const AddActivityRecordDialog({
    super.key,
    required this.counters,
    required this.pricings,
  });

  @override
  State<AddActivityRecordDialog> createState() =>
      _AddActivityRecordDialogState();
}

class _AddActivityRecordDialogState extends State<AddActivityRecordDialog> {
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _duoPrimaryController = TextEditingController();
  final TextEditingController _duoSecondaryController = TextEditingController();
  final TextEditingController _duoQuantityController =
      TextEditingController(text: '1');
  final TextEditingController _duoPriceController =
      TextEditingController(text: '0');
  final TextEditingController _eventNameController = TextEditingController();
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _ticketQuantityController =
      TextEditingController(text: '1');
  final TextEditingController _ticketPriceController =
      TextEditingController(text: '0');
  late final Map<String, TextEditingController> _countControllers;

  ActivityRecordType _type = ActivityRecordType.counter;
  CounterModel? _selectedCounter;
  List<IdolGroup> _idolGroups = [];
  List<IdolMember> _duoMembers = [];
  bool _idolGroupLoading = false;
  bool _duoMemberLoading = false;
  int? _selectedDuoGroupId;
  int? _selectedDuoPrimaryMemberId;
  int? _selectedDuoSecondaryMemberId;
  String _selectedDuoGroupName = '';
  DateTime _occurredAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _countControllers = {
      for (final field in CounterCountField.values)
        field.key: TextEditingController(text: '0'),
    };
    _loadIdolDatabase();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _duoPrimaryController.dispose();
    _duoSecondaryController.dispose();
    _duoQuantityController.dispose();
    _duoPriceController.dispose();
    _eventNameController.dispose();
    _sessionController.dispose();
    _ticketQuantityController.dispose();
    _ticketPriceController.dispose();
    for (final controller in _countControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadIdolDatabase() async {
    setState(() {
      _idolGroupLoading = true;
    });

    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final groups = await IdolDatabaseService.getGroups();

    if (!mounted) {
      return;
    }

    setState(() {
      _idolGroups = groups;
      _idolGroupLoading = false;
    });
  }

  GroupPricingModel get _selectedPricing {
    final groupName = _selectedCounter?.groupName.trim() ?? '';
    for (final pricing in widget.pricings) {
      if (pricing.groupName.trim() == groupName) {
        return pricing;
      }
    }
    return GroupPricingModel.unconfigured(groupName);
  }

  int _parseCount(CounterCountField field) {
    return int.tryParse(_countControllers[field.key]!.text.trim()) ?? 0;
  }

  int get _ticketQuantity =>
      int.tryParse(_ticketQuantityController.text.trim()) ?? 0;

  int get _duoQuantity => int.tryParse(_duoQuantityController.text.trim()) ?? 0;

  double get _duoUnitPrice =>
      double.tryParse(_duoPriceController.text.trim()) ?? 0;

  double get _ticketUnitPrice =>
      double.tryParse(_ticketPriceController.text.trim()) ?? 0;

  double get _counterPreviewTotal {
    final pricing = _selectedPricing;
    return CounterCountField.values.fold<double>(0, (sum, field) {
      return sum + (_parseCount(field) * pricing.priceForField(field));
    });
  }

  GroupPricingModel get _duoPricing {
    final groupName = _selectedDuoGroupName.trim();
    for (final pricing in widget.pricings) {
      if (pricing.groupName.trim() == groupName) {
        return pricing;
      }
    }
    return GroupPricingModel.unconfigured(groupName);
  }

  List<String> get _fallbackDuoGroupNames {
    final names = <String>{
      for (final pricing in widget.pricings)
        if (pricing.groupName.trim().isNotEmpty) pricing.groupName.trim(),
      for (final counter in widget.counters)
        if (counter.groupName.trim().isNotEmpty) counter.groupName.trim(),
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  List<IdolGroup> get _duoSelectableGroups {
    if (_idolGroups.isNotEmpty) {
      return _idolGroups;
    }
    return _fallbackDuoGroupNames
        .map((groupName) => IdolGroup(name: groupName))
        .toList();
  }

  List<IdolMember> _fallbackMembersForGroup(String groupName) {
    final trimmedGroupName = groupName.trim();
    if (trimmedGroupName.isEmpty) {
      return const <IdolMember>[];
    }

    final memberNames = <String>{
      for (final counter in widget.counters)
        if (counter.groupName.trim() == trimmedGroupName &&
            counter.name.trim().isNotEmpty)
          counter.name.trim(),
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return memberNames
        .map(
          (memberName) => IdolMember(
            groupId: 0,
            groupName: trimmedGroupName,
            name: memberName,
          ),
        )
        .toList();
  }

  List<IdolMember> get _duoSelectableMembers {
    if (_duoMembers.isNotEmpty) {
      return _duoMembers;
    }
    return _fallbackMembersForGroup(_selectedDuoGroupName);
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

  Future<void> _pickCounter() async {
    final selected = await showModalBottomSheet<CounterModel>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _CounterSearchSheet(counters: widget.counters),
    );
    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _selectedCounter = selected;
    });
  }

  Future<void> _pickDuoGroup() async {
    final selected = await showModalBottomSheet<IdolGroup>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _IdolGroupSearchSheet(
        title: '搜索团体',
        groups: _duoSelectableGroups,
      ),
    );
    if (selected == null || !mounted) {
      return;
    }

    final pricing = widget.pricings.cast<GroupPricingModel?>().firstWhere(
          (item) => item?.groupName.trim() == selected.name.trim(),
          orElse: () => null,
        );

    final fallbackMembers = _fallbackMembersForGroup(selected.name);

    setState(() {
      _selectedDuoGroupId = selected.id;
      _selectedDuoGroupName = selected.name;
      _selectedDuoPrimaryMemberId = null;
      _selectedDuoSecondaryMemberId = null;
      _duoMembers = selected.id == null ? fallbackMembers : [];
      _duoMemberLoading = selected.id != null;
      _duoPrimaryController.clear();
      _duoSecondaryController.clear();
      if (_duoPriceController.text.trim().isEmpty ||
          _duoPriceController.text.trim() == '0') {
        _duoPriceController.text =
            (pricing?.doubleCutPrice ?? 0).toStringAsFixed(0);
      }
    });

    if (selected.id != null) {
      await _loadDuoMembersForGroup(selected.id);
    }
  }

  Future<void> _loadDuoMembersForGroup(int? groupId) async {
    if (groupId == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _duoMembers = _fallbackMembersForGroup(_selectedDuoGroupName);
        _duoMemberLoading = false;
      });
      return;
    }

    setState(() {
      _duoMemberLoading = true;
      _duoMembers = [];
    });

    final members = await IdolDatabaseService.getMembers(groupId: groupId);
    if (!mounted || _selectedDuoGroupId != groupId) {
      return;
    }

    final fallbackMembers = _fallbackMembersForGroup(_selectedDuoGroupName);
    setState(() {
      _duoMembers = members.isNotEmpty ? members : fallbackMembers;
      _duoMemberLoading = false;
    });
  }

  IdolMember? _findDuoMemberById(int? id) {
    if (id == null) {
      return null;
    }
    for (final member in _duoMembers) {
      if (member.id == id) {
        return member;
      }
    }
    return null;
  }

  Future<void> _pickDuoMember({required bool primary}) async {
    if (_selectedDuoGroupName.trim().isEmpty) {
      return;
    }

    final groupId = _selectedDuoGroupId;
    if (groupId != null && _duoMembers.isEmpty && !_duoMemberLoading) {
      await _loadDuoMembersForGroup(groupId);
    }

    if (!mounted) {
      return;
    }

    final excludedId =
        primary ? _selectedDuoSecondaryMemberId : _selectedDuoPrimaryMemberId;
    final excludedName = primary
        ? _duoSecondaryController.text.trim()
        : _duoPrimaryController.text.trim();
    final availableMembers = _duoSelectableMembers.where((member) {
      if (excludedId != null && member.id != null) {
        return member.id != excludedId;
      }
      if (excludedName.isNotEmpty) {
        return member.displayName != excludedName;
      }
      return true;
    }).toList();

    final selected = await showModalBottomSheet<IdolMember>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _IdolMemberSearchSheet(
        title: primary ? '搜索成员 A' : '搜索成员 B',
        members: availableMembers,
      ),
    );

    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      if (primary) {
        _selectedDuoPrimaryMemberId = selected.id;
        _duoPrimaryController.text = selected.displayName;
      } else {
        _selectedDuoSecondaryMemberId = selected.id;
        _duoSecondaryController.text = selected.displayName;
      }
    });
  }

  void _submit() {
    if (_type == ActivityRecordType.counter) {
      if (_selectedCounter == null) {
        return;
      }

      final counterDeltas = {
        for (final field in CounterCountField.values) field: _parseCount(field),
      };
      final hasCount = counterDeltas.values.any((value) => value != 0);
      if (!hasCount) {
        return;
      }

      Navigator.of(context).pop(
        ActivityRecordDraft(
          type: _type,
          counter: _selectedCounter,
          occurredAt: _occurredAt,
          note: _noteController.text.trim(),
          counterDeltas: counterDeltas,
        ),
      );
      return;
    }

    if (_type == ActivityRecordType.duo) {
      final groupName = _selectedDuoGroupName.trim();
      final primaryMember = _duoPrimaryController.text.trim();
      final secondaryMember = _duoSecondaryController.text.trim();

      if (groupName.isEmpty ||
          primaryMember.isEmpty ||
          secondaryMember.isEmpty ||
          primaryMember == secondaryMember ||
          _duoQuantity <= 0) {
        return;
      }

      Navigator.of(context).pop(
        ActivityRecordDraft(
          type: _type,
          occurredAt: _occurredAt,
          note: _noteController.text.trim(),
          duoGroupName: groupName,
          primaryMemberName: primaryMember,
          secondaryMemberName: secondaryMember,
          duoQuantity: _duoQuantity,
          duoUnitPrice: _duoUnitPrice,
        ),
      );
      return;
    }

    final eventName = _eventNameController.text.trim();
    if (eventName.isEmpty || _ticketQuantity <= 0) {
      return;
    }

    Navigator.of(context).pop(
      ActivityRecordDraft(
        type: _type,
        occurredAt: _occurredAt,
        note: _noteController.text.trim(),
        eventName: eventName,
        sessionLabel: _sessionController.text.trim(),
        ticketQuantity: _ticketQuantity,
        ticketUnitPrice: _ticketUnitPrice,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pricing = _selectedPricing;
    final duoPricing = _duoPricing;
    final primaryDuoMember = _findDuoMemberById(_selectedDuoPrimaryMemberId);
    final secondaryDuoMember =
        _findDuoMemberById(_selectedDuoSecondaryMemberId);
    final primaryDuoLabel =
        primaryDuoMember?.displayName ?? _duoPrimaryController.text.trim();
    final secondaryDuoLabel =
        secondaryDuoMember?.displayName ?? _duoSecondaryController.text.trim();
    final canPickDuoMember =
        _selectedDuoGroupName.trim().isNotEmpty && !_duoMemberLoading;
    final duoPreviewTotal = _duoQuantity * _duoUnitPrice;
    final ticketPreviewTotal = _ticketQuantity * _ticketUnitPrice;

    return AlertDialog(
      title: const Text('新增记录'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<ActivityRecordType>(
              segments: const [
                ButtonSegment<ActivityRecordType>(
                  value: ActivityRecordType.counter,
                  label: Text('成员记录'),
                  icon: Icon(Icons.person_outline),
                ),
                ButtonSegment<ActivityRecordType>(
                  value: ActivityRecordType.duo,
                  label: Text('双人切'),
                  icon: Icon(Icons.people_outline),
                ),
                ButtonSegment<ActivityRecordType>(
                  value: ActivityRecordType.ticket,
                  label: Text('门票记录'),
                  icon: Icon(Icons.confirmation_num_outlined),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (selection) {
                setState(() {
                  _type = selection.first;
                });
              },
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('记录日期'),
              subtitle: Text(_formatDate(_occurredAt)),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: _pickDateTime,
            ),
            const SizedBox(height: 8),
            if (_type == ActivityRecordType.counter) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                title: const Text('成员'),
                subtitle: Text(
                  _selectedCounter == null
                      ? '点击搜索成员'
                      : '${_selectedCounter!.name}'
                          '${_selectedCounter!.groupName.trim().isEmpty ? '' : ' · ${_selectedCounter!.groupName}'}',
                ),
                trailing: const Icon(Icons.search),
                onTap: _pickCounter,
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前价格标签：${pricing.label}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: CounterCountField.values.map((field) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerLow,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${field.shortLabel} ¥${pricing.priceForField(field).toStringAsFixed(0)}',
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ...CounterCountField.values.map((field) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: NoAutofillTextField(
                    controller: _countControllers[field.key]!,
                    decoration: InputDecoration(
                      labelText: field.label,
                      hintText: '0',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (_) => setState(() {}),
                  ),
                );
              }),
              Text(
                '预计金额：¥${_counterPreviewTotal.toStringAsFixed(_counterPreviewTotal == _counterPreviewTotal.roundToDouble() ? 0 : 2)}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ] else if (_type == ActivityRecordType.duo) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                title: const Text('团体 / 价格'),
                subtitle: Text(
                  _idolGroupLoading
                      ? '正在加载偶像库...'
                      : _selectedDuoGroupName.isEmpty
                          ? '点击搜索团体'
                          : '$_selectedDuoGroupName · ${duoPricing.label}',
                ),
                trailing: const Icon(Icons.search),
                onTap: _idolGroupLoading ? null : _pickDuoGroup,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricPill(
                    label: '双人切单价',
                    value:
                        '¥${duoPricing.doubleCutPrice.toStringAsFixed(duoPricing.doubleCutPrice == duoPricing.doubleCutPrice.roundToDouble() ? 0 : 2)}',
                  ),
                  const _MetricPill(
                    label: '统计规则',
                    value: '只进团体统计',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                title: const Text('成员 A'),
                subtitle: Text(
                  primaryDuoLabel.isNotEmpty
                      ? primaryDuoLabel
                      : (_selectedDuoGroupName.isEmpty ? '请先选择团体' : '点击搜索成员'),
                ),
                trailing: const Icon(Icons.search),
                onTap: !canPickDuoMember
                    ? null
                    : () => _pickDuoMember(primary: true),
              ),
              const SizedBox(height: 12),
              if (_duoMemberLoading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                title: const Text('成员 B'),
                subtitle: Text(
                  secondaryDuoLabel.isNotEmpty
                      ? secondaryDuoLabel
                      : (_selectedDuoGroupName.isEmpty ? '请先选择团体' : '点击搜索成员'),
                ),
                trailing: const Icon(Icons.search),
                onTap: !canPickDuoMember
                    ? null
                    : () => _pickDuoMember(primary: false),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _duoQuantityController,
                decoration: const InputDecoration(
                  labelText: '双人切数量',
                  hintText: '1',
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _duoPriceController,
                decoration: const InputDecoration(
                  labelText: '双人切单价',
                  prefixText: '¥',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text(
                '预计金额：¥${duoPreviewTotal.toStringAsFixed(duoPreviewTotal == duoPreviewTotal.roundToDouble() ? 0 : 2)}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ] else ...[
              NoAutofillTextField(
                controller: _eventNameController,
                decoration: const InputDecoration(
                  labelText: '活动名称',
                  hintText: '例如 XX 公演 / Live / 特典会',
                ),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _sessionController,
                decoration: const InputDecoration(
                  labelText: '场次 / 部',
                  hintText: '例如 一部 / 夜场 / S席',
                ),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _ticketQuantityController,
                decoration: const InputDecoration(
                  labelText: '门票数量',
                  hintText: '1',
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _ticketPriceController,
                decoration: const InputDecoration(
                  labelText: '门票单价',
                  prefixText: '¥',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text(
                '预计金额：¥${ticketPreviewTotal.toStringAsFixed(ticketPreviewTotal == ticketPreviewTotal.roundToDouble() ? 0 : 2)}',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '例如 补录 / 特典 / 夜场加场',
              ),
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存记录'),
        ),
      ],
    );
  }
}

class _CounterSearchSheet extends StatefulWidget {
  final List<CounterModel> counters;

  const _CounterSearchSheet({
    required this.counters,
  });

  @override
  State<_CounterSearchSheet> createState() => _CounterSearchSheetState();
}

class _CounterSearchSheetState extends State<_CounterSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final counters = widget.counters.where((counter) {
      if (normalized.isEmpty) {
        return true;
      }
      return counter.name.toLowerCase().contains(normalized) ||
          counter.groupName.toLowerCase().contains(normalized) ||
          counter.namePinyin.toLowerCase().contains(normalized);
    }).toList()
      ..sort((a, b) => b.count.compareTo(a.count));

    return FractionallySizedBox(
      heightFactor: 0.8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '搜索成员',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: '成员名称 / 团体 / 拼音',
                prefixIcon: Icon(Icons.search),
              ),
              autofocus: true,
              onChanged: (value) {
                setState(() {
                  _query = value;
                });
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: counters.length,
                itemBuilder: (context, index) {
                  final counter = counters[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(counter.name),
                    subtitle: Text(
                      counter.groupName.trim().isEmpty
                          ? '当前总数 ${counter.count}'
                          : '${counter.groupName} · 当前总数 ${counter.count}',
                    ),
                    onTap: () => Navigator.of(context).pop(counter),
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

class _SimpleSearchSheet extends StatefulWidget {
  final String title;
  final String labelText;
  final List<String> items;

  const _SimpleSearchSheet({
    required this.title,
    required this.labelText,
    required this.items,
  });

  @override
  State<_SimpleSearchSheet> createState() => _SimpleSearchSheetState();
}

class _IdolGroupSearchSheet extends StatefulWidget {
  final String title;
  final List<IdolGroup> groups;

  const _IdolGroupSearchSheet({
    required this.title,
    required this.groups,
  });

  @override
  State<_IdolGroupSearchSheet> createState() => _IdolGroupSearchSheetState();
}

class _IdolGroupSearchSheetState extends State<_IdolGroupSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final groups = widget.groups.where((group) {
      if (normalized.isEmpty) {
        return true;
      }
      return group.name.toLowerCase().contains(normalized);
    }).toList();

    return FractionallySizedBox(
      heightFactor: 0.8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: '团体名称',
                prefixIcon: Icon(Icons.search),
              ),
              autofocus: true,
              onChanged: (value) {
                setState(() {
                  _query = value;
                });
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: groups.length,
                itemBuilder: (context, index) {
                  final group = groups[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(group.name),
                    subtitle: Text(
                      '${group.memberCount} 名成员${group.isBuiltIn ? ' · 内置' : ''}',
                    ),
                    onTap: () => Navigator.of(context).pop(group),
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

class _IdolMemberSearchSheet extends StatefulWidget {
  final String title;
  final List<IdolMember> members;

  const _IdolMemberSearchSheet({
    required this.title,
    required this.members,
  });

  @override
  State<_IdolMemberSearchSheet> createState() => _IdolMemberSearchSheetState();
}

class _IdolMemberSearchSheetState extends State<_IdolMemberSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.members.where((member) {
      return member.matchesQuery(_query);
    }).toList();

    return FractionallySizedBox(
      heightFactor: 0.8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: '成员名称 / 拼音 / 状态',
                prefixIcon: Icon(Icons.search),
              ),
              autofocus: true,
              onChanged: (value) {
                setState(() {
                  _query = value;
                });
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: members.length,
                itemBuilder: (context, index) {
                  final member = members[index];
                  final subtitleParts = <String>[
                    member.groupName,
                    if (member.status.isNotEmpty) member.status,
                  ];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(member.displayName),
                    subtitle: Text(subtitleParts.join(' · ')),
                    onTap: () => Navigator.of(context).pop(member),
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

class _SimpleSearchSheetState extends State<_SimpleSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final normalized = _query.trim().toLowerCase();
    final items = widget.items.where((item) {
      if (normalized.isEmpty) {
        return true;
      }
      return item.toLowerCase().contains(normalized);
    }).toList();

    return FractionallySizedBox(
      heightFactor: 0.8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: widget.labelText,
                prefixIcon: const Icon(Icons.search),
              ),
              autofocus: true,
              onChanged: (value) {
                setState(() {
                  _query = value;
                });
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(item),
                    onTap: () => Navigator.of(context).pop(item),
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

class _MetricPill extends StatelessWidget {
  final String label;
  final String value;

  const _MetricPill({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$label：$value'),
    );
  }
}
