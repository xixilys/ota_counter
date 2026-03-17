import 'package:flutter/material.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
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
  String _selectedDuoGroupName = '';
  DateTime _occurredAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _countControllers = {
      for (final field in CounterCountField.values)
        field.key: TextEditingController(text: '0'),
    };
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
    final groupNames = <String>{
      for (final pricing in widget.pricings)
        if (pricing.groupName.trim().isNotEmpty) pricing.groupName.trim(),
      for (final counter in widget.counters)
        if (counter.groupName.trim().isNotEmpty) counter.groupName.trim(),
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _SimpleSearchSheet(
        title: '搜索团体',
        labelText: '团体名称',
        items: groupNames,
      ),
    );
    if (selected == null || !mounted) {
      return;
    }

    final pricing = widget.pricings.cast<GroupPricingModel?>().firstWhere(
          (item) => item?.groupName.trim() == selected.trim(),
          orElse: () => null,
        );

    setState(() {
      _selectedDuoGroupName = selected;
      if (_duoPriceController.text.trim().isEmpty ||
          _duoPriceController.text.trim() == '0') {
        _duoPriceController.text =
            (pricing?.doubleCutPrice ?? 0).toStringAsFixed(0);
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
                  _selectedDuoGroupName.isEmpty
                      ? '点击搜索团体'
                      : '$_selectedDuoGroupName · ${duoPricing.label}',
                ),
                trailing: const Icon(Icons.search),
                onTap: _pickDuoGroup,
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
                ],
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _duoPrimaryController,
                decoration: const InputDecoration(
                  labelText: '成员 A',
                  hintText: '请输入第一位成员',
                ),
              ),
              const SizedBox(height: 12),
              NoAutofillTextField(
                controller: _duoSecondaryController,
                decoration: const InputDecoration(
                  labelText: '成员 B',
                  hintText: '请输入第二位成员',
                ),
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
