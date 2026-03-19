import 'package:flutter/material.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../widgets/add_activity_record_dialog.dart';
import '../widgets/counter_count_sheet.dart';
import 'record_memory_page.dart';

class MemberDetailPage extends StatefulWidget {
  final CounterModel displayCounter;
  final CounterModel primaryCounter;
  final List<CounterModel> sourceCounters;
  final Future<CounterModel> Function(
    CounterModel updatedCounter,
    DateTime occurredAt,
  ) onCounterChanged;

  const MemberDetailPage({
    super.key,
    required this.displayCounter,
    required this.primaryCounter,
    required this.sourceCounters,
    required this.onCounterChanged,
  });

  @override
  State<MemberDetailPage> createState() => _MemberDetailPageState();
}

class _MemberDetailPageState extends State<MemberDetailPage> {
  List<CounterModel> _allCounters = [];
  List<CounterModel> _matchedCounters = [];
  List<ActivityRecordModel> _records = [];
  List<GroupPricingModel> _pricings = [];
  Map<int, int> _recordMediaCounts = const <int, int>{};
  bool _loading = true;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _loadData();
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

  Set<int> get _sourcePersonIds {
    return widget.sourceCounters
        .map((counter) => counter.personId)
        .whereType<int>()
        .toSet();
  }

  Set<String> get _sourcePersonNames {
    return widget.sourceCounters
        .map((counter) => _normalizedLookupPart(counter.personName))
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  Set<String> get _fallbackCounterKeys {
    return widget.sourceCounters
        .map(
          (counter) =>
              '${_normalizedLookupPart(counter.groupName)}|${_normalizedLookupPart(counter.name)}',
        )
        .where((key) => key != '|')
        .toSet();
  }

  bool _matchesCounter(CounterModel counter) {
    if (_sourcePersonNames
        .contains(_normalizedLookupPart(counter.personName))) {
      return true;
    }
    if (counter.personId != null &&
        _sourcePersonIds.contains(counter.personId)) {
      return true;
    }
    final fallbackKey =
        '${_normalizedLookupPart(counter.groupName)}|${_normalizedLookupPart(counter.name)}';
    return _fallbackCounterKeys.contains(fallbackKey);
  }

  bool _matchesParticipant(ActivityParticipant participant) {
    if (_sourcePersonNames.contains(
      _normalizedLookupPart(participant.personName),
    )) {
      return true;
    }
    if (participant.personId != null &&
        _sourcePersonIds.contains(participant.personId)) {
      return true;
    }
    final fallbackKey =
        '${_normalizedLookupPart(participant.groupName)}|${_normalizedLookupPart(participant.memberName)}';
    return _fallbackCounterKeys.contains(fallbackKey);
  }

  bool _matchesCounterRecord(
    ActivityRecordModel record,
    Set<int> matchedCounterIds,
  ) {
    if (record.counterId != null &&
        matchedCounterIds.contains(record.counterId)) {
      return true;
    }
    if (_sourcePersonNames.contains(_normalizedLookupPart(record.personName))) {
      return true;
    }
    if (record.personId != null && _sourcePersonIds.contains(record.personId)) {
      return true;
    }
    final fallbackKey =
        '${_normalizedLookupPart(record.groupName)}|${_normalizedLookupPart(record.subjectName)}';
    return _fallbackCounterKeys.contains(fallbackKey);
  }

  Future<void> _loadData() async {
    final counters = await DatabaseService.getCounters();
    final pricings = await DatabaseService.getGroupPricings();
    final matchedCounters = counters.where(_matchesCounter).toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final matchedCounterIds =
        matchedCounters.map((counter) => counter.id).whereType<int>().toSet();

    final allRecords = await DatabaseService.getActivityRecords();
    final relatedRecords = allRecords.where((record) {
      if (record.isTicket) {
        return false;
      }
      if (record.isCounter) {
        return _matchesCounterRecord(record, matchedCounterIds);
      }
      return record.effectiveParticipants.any(_matchesParticipant);
    }).toList()
      ..sort((a, b) {
        final timeCompare = b.occurredAt.compareTo(a.occurredAt);
        if (timeCompare != 0) {
          return timeCompare;
        }
        return (b.id ?? 0).compareTo(a.id ?? 0);
      });

    final recordIds =
        relatedRecords.map((record) => record.id).whereType<int>().toList();
    final media = recordIds.isEmpty
        ? const []
        : await DatabaseService.getActivityRecordMedia(recordIds: recordIds);
    final recordMediaCounts = <int, int>{};
    for (final item in media) {
      recordMediaCounts[item.recordId] =
          (recordMediaCounts[item.recordId] ?? 0) + 1;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _allCounters = counters;
      _matchedCounters = matchedCounters.isEmpty
          ? List<CounterModel>.from(widget.sourceCounters)
          : matchedCounters;
      _records = relatedRecords;
      _pricings = pricings;
      _recordMediaCounts = recordMediaCounts;
      _loading = false;
    });
  }

