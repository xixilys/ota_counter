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
  final List<ActivityParticipant> multiParticipants;
  final CounterCountField? multiField;
  final int multiQuantity;
  final double multiTotalPrice;
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
    this.multiParticipants = const [],
    this.multiField,
    this.multiQuantity = 1,
    this.multiTotalPrice = 0,
    this.eventName = '',
    this.sessionLabel = '',
    this.ticketQuantity = 0,
    this.ticketUnitPrice = 0,
  });
}

class AddActivityRecordDialog extends StatefulWidget {
  final List<CounterModel> counters;
  final List<GroupPricingModel> pricings;
  final ActivityRecordDraft? initialDraft;
  final String title;
  final String submitLabel;

  const AddActivityRecordDialog({
    super.key,
    required this.counters,
    required this.pricings,
    this.initialDraft,
    this.title = '新增记录',
    this.submitLabel = '保存记录',
  });

  @override
  State<AddActivityRecordDialog> createState() =>
      _AddActivityRecordDialogState();
}

class _AddActivityRecordDialogState extends State<AddActivityRecordDialog> {
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _multiQuantityController =
      TextEditingController(text: '1');
  final TextEditingController _multiPriceController =
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
  List<IdolMember> _idolMembers = [];
  bool _idolLoading = false;
  List<ActivityParticipant> _selectedParticipants = [];
  CounterCountField _selectedMultiField = CounterCountField.threeInch;
  DateTime _occurredAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _countControllers = {
      for (final field in CounterCountField.values)
        field.key: TextEditingController(text: '0'),
    };
    _initializeFromDraft();
    _loadIdolDatabase();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _multiQuantityController.dispose();
    _multiPriceController.dispose();
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
      _idolLoading = true;
    });

    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final members = await IdolDatabaseService.getMembers();

    if (!mounted) {
      return;
    }

    setState(() {
      _idolMembers = members;
      _idolLoading = false;
    });
  }

  void _initializeFromDraft() {
    final draft = widget.initialDraft;
    if (draft == null) {
      return;
    }

    _type = draft.type;
    _selectedCounter = draft.counter;
    _selectedParticipants = List<ActivityParticipant>.from(
      draft.multiParticipants,
    );
    _selectedMultiField = draft.multiField ?? _selectedMultiField;
    _occurredAt = draft.occurredAt;

    _noteController.text = draft.note;
    _multiQuantityController.text = '${draft.multiQuantity}';
    _multiPriceController.text = _formatEditableNumber(draft.multiTotalPrice);
    _eventNameController.text = draft.eventName;
    _sessionController.text = draft.sessionLabel;
    _ticketQuantityController.text = '${draft.ticketQuantity}';
    _ticketPriceController.text = _formatEditableNumber(draft.ticketUnitPrice);

    for (final field in CounterCountField.values) {
      _countControllers[field.key]!.text = '${draft.counterDeltas[field] ?? 0}';
    }
  }

  String _formatEditableNumber(num value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toString();
  }

  GroupPricingModel get _selectedPricing {
    final groupName = _selectedCounter?.groupName.trim() ?? '';
    return _resolvePricingByGroupName(groupName) ??
        GroupPricingModel.unconfigured(groupName);
  }

  GroupPricingModel? _resolvePricingByGroupName(String groupName) {
    final normalized = groupName.trim();
    if (normalized.isEmpty) {
      return null;
    }
    for (final pricing in widget.pricings) {
      if (pricing.groupName.trim() == normalized) {
        return pricing;
      }
    }
    return GroupPricingModel.unconfigured(normalized);
  }

  int _parseCount(CounterCountField field) {
    return int.tryParse(_countControllers[field.key]!.text.trim()) ?? 0;
  }

  int get _ticketQuantity =>
      int.tryParse(_ticketQuantityController.text.trim()) ?? 0;

  int get _multiQuantity =>
      int.tryParse(_multiQuantityController.text.trim()) ?? 0;

  double get _ticketUnitPrice =>
      double.tryParse(_ticketPriceController.text.trim()) ?? 0;

  double get _counterPreviewTotal {
    final pricing = _selectedPricing;
    return CounterCountField.visibleValues(
      enableUnsigned: pricing.hasUnsignedPrices,
    ).fold<double>(0, (sum, field) {
      return sum + (_parseCount(field) * pricing.priceForField(field));
    });
  }

  GroupPricingModel? get _multiSuggestedPricing {
    final groupNames = _selectedParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet();
    if (groupNames.length != 1) {
      return null;
    }

    final groupName = groupNames.first;
    return _resolvePricingByGroupName(groupName);
  }

  bool get _multiAllowsUnsignedOptions {
    if (_selectedParticipants.isEmpty) {
      return false;
    }

    final groupNames = _selectedParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet();
    if (groupNames.isEmpty) {
      return false;
    }

    for (final groupName in groupNames) {
      final pricing = _resolvePricingByGroupName(groupName);
      if (pricing?.hasUnsignedPrices != true) {
        return false;
      }
    }
    return true;
  }

  List<CounterCountField> get _counterVisibleFields {
    return CounterCountField.visibleValues(
      enableUnsigned: _selectedPricing.hasUnsignedPrices ||
          (_selectedCounter?.hasUnsignedCounts ?? false),
    );
  }

  List<CounterCountField> get _multiVisibleFields {
    return CounterCountField.multiVisibleValues(
      enableUnsigned: _multiAllowsUnsignedOptions,
    );
  }

  List<IdolMember> get _fallbackMembers {
    final entries = <String, IdolMember>{};
    for (final counter in widget.counters) {
      final memberName = counter.name.trim();
      if (memberName.isEmpty) {
        continue;
      }
      final groupName = counter.groupName.trim();
      final key = '${groupName.toLowerCase()}|${memberName.toLowerCase()}';
      entries.putIfAbsent(
        key,
        () => IdolMember(
          groupId: 0,
          personId: counter.personId,
          groupName: groupName,
          personName: counter.personName,
          name: memberName,
        ),
      );
    }
    final members = entries.values.toList()
      ..sort((a, b) {
        final groupCompare = a.groupName.toLowerCase().compareTo(
              b.groupName.toLowerCase(),
            );
        if (groupCompare != 0) {
          return groupCompare;
        }
        return a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            );
      });
    return members;
  }

  List<IdolMember> get _selectableMembers {
    if (_idolMembers.isNotEmpty) {
      return _idolMembers;
    }
    return _fallbackMembers;
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

  String _participantKey(ActivityParticipant participant) {
    final normalizedGroup = participant.groupName.trim().toLowerCase();
    final normalizedMember = participant.memberName.trim().toLowerCase();
    return '$normalizedGroup|$normalizedMember';
  }

  Future<void> _pickMultiParticipant() async {
    final excludedKeys = _selectedParticipants.map(_participantKey).toSet();
    final availableMembers = _selectableMembers.where((member) {
      final key =
          '${member.groupName.trim().toLowerCase()}|${member.displayName.trim().toLowerCase()}';
      return !excludedKeys.contains(key);
    }).toList(growable: false);

    final selected = await showModalBottomSheet<IdolMember>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _IdolMemberSearchSheet(
        title: '添加多人切成员',
        members: availableMembers,
      ),
    );

    if (selected == null || !mounted) {
      return;
    }

    final nextParticipants = [
      ..._selectedParticipants,
      ActivityParticipant(
        memberName: selected.displayName,
        groupName: selected.groupName,
        personId: selected.personId,
        personName: selected.resolvedPersonName,
      ),
    ];
    final nextGroupNames = nextParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet();
    final nextPricing = nextGroupNames.length == 1
        ? _resolvePricingByGroupName(nextGroupNames.first)
        : null;
    final nextAllowsUnsigned = nextGroupNames.isNotEmpty &&
        nextGroupNames.every(
          (groupName) =>
              _resolvePricingByGroupName(groupName)?.hasUnsignedPrices == true,
        );
    final nextVisibleFields = CounterCountField.multiVisibleValues(
      enableUnsigned: nextAllowsUnsigned,
    );
    final nextSelectedField = nextVisibleFields.contains(_selectedMultiField)
        ? _selectedMultiField
        : nextVisibleFields.first;

    setState(() {
      _selectedParticipants = nextParticipants;
      _selectedMultiField = nextSelectedField;
      final suggestedPricing = nextPricing;
      if ((_multiPriceController.text.trim().isEmpty ||
              _multiPriceController.text.trim() == '0') &&
          suggestedPricing != null &&
          suggestedPricing.doubleCutPrice > 0) {
        _multiPriceController.text =
            suggestedPricing.doubleCutPrice.toStringAsFixed(0);
      }
    });
  }

  void _removeParticipantAt(int index) {
    setState(() {
      final next = [..._selectedParticipants];
      next.removeAt(index);
      _selectedParticipants = next;
      final visibleFields = _multiVisibleFields;
      if (!visibleFields.contains(_selectedMultiField)) {
        _selectedMultiField = visibleFields.first;
      }
    });
  }

  void _submit() {
    if (_type == ActivityRecordType.counter) {
      if (_selectedCounter == null) {
        return;
      }

      final counterDeltas = {
        for (final field in _counterVisibleFields) field: _parseCount(field),
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

    if (_type == ActivityRecordType.multi) {
      if (_selectedParticipants.length < 2 ||
          _multiQuantity <= 0 ||
          !_multiVisibleFields.contains(_selectedMultiField)) {
        return;
      }

      Navigator.of(context).pop(
        ActivityRecordDraft(
          type: _type,
          occurredAt: _occurredAt,
          note: _noteController.text.trim(),
          multiParticipants: _selectedParticipants,
          multiField: _selectedMultiField,
          multiQuantity: _multiQuantity,
          multiTotalPrice:
              double.tryParse(_multiPriceController.text.trim()) ?? 0,
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
    final multiSuggestedPricing = _multiSuggestedPricing;
    final participantGroups = _selectedParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final multiPreviewTotal =
        double.tryParse(_multiPriceController.text.trim()) ?? 0;
    final ticketPreviewTotal = _ticketQuantity * _ticketUnitPrice;

    return AlertDialog(
      title: Text(widget.title),
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
                  value: ActivityRecordType.multi,
                  label: Text('多人切'),
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
                      children: _counterVisibleFields.map((field) {
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
              ..._counterVisibleFields.map((field) {
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
            ] else if (_type == ActivityRecordType.multi) ...[
              if (_idolLoading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MetricPill(
                    label: '已选人数',
                    value: '${_selectedParticipants.length}',
                  ),
                  const _MetricPill(
                    label: '金额规则',
                    value: '统计时均摊',
                  ),
                  _MetricPill(
                    label: '当前规格',
                    value: _selectedMultiField.label,
                  ),
                  if (multiSuggestedPricing != null)
                    _MetricPill(
                      label: '单团参考价',
                      value:
                          '¥${multiSuggestedPricing.doubleCutPrice.toStringAsFixed(multiSuggestedPricing.doubleCutPrice == multiSuggestedPricing.doubleCutPrice.roundToDouble() ? 0 : 2)}',
                    ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: _pickMultiParticipant,
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('添加参与成员'),
              ),
              if (_selectableMembers.isEmpty && !_idolLoading) ...[
                const SizedBox(height: 12),
                Text(
                  '当前没有可选成员，请先在偶像数据库或主页计数器里补成员。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (_selectedParticipants.isNotEmpty) ...[
                const SizedBox(height: 12),
                ..._selectedParticipants.asMap().entries.map((entry) {
                  final index = entry.key;
                  final participant = entry.value;
                  final subtitle = [
                    if (participant.groupName.trim().isNotEmpty)
                      participant.groupName.trim(),
                    if (participant.personName.trim().isNotEmpty &&
                        participant.personName.trim() !=
                            participant.memberName.trim())
                      '真人 ${participant.personName.trim()}',
                  ].join(' · ');

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      title: Text(participant.memberName),
                      subtitle: subtitle.isEmpty ? null : Text(subtitle),
                      trailing: IconButton(
                        onPressed: () => _removeParticipantAt(index),
                        icon: const Icon(Icons.close),
                        tooltip: '移除',
                      ),
                    ),
                  );
                }),
              ],
              if (participantGroups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '涉及团体：${participantGroups.join(' / ')}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Text(
                '规格',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _multiVisibleFields.map((field) {
                  final selected = field == _selectedMultiField;
                  return ChoiceChip(
                    label: Text(field.label),
                    selected: selected,
                    onSelected: (_) {
                      setState(() {
                        _selectedMultiField = field;
                      });
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _multiQuantityController,
                decoration: const InputDecoration(
                  labelText: '每人成交数量',
                  hintText: '1',
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _multiPriceController,
                decoration: const InputDecoration(
                  labelText: '多人切总价',
                  prefixText: '¥',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text(
                '预计金额：¥${multiPreviewTotal.toStringAsFixed(multiPreviewTotal == multiPreviewTotal.roundToDouble() ? 0 : 2)}',
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
          child: Text(widget.submitLabel),
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
    }).toList()
      ..sort((a, b) {
        if (a.isActiveAffiliation != b.isActiveAffiliation) {
          return a.isActiveAffiliation ? -1 : 1;
        }
        final personCompare = a.resolvedPersonName.toLowerCase().compareTo(
              b.resolvedPersonName.toLowerCase(),
            );
        if (personCompare != 0) {
          return personCompare;
        }
        final groupCompare = a.groupName.toLowerCase().compareTo(
              b.groupName.toLowerCase(),
            );
        if (groupCompare != 0) {
          return groupCompare;
        }
        return a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            );
      });

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
                    if (member.resolvedPersonName != member.displayName)
                      '真人 ${member.resolvedPersonName}',
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
