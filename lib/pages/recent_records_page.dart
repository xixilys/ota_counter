import 'package:flutter/material.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../widgets/add_activity_record_dialog.dart';

class RecentRecordsPage extends StatefulWidget {
  const RecentRecordsPage({super.key});

  @override
  State<RecentRecordsPage> createState() => _RecentRecordsPageState();
}

class _RecentRecordsPageState extends State<RecentRecordsPage> {
  List<CounterModel> _counters = [];
  List<ActivityRecordModel> _records = [];
  List<GroupPricingModel> _pricings = [];
  bool _loading = true;
  bool _selectionMode = false;
  final Set<int> _selectedRecordIds = <int>{};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
    });

    final counters = await DatabaseService.getCounters();
    final records = await DatabaseService.getActivityRecords();
    final pricings = await DatabaseService.getGroupPricings();

    if (!mounted) {
      return;
    }

    final nextRecords = records.where(_canMutateRecord).toList()
      ..sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
    final nextIds =
        nextRecords.map((record) => record.id).whereType<int>().toSet();

    setState(() {
      _counters = counters;
      _records = nextRecords;
      _pricings = pricings;
      _selectedRecordIds.removeWhere((id) => !nextIds.contains(id));
      if (_selectedRecordIds.isEmpty) {
        _selectionMode = false;
      }
      _loading = false;
    });
  }

  bool _canMutateRecord(ActivityRecordModel record) {
    return record.id != null && record.source == 'local';
  }

  String _normalizedLookupPart(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.replaceAll(
      RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
      '',
    );
  }

  CounterModel? _findCounterForRecord(ActivityRecordModel record) {
    final counterId = record.counterId;
    if (counterId != null) {
      for (final counter in _counters) {
        if (counter.id == counterId) {
          return counter;
        }
      }
    }

    final normalizedGroup = _normalizedLookupPart(record.groupName);
    final normalizedMember = _normalizedLookupPart(record.subjectName);
    for (final counter in _counters) {
      if (_normalizedLookupPart(counter.groupName) == normalizedGroup &&
          _normalizedLookupPart(counter.name) == normalizedMember) {
        return counter;
      }
    }
    return null;
  }

  CounterModel? _findCounterForRecordIn(
    List<CounterModel> counters,
    ActivityRecordModel record,
  ) {
    final counterId = record.counterId;
    if (counterId != null) {
      for (final counter in counters) {
        if (counter.id == counterId) {
          return counter;
        }
      }
    }

    final normalizedGroup = _normalizedLookupPart(record.groupName);
    final normalizedMember = _normalizedLookupPart(record.subjectName);
    for (final counter in counters) {
      if (_normalizedLookupPart(counter.groupName) == normalizedGroup &&
          _normalizedLookupPart(counter.name) == normalizedMember) {
        return counter;
      }
    }
    return null;
  }

  CounterModel? _findCounterForParticipantIn(
    List<CounterModel> counters,
    ActivityParticipant participant,
  ) {
    final normalizedGroup = _normalizedLookupPart(participant.groupName);
    final normalizedMember = _normalizedLookupPart(participant.memberName);

    for (final counter in counters) {
      if (_normalizedLookupPart(counter.groupName) == normalizedGroup &&
          _normalizedLookupPart(counter.name) == normalizedMember) {
        return counter;
      }
    }
    return null;
  }

  Map<CounterCountField, int> _counterDeltasFromRecord(
    ActivityRecordModel record,
  ) {
    return {
      for (final field in CounterCountField.values)
        if (record.countForField(field) != 0)
          field: record.countForField(field),
    };
  }

  ActivityRecordDraft _draftFromRecord(ActivityRecordModel record) {
    if (record.isCounter) {
      return ActivityRecordDraft(
        type: ActivityRecordType.counter,
        counter: _findCounterForRecord(record) ??
            CounterModel(
              id: record.counterId,
              name: record.subjectName,
              groupName: record.groupName,
              personId: record.personId,
              personName: record.personName,
              color: '#FFE135',
            ),
        occurredAt: record.occurredAt,
        note: record.note,
        counterDeltas: _counterDeltasFromRecord(record),
      );
    }

    if (record.isMulti) {
      final multiField = record.multiCountField;
      return ActivityRecordDraft(
        type: ActivityRecordType.multi,
        occurredAt: record.occurredAt,
        note: record.note,
        multiParticipants: record.effectiveParticipants,
        multiField: multiField == CounterCountField.groupCut
            ? CounterCountField.threeInch
            : (multiField ?? CounterCountField.threeInch),
        multiAsGroupCut: multiField == CounterCountField.groupCut,
        multiQuantity: record.effectiveMultiQuantity,
        multiTotalPrice: record.totalAmount,
      );
    }

    return ActivityRecordDraft(
      type: ActivityRecordType.ticket,
      occurredAt: record.occurredAt,
      note: record.note,
      eventName: record.subjectName,
      sessionLabel: record.sessionLabel,
      ticketQuantity: record.ticketQuantity > 0 ? record.ticketQuantity : 1,
      ticketUnitPrice: record.ticketUnitPrice,
    );
  }

  GroupPricingModel? _resolvePricingByGroupName(String groupName) {
    final normalizedGroup = groupName.trim();
    if (normalizedGroup.isEmpty) {
      return null;
    }

    for (final pricing in _pricings) {
      if (pricing.groupName.trim() == normalizedGroup) {
        return pricing;
      }
    }
    return GroupPricingModel.unconfigured(normalizedGroup);
  }

  Future<ActivityRecordModel?> _buildRecordFromDraft(
    ActivityRecordDraft draft, {
    int? id,
    String source = 'local',
    String? sourceRecordId,
  }) async {
    if (draft.type == ActivityRecordType.counter) {
      final counter = draft.counter;
      if (counter == null) {
        return null;
      }
      final pricing = _resolvePricingByGroupName(counter.groupName) ??
          GroupPricingModel.unconfigured(counter.groupName);
      return ActivityRecordModel.counterAdjustment(
        id: id,
        counter: counter,
        occurredAt: draft.occurredAt,
        deltas: draft.counterDeltas,
        pricing: pricing,
        note: draft.note,
      ).copyWith(
        source: source,
        sourceRecordId: sourceRecordId,
      );
    }

    if (draft.type == ActivityRecordType.multi) {
      final isGroupCut = draft.multiAsGroupCut;
      final participantGroups = draft.multiParticipants
          .map((participant) => participant.groupName.trim())
          .where((groupName) => groupName.isNotEmpty)
          .toSet();
      final pricing = participantGroups.length == 1
          ? _resolvePricingByGroupName(participantGroups.first)
          : null;
      final pricingLabel = pricing == null
          ? (participantGroups.length > 1
              ? (isGroupCut ? '跨团团切' : '跨团多人切')
              : (isGroupCut ? '团切' : '多人切'))
          : pricing.label;
      return ActivityRecordModel.multiCut(
        id: id,
        participants: draft.multiParticipants,
        field: isGroupCut
            ? CounterCountField.groupCut
            : (draft.multiField ?? CounterCountField.threeInch),
        occurredAt: draft.occurredAt,
        note: draft.note,
        pricingLabel: pricingLabel,
        quantity: isGroupCut ? 1 : draft.multiQuantity,
        totalPrice: draft.multiTotalPrice,
      ).copyWith(
        source: source,
        sourceRecordId: sourceRecordId,
      );
    }

    return ActivityRecordModel.ticket(
      id: id,
      eventName: draft.eventName,
      occurredAt: draft.occurredAt,
      sessionLabel: draft.sessionLabel,
      note: draft.note,
      quantity: draft.ticketQuantity,
      unitPrice: draft.ticketUnitPrice,
    ).copyWith(
      source: source,
      sourceRecordId: sourceRecordId,
    );
  }

  Future<void> _applyRecordCounterImpact(
    ActivityRecordModel record, {
    required bool reverse,
  }) async {
    final counters = await DatabaseService.getCounters();
    var insertedNewCounter = false;
    final multiplier = reverse ? -1 : 1;

    if (record.isCounter) {
      final existingCounter = _findCounterForRecordIn(counters, record);
      if (existingCounter == null && reverse) {
        return;
      }

      final baseCounter = existingCounter ??
          CounterModel(
            name: record.subjectName,
            groupName: record.groupName,
            personId: record.personId,
            personName: record.personName,
            color: '#FFE135',
          );
      var updatedCounter = baseCounter;
      for (final field in CounterCountField.values) {
        final delta = record.countForField(field);
        if (delta == 0) {
          continue;
        }
        updatedCounter = updatedCounter.changeCount(field, delta * multiplier);
      }

      if (existingCounter?.id != null) {
        await DatabaseService.updateCounter(
            existingCounter!.id!, updatedCounter);
      } else if (!reverse) {
        await DatabaseService.insertCounter(updatedCounter);
        insertedNewCounter = true;
      }
    } else if (record.isMulti) {
      final field = record.multiCountField;
      if (field == null || record.effectiveMultiQuantity <= 0) {
        return;
      }

      for (final participant in record.effectiveParticipants) {
        final existingCounter =
            _findCounterForParticipantIn(counters, participant);
        if (existingCounter == null && reverse) {
          continue;
        }

        final baseCounter = existingCounter ??
            CounterModel(
              name: participant.memberName,
              groupName: participant.groupName,
              personId: participant.personId,
              personName: participant.personName,
              color: '#FFE135',
            );
        final updatedCounter = baseCounter.changeCount(
          field,
          record.effectiveMultiQuantity * multiplier,
        );

        if (existingCounter?.id != null) {
          await DatabaseService.updateCounter(
            existingCounter!.id!,
            updatedCounter,
          );
        } else if (!reverse) {
          await DatabaseService.insertCounter(updatedCounter);
          insertedNewCounter = true;
        }
      }
    }

    if (insertedNewCounter) {
      await DatabaseService.autoAssignCounterThemeColors();
    }
  }

  Future<void> _editRecord(ActivityRecordModel record) async {
    if (!_canMutateRecord(record)) {
      return;
    }

    final draft = await showDialog<ActivityRecordDraft>(
      context: context,
      builder: (context) => AddActivityRecordDialog(
        counters: _counters,
        pricings: _pricings,
        initialDraft: _draftFromRecord(record),
        title: '编辑记录',
        submitLabel: '保存修改',
      ),
    );
    if (draft == null || record.id == null) {
      return;
    }

    final updatedRecord = await _buildRecordFromDraft(
      draft,
      id: record.id,
      source: record.source,
      sourceRecordId: record.sourceRecordId,
    );
    if (updatedRecord == null) {
      return;
    }

    try {
      await _applyRecordCounterImpact(record, reverse: true);
      try {
        await DatabaseService.updateActivityRecord(record.id!, updatedRecord);
        await _applyRecordCounterImpact(updatedRecord, reverse: false);
      } catch (_) {
        await _applyRecordCounterImpact(record, reverse: false);
        rethrow;
      }
      await _loadData();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('记录已更新')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新记录失败：$error')),
      );
    }
  }

  Future<void> _deleteRecordInternal(ActivityRecordModel record) async {
    if (!_canMutateRecord(record) || record.id == null) {
      return;
    }

    await _applyRecordCounterImpact(record, reverse: true);
    try {
      await DatabaseService.deleteActivityRecord(record.id!);
    } catch (_) {
      await _applyRecordCounterImpact(record, reverse: false);
      rethrow;
    }
  }

  Future<void> _deleteRecord(ActivityRecordModel record) async {
    if (!_canMutateRecord(record)) {
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除记录'),
            content: Text(
              '确定删除「${_recordTitle(record)}」这条记录吗？关联数量也会一起回滚。',
            ),
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
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    try {
      await _deleteRecordInternal(record);
      await _loadData();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('记录已删除')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除记录失败：$error')),
      );
    }
  }

  Future<void> _deleteSelectedRecords() async {
    final selectedRecords = _records
        .where((record) => _selectedRecordIds.contains(record.id))
        .toList();
    if (selectedRecords.isEmpty) {
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('批量删除记录'),
            content: Text(
              '确定删除选中的 ${selectedRecords.length} 条记录吗？关联数量也会一起回滚。',
            ),
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
        ) ??
        false;
    if (!confirmed) {
      return;
    }

    var deletedCount = 0;
    Object? failure;
    for (final record in selectedRecords) {
      try {
        await _deleteRecordInternal(record);
        deletedCount += 1;
      } catch (error) {
        failure = error;
        break;
      }
    }

    await _loadData();
    if (!mounted) {
      return;
    }

    setState(() {
      _selectionMode = false;
      _selectedRecordIds.clear();
    });

    if (failure == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 $deletedCount 条记录')),
      );
      return;
    }

    final message = deletedCount > 0
        ? '已删除 $deletedCount 条记录，剩余删除失败：$failure'
        : '批量删除失败：$failure';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  bool _shouldUseCurrentPricingForRecord(ActivityRecordModel record) {
    if (!record.isCounter || record.counterCountTotal <= 0) {
      return false;
    }

    if (record.totalAmount != 0) {
      return false;
    }

    for (final field in CounterCountField.values) {
      if (record.priceForField(field) != 0) {
        return false;
      }
    }

    return true;
  }

  double _calculateCounterAmountWithPricing(
    ActivityRecordModel record,
    GroupPricingModel pricing,
  ) {
    return CounterCountField.values.fold<double>(0, (sum, field) {
      return sum + (record.countForField(field) * pricing.priceForField(field));
    });
  }

  double _effectiveTotalAmount(ActivityRecordModel record) {
    if (!_shouldUseCurrentPricingForRecord(record)) {
      if (record.isTicket &&
          record.totalAmount == 0 &&
          record.ticketQuantity > 0 &&
          record.ticketUnitPrice > 0) {
        return record.ticketQuantity * record.ticketUnitPrice;
      }
      return record.totalAmount;
    }

    final pricing = _resolvePricingByGroupName(record.groupName);
    if (pricing == null) {
      return record.totalAmount;
    }
    return _calculateCounterAmountWithPricing(record, pricing);
  }

  String _effectivePricingLabel(ActivityRecordModel record) {
    if (!_shouldUseCurrentPricingForRecord(record)) {
      return record.pricingLabel;
    }

    final pricing = _resolvePricingByGroupName(record.groupName);
    if (pricing == null) {
      return record.pricingLabel;
    }

    final label = pricing.label.trim();
    if (label.isEmpty) {
      return '当前团价';
    }
    return '$label（当前团价）';
  }

  String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }

  String _formatDateTime(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${_formatDate(value)} ${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  String _formatOccurredAtLabel(DateTime value) {
    if (value.hour == 0 && value.minute == 0) {
      return _formatDate(value);
    }
    return _formatDateTime(value);
  }

  String _formatAmount(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }

  String _recordTitle(ActivityRecordModel record) {
    if (record.isMulti) {
      return record.multiDisplayName;
    }
    return record.subjectName;
  }

  String _recordSubtitle(ActivityRecordModel record) {
    final multiGroupLabel = record.effectiveParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet()
        .join(' / ');

    if (record.isTicket) {
      return [
        _formatOccurredAtLabel(record.occurredAt),
        if (record.sessionLabel.isNotEmpty) record.sessionLabel,
        '门票 ${record.ticketQuantity} 张',
        if (record.note.isNotEmpty) record.note,
      ].join(' · ');
    }

    if (record.isMulti) {
      return [
        _formatOccurredAtLabel(record.occurredAt),
        if (multiGroupLabel.isNotEmpty) multiGroupLabel,
        _effectivePricingLabel(record),
        if (record.multiFieldLabel.isNotEmpty) record.multiFieldLabel,
        '多人切 ${record.multiParticipantCount} 人',
        if (record.effectiveMultiQuantity > 1)
          '每人 ${record.effectiveMultiQuantity}',
        if (record.note.isNotEmpty) record.note,
      ].join(' · ');
    }

    return [
      _formatOccurredAtLabel(record.occurredAt),
      if (record.groupName.isNotEmpty) record.groupName,
      _effectivePricingLabel(record),
      CounterCountField.values
          .where((field) => record.countForField(field) != 0)
          .map((field) => '${field.shortLabel} ${record.countForField(field)}')
          .join(' / '),
      if (record.note.isNotEmpty) record.note,
    ].join(' · ');
  }

  IconData _recordIcon(ActivityRecordModel record) {
    if (record.isTicket) {
      return Icons.confirmation_num_outlined;
    }
    if (record.isMulti) {
      return Icons.people_alt_outlined;
    }
    return Icons.photo_library_outlined;
  }

  void _enterSelectionMode([ActivityRecordModel? record]) {
    setState(() {
      _selectionMode = true;
      if (record?.id != null) {
        _selectedRecordIds.add(record!.id!);
      }
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedRecordIds.clear();
    });
  }

  void _toggleRecordSelection(ActivityRecordModel record) {
    final id = record.id;
    if (id == null) {
      return;
    }

    setState(() {
      if (_selectedRecordIds.contains(id)) {
        _selectedRecordIds.remove(id);
      } else {
        _selectedRecordIds.add(id);
      }
      if (_selectedRecordIds.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  void _toggleSelectAll() {
    final allIds = _records.map((record) => record.id).whereType<int>().toSet();
    setState(() {
      if (_selectedRecordIds.length == allIds.length) {
        _selectedRecordIds.clear();
      } else {
        _selectedRecordIds
          ..clear()
          ..addAll(allIds);
      }
    });
  }

  Future<void> _handleRecordTap(ActivityRecordModel record) async {
    if (_selectionMode) {
      _toggleRecordSelection(record);
      return;
    }
    await _editRecord(record);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recordCount = _records.length;
    final allSelected =
        recordCount > 0 && _selectedRecordIds.length == recordCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionMode ? '已选择 ${_selectedRecordIds.length} 条' : '最近提交记录',
        ),
        actions: _selectionMode
            ? [
                IconButton(
                  onPressed: recordCount == 0 ? null : _toggleSelectAll,
                  tooltip: allSelected ? '取消全选' : '全选',
                  icon: Icon(
                    allSelected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                  ),
                ),
                IconButton(
                  onPressed: _selectedRecordIds.isEmpty
                      ? null
                      : _deleteSelectedRecords,
                  tooltip: '删除所选',
                  icon: const Icon(Icons.delete_outline),
                ),
                IconButton(
                  onPressed: _exitSelectionMode,
                  tooltip: '退出多选',
                  icon: const Icon(Icons.close),
                ),
              ]
            : [
                IconButton(
                  onPressed: recordCount == 0 ? null : _enterSelectionMode,
                  tooltip: '批量选择',
                  icon: const Icon(Icons.checklist_rounded),
                ),
                IconButton(
                  onPressed: _loadData,
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                ),
              ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '最近提交记录',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _selectionMode
                              ? '已进入多选模式，可以勾选多条记录后一起删除。'
                              : '这里只显示本地提交的记录，按时间倒序排列；点一条可直接编辑，长按可进入多选删除。',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _RecentInfoChip(
                              label: '本地记录',
                              value: '$recordCount',
                            ),
                            _RecentInfoChip(
                              label: '已选中',
                              value: '${_selectedRecordIds.length}',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_records.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        color: theme.colorScheme.surface,
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.history_toggle_off_rounded,
                            size: 40,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '还没有本地提交记录',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '从首页新增的本地记录会出现在这里，后续可以直接编辑或批量删除。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    )
                  else
                    ..._records.map((record) {
                      final selected = record.id != null &&
                          _selectedRecordIds.contains(record.id);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: theme.colorScheme.surface,
                          borderRadius: BorderRadius.circular(18),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(18),
                            onTap: () => _handleRecordTap(record),
                            onLongPress: () => _enterSelectionMode(record),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: _selectionMode
                                        ? Checkbox(
                                            value: selected,
                                            onChanged: (_) =>
                                                _toggleRecordSelection(record),
                                          )
                                        : Icon(_recordIcon(record)),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _recordTitle(record),
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _recordSubtitle(record),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        '¥${_formatAmount(_effectiveTotalAmount(record))}',
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (!_selectionMode)
                                        PopupMenuButton<_RecentRecordAction>(
                                          tooltip: '记录操作',
                                          onSelected: (action) async {
                                            switch (action) {
                                              case _RecentRecordAction.edit:
                                                await _editRecord(record);
                                                break;
                                              case _RecentRecordAction.delete:
                                                await _deleteRecord(record);
                                                break;
                                            }
                                          },
                                          itemBuilder: (context) => const [
                                            PopupMenuItem(
                                              value: _RecentRecordAction.edit,
                                              child: Text('编辑'),
                                            ),
                                            PopupMenuItem(
                                              value: _RecentRecordAction.delete,
                                              child: Text('删除'),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}

enum _RecentRecordAction {
  edit,
  delete,
}

class _RecentInfoChip extends StatelessWidget {
  final String label;
  final String value;

  const _RecentInfoChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: theme.colorScheme.surface,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