  String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }

  String _groupLabel() {
    final groups = _matchedCounters
        .map((counter) => counter.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (groups.isEmpty) {
      return '未分组';
    }
    if (groups.length <= 2) {
      return groups.join(' / ');
    }
    return '${groups[0]} / ${groups[1]} 等${groups.length}团';
  }

  List<CounterModel> get _effectiveCounters {
    if (_matchedCounters.isNotEmpty) {
      return _matchedCounters;
    }
    return widget.sourceCounters;
  }

  int get _currentTotalCount {
    final builtInCount = _effectiveCounters.fold<int>(
      0,
      (sum, counter) => sum + counter.count,
    );
    final customCount = _records.fold<int>(0, (sum, record) {
      return sum + record.customChekiCountTotal;
    });
    return builtInCount + customCount;
  }

  CounterModel get _sheetCounter {
    if (_matchedCounters.isNotEmpty) {
      return _matchedCounters.first;
    }
    return widget.primaryCounter;
  }

  Future<void> _openQuickCount() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => CounterCountSheet(
        counter: _sheetCounter,
        allCounters: _allCounters,
        onCounterChanged: (updatedCounter, occurredAt) async {
          final saved =
              await widget.onCounterChanged(updatedCounter, occurredAt);
          _dirty = true;
          return saved;
        },
      ),
    );
    await _loadData();
  }

  String _recordTitle(ActivityRecordModel record) {
    final activityName = record.resolvedActivityName;
    if (activityName.isNotEmpty) {
      return activityName;
    }
    if (record.isMulti) {
      return record.multiDisplayName;
    }
    return record.subjectName;
  }

  IconData _recordIcon(ActivityRecordModel record) {
    if (record.isMulti) {
      return Icons.groups_2_outlined;
    }
    return Icons.photo_library_outlined;
  }

  List<_RecordDayGroup> get _dayGroups {
    final grouped = <DateTime, List<ActivityRecordModel>>{};
    for (final record in _records) {
      final day = DateTime(
        record.occurredAt.year,
        record.occurredAt.month,
        record.occurredAt.day,
      );
      grouped.putIfAbsent(day, () => <ActivityRecordModel>[]).add(record);
    }

    final groups = grouped.entries.map((entry) {
      final mediaCount = entry.value.fold<int>(0, (sum, record) {
        final recordId = record.id;
        if (recordId == null) {
          return sum;
        }
        return sum + (_recordMediaCounts[recordId] ?? 0);
      });
      return _RecordDayGroup(
        day: entry.key,
        records: entry.value,
        mediaCount: mediaCount,
      );
    }).toList()
      ..sort((a, b) => b.day.compareTo(a.day));

    return groups;
  }

  String _recordDaySummary(ActivityRecordModel record) {
    final parts = <String>[];
    if (record.occurredAt.hour != 0 || record.occurredAt.minute != 0) {
      final hour = record.occurredAt.hour.toString().padLeft(2, '0');
      final minute = record.occurredAt.minute.toString().padLeft(2, '0');
      parts.add('$hour:$minute');
    }
    if (record.resolvedVenueName.isNotEmpty) {
      parts.add(record.resolvedVenueName);
    }
    if (record.isMulti) {
      final label =
          record.multiFieldLabel.isEmpty ? '多人切' : record.multiFieldLabel;
      parts.add(label);
    } else if (record.counterSpecSummaryLabel.isNotEmpty) {
      parts.add(record.counterSpecSummaryLabel);
    }
    if (record.note.trim().isNotEmpty) {
      parts.add(record.note.trim());
    }
    return parts.join(' · ');
  }

  bool _canMutateRecord(ActivityRecordModel record) {
    return record.id != null;
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

  CounterModel? _findCounterForRecord(ActivityRecordModel record) {
    return _findCounterForRecordIn(_allCounters, record);
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
        activityName: record.resolvedActivityName,
        venueName: record.resolvedVenueName,
        note: record.note,
        counterDeltas: _counterDeltasFromRecord(record),
        customChekiCounts: record.customChekiCounts,
      );
    }

    if (record.isMulti) {
      final multiField = record.multiCountField;
      return ActivityRecordDraft(
        type: ActivityRecordType.multi,
        occurredAt: record.occurredAt,
        activityName: record.resolvedActivityName,
        venueName: record.resolvedVenueName,
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
      activityName: record.resolvedActivityName,
      venueName: record.resolvedVenueName,
      note: record.note,
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
        activityName: draft.activityName,
        venueName: draft.venueName,
        note: draft.note,
        customChekiCounts: draft.customChekiCounts,
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
        activityName: draft.activityName,
        venueName: draft.venueName,
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
      eventName: draft.activityName,
      occurredAt: draft.occurredAt,
      venueName: draft.venueName,
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
        counters: _allCounters,
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
      _dirty = true;
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

  Future<void> _deleteRecord(ActivityRecordModel record) async {
    if (!_canMutateRecord(record) || record.id == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除记录'),
            content: Text('确定删除这条记录吗？关联数量也会一起回滚。'),
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
      await _applyRecordCounterImpact(record, reverse: true);
      try {
        await DatabaseService.deleteActivityRecord(record.id!);
      } catch (_) {
        await _applyRecordCounterImpact(record, reverse: false);
        rethrow;
      }
      _dirty = true;
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

  Future<void> _openMemoryPage(_RecordDayGroup dayGroup) async {
    if (dayGroup.records.every((record) => record.id == null)) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RecordMemoryPage.group(
          records: dayGroup.records,
          albumTitle: widget.displayCounter.name,
          albumDate: dayGroup.day,
        ),
      ),
    );
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayCounter = _matchedCounters.isNotEmpty
        ? _matchedCounters.first.copyWith(
            name: widget.displayCounter.name,
            groupName: _groupLabel(),
          )
        : widget.displayCounter;

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          return;
        }
        Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.of(context).pop(_dirty),
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(widget.displayCounter.name),
          actions: [
            IconButton(
              onPressed: _loading ? null : _openQuickCount,
              icon: const Icon(Icons.addchart_outlined),
              tooltip: '快捷计数',
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _loading ? null : _openQuickCount,
          icon: const Icon(Icons.edit_note_outlined),
          label: const Text('快捷计数'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _loadData,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayCounter.name,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _groupLabel(),
                            style: theme.textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              _DetailMetric(
                                label: '总计',
                                value: '$_currentTotalCount',
                              ),
                              _DetailMetric(
                                label: '记录数',
                                value: '${_records.length}',
                              ),
                              _DetailMetric(
                                label: '存图数',
                                value:
                                    '${_recordMediaCounts.values.fold<int>(0, (sum, value) => sum + value)}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_records.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: const Text(
                          '这张卡片目前还没有可展示的见面流水。先记一次切，后面这里就会按时间积累下来。',
                        ),
                      )
                    else
                      ..._dayGroups.map((dayGroup) {
                        final activityLabels = dayGroup.records
                            .map(_recordTitle)
                            .where((item) => item.trim().isNotEmpty)
                            .toSet()
                            .toList()
                          ..sort();

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.event_note_outlined),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _formatDate(dayGroup.day),
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 6,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: theme.colorScheme
                                                      .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    999,
                                                  ),
                                                ),
                                                child: Text(
                                                  '${dayGroup.records.length} 条记录',
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 6,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: theme.colorScheme
                                                      .surfaceContainerHighest,
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    999,
                                                  ),
                                                ),
                                                child: Text(
                                                  dayGroup.mediaCount > 0
                                                      ? '存图 ${dayGroup.mediaCount}'
                                                      : '还没存图',
                                                ),
                                              ),
                                              ...activityLabels.take(2).map(
                                                    (item) => Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 10,
                                                        vertical: 6,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: theme.colorScheme
                                                            .surfaceContainerHighest,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                          999,
                                                        ),
                                                      ),
                                                      child: Text(item),
                                                    ),
                                                  ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ...dayGroup.records.map((record) {
                                  final summary = _recordDaySummary(record);
                                  final canMutate = _canMutateRecord(record);
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Material(
                                      color: theme
                                          .colorScheme.surfaceContainerLowest,
                                      borderRadius: BorderRadius.circular(16),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(16),
                                        onTap: canMutate
                                            ? () => _editRecord(record)
                                            : null,
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Icon(
                                                _recordIcon(record),
                                                size: 18,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      _recordTitle(record),
                                                      style: theme
                                                          .textTheme.bodyLarge
                                                          ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                    if (summary.isNotEmpty) ...[
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        summary,
                                                        style: theme.textTheme
                                                            .bodySmall,
                                                      ),
                                                    ],
                                                  ],
                                                ),
                                              ),
                                              if (canMutate) ...[
                                                const SizedBox(width: 8),
                                                PopupMenuButton<
                                                    _RecordCardAction>(
                                                  tooltip: '记录操作',
                                                  onSelected: (action) async {
                                                    switch (action) {
                                                      case _RecordCardAction
                                                            .edit:
                                                        await _editRecord(
                                                          record,
                                                        );
                                                        break;
                                                      case _RecordCardAction
                                                            .delete:
                                                        await _deleteRecord(
                                                          record,
                                                        );
                                                        break;
                                                    }
                                                  },
                                                  itemBuilder: (context) =>
                                                      const [
                                                    PopupMenuItem(
                                                      value: _RecordCardAction
                                                          .edit,
                                                      child: Text('编辑'),
                                                    ),
                                                    PopupMenuItem(
                                                      value: _RecordCardAction
                                                          .delete,
                                                      child: Text('删除'),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _openMemoryPage(dayGroup),
                                    icon: const Icon(
                                        Icons.photo_library_outlined),
                                    label: Text(
                                      dayGroup.mediaCount > 0
                                          ? '查看当日存图 ${dayGroup.mediaCount}'
                                          : '新增当日存图',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }
}

enum _RecordCardAction {
  edit,
  delete,
}

class _DetailMetric extends StatelessWidget {
  final String label;
  final String value;

  const _DetailMetric({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
        ],
      ),
    );
  }
}

class _RecordDayGroup {
  final DateTime day;
  final List<ActivityRecordModel> records;
  final int mediaCount;

  const _RecordDayGroup({
    required this.day,
    required this.records,
    required this.mediaCount,
  });
}
