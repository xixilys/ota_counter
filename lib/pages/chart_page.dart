import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../models/chart_stats_helpers.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../widgets/add_activity_record_dialog.dart';
import 'group_pricing_page.dart';

class ChartPage extends StatefulWidget {
  final bool openComposerOnStart;

  const ChartPage({
    super.key,
    this.openComposerOnStart = false,
  });

  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  List<CounterModel> _counters = [];
  List<ActivityRecordModel> _records = [];
  List<ActivityRecordMediaModel> _recordMedia = [];
  List<GroupPricingModel> _pricings = [];
  bool _loading = true;
  bool _initialComposerHandled = false;
  StatsScope _scope = StatsScope.day;
  MemberStatsMode _memberStatsMode = MemberStatsMode.group;
  DateTime _anchor = DateTime.now();

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
    final recordIds =
        records.map((record) => record.id).whereType<int>().toList();
    final media = recordIds.isEmpty
        ? const <ActivityRecordMediaModel>[]
        : await DatabaseService.getActivityRecordMedia(recordIds: recordIds);
    final pricings = await DatabaseService.getGroupPricings();

    if (!mounted) {
      return;
    }

    setState(() {
      _counters = counters;
      _records = records;
      _recordMedia = media;
      _pricings = pricings;
      _loading = false;
    });

    _openInitialComposerIfNeeded();
  }

  void _openInitialComposerIfNeeded() {
    if (!widget.openComposerOnStart || _initialComposerHandled || !mounted) {
      return;
    }

    _initialComposerHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _openAddRecordDialog();
    });
  }

  DateTimeRange? get _activeRange => _scope.rangeFor(_anchor);

  List<ActivityRecordModel> get _filteredRecords {
    final range = _activeRange;
    if (range == null) {
      return _records;
    }

    return _records.where((record) {
      return !record.occurredAt.isBefore(range.start) &&
          record.occurredAt.isBefore(range.end);
    }).toList();
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

  bool get _showCalendar {
    return _scope == StatsScope.day;
  }

  DateTime get _calendarMonth {
    return DateTime(_anchor.year, _anchor.month);
  }

  DateTime get _selectedCalendarDate {
    return DateTime(_anchor.year, _anchor.month, _anchor.day);
  }

  Map<DateTime, _CalendarDaySummary> get _calendarMonthSummaries {
    if (!_showCalendar) {
      return const <DateTime, _CalendarDaySummary>{};
    }
    return _buildCalendarDaySummariesForMonth(_calendarMonth);
  }

  _CalendarDaySummary? get _selectedCalendarSummary {
    return _calendarMonthSummaries[_selectedCalendarDate];
  }

  Map<DateTime, _CalendarDaySummary> _buildCalendarDaySummariesForMonth(
    DateTime month,
  ) {
    final monthStart = DateTime(month.year, month.month);
    final monthEnd = month.month == 12
        ? DateTime(month.year + 1, 1)
        : DateTime(month.year, month.month + 1);
    final summaries = <DateTime, _CalendarDaySummaryBuilder>{};
    final recordsById = <int, ActivityRecordModel>{};

    for (final record in _records) {
      final occurredDay = DateTime(
        record.occurredAt.year,
        record.occurredAt.month,
        record.occurredAt.day,
      );
      if (occurredDay.isBefore(monthStart) || !occurredDay.isBefore(monthEnd)) {
        continue;
      }

      final summary = summaries.putIfAbsent(
        occurredDay,
        () => _CalendarDaySummaryBuilder(date: occurredDay),
      );
      summary.recordCount += 1;
      summary.amount += _effectiveTotalAmount(record);
      final activityKey = _activitySummaryKey(record);
      if (summary.activityKeys.add(activityKey)) {
        summary.activityLabels.add(_activitySummaryLabel(record));
      }
      if (record.isTicket) {
        summary.ticketCount += record.ticketQuantity;
      } else if (record.isMulti) {
        summary.cutCount += record.multiContributionTotal;
      } else {
        summary.cutCount += record.counterCountTotal;
      }

      if (record.id != null) {
        recordsById[record.id!] = record;
      }
    }

    for (final media in _recordMedia) {
      if (!media.isScan) {
        continue;
      }
      final record = recordsById[media.recordId];
      if (record == null) {
        continue;
      }
      final occurredDay = DateTime(
        record.occurredAt.year,
        record.occurredAt.month,
        record.occurredAt.day,
      );
      final summary = summaries.putIfAbsent(
        occurredDay,
        () => _CalendarDaySummaryBuilder(date: occurredDay),
      );
      summary.scanCount += 1;
    }

    return {
      for (final entry in summaries.entries) entry.key: entry.value.build(),
    };
  }

  String _activitySummaryKey(ActivityRecordModel record) {
    final baseLabel = record.resolvedActivityName.isNotEmpty
        ? record.resolvedActivityName
        : record.isTicket
            ? record.subjectName.trim()
            : record.isMulti
                ? record.multiDisplayName
                : record.subjectName.trim();
    final parts = <String>[
      if (baseLabel.isNotEmpty) baseLabel,
      if (record.resolvedVenueName.isNotEmpty) record.resolvedVenueName,
      if (record.sessionLabel.trim().isNotEmpty) record.sessionLabel.trim(),
    ];
    return parts.join('|');
  }

  String _activitySummaryLabel(ActivityRecordModel record) {
    final baseLabel = record.resolvedActivityName.isNotEmpty
        ? record.resolvedActivityName
        : record.isTicket
            ? record.subjectName.trim()
            : record.isMulti
                ? record.multiDisplayName
                : record.subjectName.trim();
    final parts = <String>[
      if (baseLabel.isNotEmpty) baseLabel,
      if (record.resolvedVenueName.isNotEmpty) record.resolvedVenueName,
      if (record.sessionLabel.trim().isNotEmpty) record.sessionLabel.trim(),
    ];
    if (parts.isEmpty) {
      return '未命名记录';
    }
    return parts.join(' · ');
  }

  void _handleCalendarDaySelected(DateTime date) {
    setState(() {
      _anchor = date;
    });
  }

  void _changeCalendarMonth(int offset) {
    final current = _selectedCalendarDate;
    final targetMonth = DateTime(current.year, current.month + offset, 1);
    final lastDay = DateTime(targetMonth.year, targetMonth.month + 1, 0).day;

    setState(() {
      _anchor = DateTime(
        targetMonth.year,
        targetMonth.month,
        current.day.clamp(1, lastDay),
      );
    });
  }

  Future<void> _pickCalendarDate() async {
    final selected = await showDatePicker(
      context: context,
      locale: const Locale('zh', 'CN'),
      helpText: '选择日期',
      initialDate: _selectedCalendarDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      _anchor = selected;
    });
  }

  String get _scopeTitle {
    final range = _activeRange;
    if (range == null) {
      return '全部记录';
    }

    switch (_scope) {
      case StatsScope.day:
        return _formatDate(range.start);
      case StatsScope.week:
        final weekEnd = range.end.subtract(const Duration(days: 1));
        return '${_formatDate(range.start)} ~ ${_formatDate(weekEnd)}';
      case StatsScope.month:
        return '${range.start.year}-${range.start.month.toString().padLeft(2, '0')}';
      case StatsScope.year:
        return '${range.start.year} 年';
      case StatsScope.all:
        return '全部记录';
    }
  }

  void _moveScope(int offset) {
    if (_scope == StatsScope.all) {
      return;
    }

    setState(() {
      _anchor = _scope.shift(_anchor, offset);
    });
  }

  bool get _canMoveForward {
    if (_scope == StatsScope.all) {
      return false;
    }
    final nextRange = _scope.rangeFor(_scope.shift(_anchor, 1));
    if (nextRange == null) {
      return false;
    }
    final today = DateTime.now();
    return !nextRange.start.isAfter(
      DateTime(today.year, today.month, today.day),
    );
  }

  Future<void> _pickScopeAnchor() async {
    if (_scope == StatsScope.all) {
      return;
    }

    switch (_scope) {
      case StatsScope.day:
        return;
      case StatsScope.week:
        final selected = await showDatePicker(
          context: context,
          locale: const Locale('zh', 'CN'),
          helpText: '选择一周中的任意日期',
          initialDate: _anchor,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (selected == null || !mounted) {
          return;
        }
        setState(() {
          _anchor = _scope == StatsScope.week
              ? StatsScope.week.rangeFor(selected)!.start
              : selected;
        });
        return;
      case StatsScope.month:
        final selected = await showDatePicker(
          context: context,
          locale: const Locale('zh', 'CN'),
          helpText: '选择任意一天以切换月份',
          initialDate: _anchor,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (selected == null || !mounted) {
          return;
        }
        setState(() {
          _anchor = DateTime(selected.year, selected.month, 1);
        });
        return;
      case StatsScope.year:
        final selected = await showDatePicker(
          context: context,
          locale: const Locale('zh', 'CN'),
          helpText: '选择任意一天以切换年份',
          initialDate: _anchor,
          firstDate: DateTime(2020),
          lastDate: DateTime(2100),
        );
        if (selected == null || !mounted) {
          return;
        }
        setState(() {
          _anchor = DateTime(selected.year, 1, 1);
        });
        return;
      case StatsScope.all:
        return;
    }
  }

  Future<void> _openPricingPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const GroupPricingPage()),
    );
    await _loadData();
  }

  bool _canMutateRecord(ActivityRecordModel record) {
    return record.id != null;
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

  CounterModel? _findCounterForParticipant(ActivityParticipant participant) {
    final normalizedGroup = _normalizedLookupPart(participant.groupName);
    final normalizedMember = _normalizedLookupPart(participant.memberName);

    for (final counter in _counters) {
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
    var insertedNewCounter = false;
    final multiplier = reverse ? -1 : 1;

    if (record.isCounter) {
      final existingCounter = _findCounterForRecord(record);
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
        final existingCounter = _findCounterForParticipant(participant);
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

  Future<void> _saveNewRecord(ActivityRecordDraft draft) async {
    final record = await _buildRecordFromDraft(draft);
    if (record == null) {
      return;
    }

    try {
      await _applyRecordCounterImpact(record, reverse: false);
      try {
        await DatabaseService.insertActivityRecord(record);
      } catch (_) {
        await _applyRecordCounterImpact(record, reverse: true);
        rethrow;
      }
      await _loadData();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存记录失败：$error')),
      );
    }
  }

  Future<void> _openAddRecordDialog() async {
    final draft = await showDialog<ActivityRecordDraft>(
      context: context,
      builder: (context) => AddActivityRecordDialog(
        counters: _counters,
        pricings: _pricings,
      ),
    );

    if (draft == null) {
      return;
    }
    await _saveNewRecord(draft);
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

  Future<void> _deleteRecord(ActivityRecordModel record) async {
    if (!_canMutateRecord(record) || record.id == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除记录'),
            content: Text(
              '确定删除「${record.isMulti ? record.multiDisplayName : record.subjectName}」这条记录吗？关联数量也会一起回滚。',
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
      await _applyRecordCounterImpact(record, reverse: true);
      try {
        await DatabaseService.deleteActivityRecord(record.id!);
      } catch (_) {
        await _applyRecordCounterImpact(record, reverse: false);
        rethrow;
      }
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

  String _memberStatKey(String groupName, String subjectName) {
    final normalizedGroup = groupName.trim().toLowerCase();
    final normalizedSubject = subjectName.trim().toLowerCase();
    return '$normalizedGroup|$normalizedSubject';
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

  String _personStatKey({
    required int? personId,
    required String personName,
    required String groupName,
    required String subjectName,
  }) {
    final normalizedPerson = _normalizedLookupPart(personName);
    if (normalizedPerson.isNotEmpty) {
      return 'person-name:$normalizedPerson';
    }

    if (personId != null) {
      return 'person:$personId';
    }

    final normalizedGroup = _normalizedLookupPart(groupName);
    final normalizedSubject = _normalizedLookupPart(subjectName);
    return 'fallback:$normalizedGroup|$normalizedSubject';
  }

  bool _shouldUseCurrentPricingForRecord(ActivityRecordModel record) {
    return record.shouldResolveWithCurrentPricing;
  }

  double _calculateCounterAmountWithPricing(
    ActivityRecordModel record,
    GroupPricingModel pricing,
  ) {
    return record.totalAmountWithPricing(pricing);
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

  double _effectiveMultiParticipantAmountShare(ActivityRecordModel record) {
    final participantCount = record.multiParticipantCount;
    if (participantCount <= 0) {
      return 0;
    }
    return _effectiveTotalAmount(record) / participantCount;
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

  Future<void> _previewMedia(ActivityRecordMediaModel media) async {
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Stack(
          children: [
            Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: InteractiveViewer(
                child: Image.file(File(media.path)),
              ),
            ),
            Positioned(
              top: 16,
              left: 16,
              child: FilledButton.tonalIcon(
                onPressed: null,
                icon: Icon(
                  media.isScan
                      ? Icons.document_scanner_outlined
                      : Icons.photo_library_outlined,
                ),
                label: Text(media.isScan ? '切图' : '纪念照'),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filledTonal(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _sameDay(DateTime left, DateTime right) {
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }

  String _recordTitle(ActivityRecordModel record) {
    if (record.isMulti) {
      return record.multiDisplayName;
    }
    return record.subjectName;
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

  String _recordSubtitle(ActivityRecordModel record) {
    final multiGroupLabel = record.effectiveParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet()
        .join(' / ');
    if (record.isTicket) {
      return [
        _formatOccurredAtLabel(record.occurredAt),
        if (record.resolvedVenueName.isNotEmpty) record.resolvedVenueName,
        if (record.sessionLabel.isNotEmpty) record.sessionLabel,
        '门票 ${record.ticketQuantity} 张',
        if (record.note.isNotEmpty) record.note,
      ].join(' · ');
    }

    if (record.isMulti) {
      return [
        _formatOccurredAtLabel(record.occurredAt),
        if (record.resolvedActivityName.isNotEmpty) record.resolvedActivityName,
        if (record.resolvedVenueName.isNotEmpty) record.resolvedVenueName,
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
      if (record.resolvedActivityName.isNotEmpty) record.resolvedActivityName,
      if (record.resolvedVenueName.isNotEmpty) record.resolvedVenueName,
      if (record.groupName.isNotEmpty) record.groupName,
      _effectivePricingLabel(record),
      if (record.counterSpecSummaryLabel.isNotEmpty)
        record.counterSpecSummaryLabel,
      if (record.note.isNotEmpty) record.note,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calendarMonth = _calendarMonth;
    final calendarSummaries = _calendarMonthSummaries;
    final selectedCalendarDate = _selectedCalendarDate;
    final selectedCalendarSummary = _selectedCalendarSummary;
    final selectedDayRecords = _records.where((record) {
      return _sameDay(record.occurredAt, selectedCalendarDate);
    }).toList()
      ..sort((a, b) {
        final timeCompare = b.occurredAt.compareTo(a.occurredAt);
        if (timeCompare != 0) {
          return timeCompare;
        }
        return (b.id ?? 0).compareTo(a.id ?? 0);
      });
    final selectedDayMediaByRecordId = <int, List<ActivityRecordMediaModel>>{};
    for (final media in _recordMedia) {
      final bucket = selectedDayMediaByRecordId.putIfAbsent(
        media.recordId,
        () => <ActivityRecordMediaModel>[],
      );
      bucket.add(media);
    }
    final filteredRecords = _filteredRecords;
    final counterRecords = filteredRecords.where((record) => record.isCounter);
    final multiRecords = filteredRecords.where((record) => record.isMulti);
    final ticketRecords = filteredRecords.where((record) => record.isTicket);
    final recordCount = filteredRecords.length;
    final counterCountTotal = counterRecords.fold<int>(
      0,
      (sum, record) => sum + record.counterCountTotal,
    );
    final multiCountTotal = multiRecords.fold<int>(
      0,
      (sum, record) => sum + record.multiTotalCount,
    );
    final ticketCountTotal = ticketRecords.fold<int>(
      0,
      (sum, record) => sum + record.ticketQuantity,
    );
    final memberContributionTotal = counterCountTotal +
        multiRecords.fold<int>(
          0,
          (sum, record) => sum + record.multiContributionTotal,
        );
    final totalAmount = filteredRecords.fold<double>(
      0,
      (sum, record) => sum + _effectiveTotalAmount(record),
    );

    final typeTotals = {
      for (final field in CounterCountField.values)
        field: counterRecords.fold<int>(
              0,
              (sum, record) => sum + chartTypeFieldContribution(record, field),
            ) +
            multiRecords.fold<int>(
              0,
              (sum, record) => sum + chartTypeFieldContribution(record, field),
            ),
    };
    final customTypeTotals = <String, int>{};
    for (final record in counterRecords) {
      for (final item in record.effectiveCustomChekiCounts) {
        final label = item.label.trim();
        if (label.isEmpty) {
          continue;
        }
        customTypeTotals[label] = (customTypeTotals[label] ?? 0) + item.count;
      }
    }

    final memberTotals = <String, _MemberStatEntry>{};
    for (final record in counterRecords) {
      final key = _memberStatsMode == MemberStatsMode.group
          ? _memberStatKey(record.groupName, record.subjectName)
          : _personStatKey(
              personId: record.personId,
              personName: record.personName,
              groupName: record.groupName,
              subjectName: record.subjectName,
            );
      final entry = memberTotals.putIfAbsent(
        key,
        () => _MemberStatEntry(
          name: _memberStatsMode == MemberStatsMode.group
              ? record.subjectName
              : (record.personName.trim().isEmpty
                  ? record.subjectName
                  : record.personName.trim()),
          groupName: record.groupName,
          isPersonEntry: _memberStatsMode == MemberStatsMode.person,
        ),
      );
      entry.groups.add(record.groupName.trim());
      entry.count += record.counterCountTotal;
      entry.amount += _effectiveTotalAmount(record);
    }
    for (final record in multiRecords) {
      for (final participant in record.effectiveParticipants) {
        final key = _memberStatsMode == MemberStatsMode.group
            ? _memberStatKey(participant.groupName, participant.memberName)
            : _personStatKey(
                personId: participant.personId,
                personName: participant.resolvedPersonName,
                groupName: participant.groupName,
                subjectName: participant.memberName,
              );
        final entry = memberTotals.putIfAbsent(
          key,
          () => _MemberStatEntry(
            name: _memberStatsMode == MemberStatsMode.group
                ? participant.memberName
                : participant.resolvedPersonName,
            groupName: participant.groupName,
            isPersonEntry: _memberStatsMode == MemberStatsMode.person,
          ),
        );
        entry.groups.add(participant.groupName.trim());
        entry.count += record.effectiveMultiQuantity;
        entry.amount += _effectiveMultiParticipantAmountShare(record);
      }
    }
    final memberEntries = memberTotals.values.toList()
      ..sort((a, b) {
        final countCompare = b.count.compareTo(a.count);
        if (countCompare != 0) {
          return countCompare;
        }
        return b.amount.compareTo(a.amount);
      });

    final groupSummaries = <String, _GroupSummary>{};
    for (final record in counterRecords) {
      final key = record.groupName.trim().isEmpty ? '未分组' : record.groupName;
      final summary = groupSummaries.putIfAbsent(
        key,
        () => _GroupSummary(groupName: key),
      );
      summary.amount += _effectiveTotalAmount(record);
      summary.recordCount += 1;
      for (final field in CounterCountField.values) {
        summary.counts[field] =
            (summary.counts[field] ?? 0) + record.countForField(field);
      }
      for (final item in record.effectiveCustomChekiCounts) {
        final label = item.label.trim();
        if (label.isEmpty) {
          continue;
        }
        summary.customCounts[label] =
            (summary.customCounts[label] ?? 0) + item.count;
      }
    }
    for (final record in multiRecords) {
      final participantsByGroup = <String, int>{};
      for (final participant in record.effectiveParticipants) {
        final key = participant.groupName.trim().isEmpty
            ? (record.groupName.trim().isEmpty ? '未分组' : record.groupName)
            : participant.groupName.trim();
        participantsByGroup[key] = (participantsByGroup[key] ?? 0) + 1;
      }
      if (participantsByGroup.isEmpty) {
        final fallbackGroup =
            record.groupName.trim().isEmpty ? '未分组' : record.groupName;
        participantsByGroup[fallbackGroup] = 1;
      }

      participantsByGroup.forEach((groupName, participantSlots) {
        final summary = groupSummaries.putIfAbsent(
          groupName,
          () => _GroupSummary(groupName: groupName),
        );
        summary.amount +=
            _effectiveMultiParticipantAmountShare(record) * participantSlots;
        summary.recordCount += 1;
        summary.counts[CounterCountField.groupCut] =
            (summary.counts[CounterCountField.groupCut] ?? 0) +
                chartGroupSummaryGroupCutContribution(record);
        summary.multiCount += chartGroupSummaryMultiContribution(record);
      });
    }
    final sortedGroupSummaries = groupSummaries.values.toList()
      ..sort((a, b) => b.totalCount.compareTo(a.totalCount));

    final multiSummaries = <String, _MultiSummary>{};
    for (final record in multiRecords) {
      final dateKey = _formatDate(record.occurredAt);
      final labelKey = record.multiDisplayName;
      final key = '$dateKey|$labelKey';
      final summary = multiSummaries.putIfAbsent(
        key,
        () => _MultiSummary(
          title: labelKey,
          date: dateKey,
        ),
      );
      if (record.multiFieldLabel.isNotEmpty) {
        summary.specLabel = record.multiFieldLabel;
      }
      summary.groups.addAll(
        record.effectiveParticipants
            .map((participant) => participant.groupName.trim())
            .where((groupName) => groupName.isNotEmpty),
      );
      summary.quantity += record.effectiveMultiQuantity;
      summary.participantCount =
          summary.participantCount > record.multiParticipantCount
              ? summary.participantCount
              : record.multiParticipantCount;
      summary.amount += _effectiveTotalAmount(record);
      if (record.note.trim().isNotEmpty) {
        summary.notes.add(record.note.trim());
      }
    }
    final sortedMultiSummaries = multiSummaries.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    final ticketSummaries = <String, _TicketSummary>{};
    for (final record in ticketRecords) {
      final dateKey = _formatDate(record.occurredAt);
      final sessionKey = record.sessionLabel.trim();
      final key = '$dateKey|${record.subjectName}|$sessionKey';
      final summary = ticketSummaries.putIfAbsent(
        key,
        () => _TicketSummary(
          eventName: record.subjectName,
          sessionLabel: sessionKey,
          date: dateKey,
        ),
      );
      summary.quantity += record.ticketQuantity;
      summary.amount += _effectiveTotalAmount(record);
      summary.notes.add(record.note);
    }
    final sortedTicketSummaries = ticketSummaries.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    const piePalette = [
      Color(0xFF4F46E5),
      Color(0xFF06B6D4),
      Color(0xFF22C55E),
      Color(0xFFF97316),
      Color(0xFFEC4899),
      Color(0xFFEAB308),
      Color(0xFF8B5CF6),
      Color(0xFF14B8A6),
    ];

    final memberPieData = <_PieDatum>[];
    final visibleMembers = memberEntries.take(6).toList();
    for (var index = 0; index < visibleMembers.length; index++) {
      final entry = visibleMembers[index];
      if (entry.count <= 0) {
        continue;
      }
      memberPieData.add(
        _PieDatum(
          label: entry.chartLabel,
          value: entry.count.toDouble(),
          color: piePalette[index % piePalette.length],
        ),
      );
    }
    final remainingMemberTotal =
        memberEntries.skip(6).fold<int>(0, (sum, entry) => sum + entry.count);
    if (remainingMemberTotal > 0) {
      memberPieData.add(
        _PieDatum(
          label: '其他成员',
          value: remainingMemberTotal.toDouble(),
          color: const Color(0xFF94A3B8),
        ),
      );
    }

    final groupPieData = <_PieDatum>[];
    final visibleGroups = sortedGroupSummaries.take(5).toList();
    for (var index = 0; index < visibleGroups.length; index++) {
      final summary = visibleGroups[index];
      if (summary.totalCount <= 0) {
        continue;
      }
      groupPieData.add(
        _PieDatum(
          label: summary.groupName,
          value: summary.totalCount.toDouble(),
          color: piePalette[(index + 2) % piePalette.length],
        ),
      );
    }
    final remainingGroupTotal = sortedGroupSummaries
        .skip(5)
        .fold<int>(0, (sum, summary) => sum + summary.totalCount);
    if (remainingGroupTotal > 0) {
      groupPieData.add(
        _PieDatum(
          label: '其他团体',
          value: remainingGroupTotal.toDouble(),
          color: Color(0xFF94A3B8),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('统计与流水'),
        actions: [
          IconButton(
            onPressed: _openPricingPage,
            icon: const Icon(Icons.sell_outlined),
            tooltip: '团体配置',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddRecordDialog,
        icon: const Icon(Icons.add),
        label: const Text('新增记录'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary.withAlpha(16),
                    theme.colorScheme.secondary.withAlpha(10),
                    theme.colorScheme.surface,
                  ],
                ),
              ),
              child: RefreshIndicator(
                onRefresh: _loadData,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            theme.colorScheme.primary.withAlpha(28),
                            theme.colorScheme.secondary.withAlpha(18),
                          ],
                        ),
                        border: Border.all(
                          color: theme.colorScheme.primary.withAlpha(28),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: StatsScope.values.map((scope) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(scope.label),
                                    selected: _scope == scope,
                                    onSelected: (_) {
                                      setState(() {
                                        _scope = scope;
                                      });
                                    },
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          if (_scope == StatsScope.day) ...[
                            const SizedBox(height: 12),
                            Text(
                              '单日直接在下方日历切换日期和月份',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                          ] else ...[
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                IconButton.filledTonal(
                                  onPressed: _scope == StatsScope.all
                                      ? null
                                      : () => _moveScope(-1),
                                  icon: const Icon(Icons.chevron_left),
                                ),
                                Expanded(
                                  child: Column(
                                    children: [
                                      Text(
                                        _scope.label,
                                        style: theme.textTheme.labelLarge,
                                      ),
                                      const SizedBox(height: 4),
                                      InkWell(
                                        onTap: _scope == StatsScope.all
                                            ? null
                                            : _pickScopeAnchor,
                                        borderRadius: BorderRadius.circular(18),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 10,
                                          ),
                                          decoration: BoxDecoration(
                                            color: theme.colorScheme.surface,
                                            borderRadius:
                                                BorderRadius.circular(18),
                                            border: Border.all(
                                              color: theme
                                                  .colorScheme.outlineVariant,
                                            ),
                                          ),
                                          child: Column(
                                            children: [
                                              if (_scope != StatsScope.all)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    bottom: 4,
                                                  ),
                                                  child: Icon(
                                                    Icons
                                                        .calendar_month_outlined,
                                                    size: 18,
                                                    color: theme
                                                        .colorScheme.primary,
                                                  ),
                                                ),
                                              Text(
                                                _scopeTitle,
                                                textAlign: TextAlign.center,
                                                style: theme
                                                    .textTheme.headlineSmall
                                                    ?.copyWith(
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton.filledTonal(
                                  onPressed: _canMoveForward
                                      ? () => _moveScope(1)
                                      : null,
                                  icon: const Icon(Icons.chevron_right),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                          ],
                          SegmentedButton<MemberStatsMode>(
                            segments: const [
                              ButtonSegment<MemberStatsMode>(
                                value: MemberStatsMode.group,
                                label: Text('按团籍'),
                                icon: Icon(Icons.groups_2_outlined),
                              ),
                              ButtonSegment<MemberStatsMode>(
                                value: MemberStatsMode.person,
                                label: Text('按真人'),
                                icon: Icon(Icons.person_search_outlined),
                              ),
                            ],
                            selected: {_memberStatsMode},
                            onSelectionChanged: (selection) {
                              setState(() {
                                _memberStatsMode = selection.first;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_showCalendar) ...[
                      _CalendarOverviewCard(
                        month: calendarMonth,
                        selectedDate: selectedCalendarDate,
                        scope: _scope,
                        activeRange: _activeRange,
                        summaries: calendarSummaries,
                        onDateSelected: _handleCalendarDaySelected,
                        onPreviousMonth: () => _changeCalendarMonth(-1),
                        onNextMonth: () => _changeCalendarMonth(1),
                        onHeaderTap: _pickCalendarDate,
                      ),
                      const SizedBox(height: 12),
                      _CalendarDayDetailCard(
                        date: selectedCalendarDate,
                        summary: selectedCalendarSummary,
                        dateFormatter: _formatDate,
                        records: selectedDayRecords,
                        mediaByRecordId: selectedDayMediaByRecordId,
                        recordSubtitleBuilder: _recordSubtitle,
                        recordAmountBuilder: _effectiveTotalAmount,
                        amountFormatter: _formatAmount,
                        onPreviewMedia: _previewMedia,
                      ),
                      const SizedBox(height: 16),
                    ],
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth > 720 ? 4 : 2;
                        final spacing = 12.0;
                        final itemWidth =
                            (constraints.maxWidth - (spacing * (columns - 1))) /
                                columns;

                        return Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: [
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '记录数',
                                value: '$recordCount',
                                hint: '本周期共 $recordCount 条',
                                icon: Icons.receipt_long_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '拍切总数',
                                value: '$counterCountTotal',
                                hint: '单人切规格求和',
                                icon: Icons.photo_library_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '多人切总数',
                                value: '$multiCountTotal',
                                hint: '按参与人数统计',
                                icon: Icons.people_alt_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '门票总数',
                                value: '$ticketCountTotal',
                                hint: '门票记录数量求和',
                                icon: Icons.confirmation_num_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '总金额',
                                value: '¥${_formatAmount(totalAmount)}',
                                hint: '按记录快照价格统计',
                                icon: Icons.payments_outlined,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    if (memberPieData.isNotEmpty || groupPieData.isNotEmpty)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth > 760;
                          final chartWidth = wide
                              ? (constraints.maxWidth - 12) / 2
                              : constraints.maxWidth;

                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              SizedBox(
                                width: chartWidth,
                                child: _PieBreakdownCard(
                                  title:
                                      _memberStatsMode == MemberStatsMode.group
                                          ? '成员占比'
                                          : '真人占比',
                                  emptyMessage:
                                      _memberStatsMode == MemberStatsMode.group
                                          ? '当前周期内还没有成员记录。'
                                          : '当前周期内还没有真人维度数据。',
                                  centerLabel:
                                      _memberStatsMode == MemberStatsMode.group
                                          ? '成员'
                                          : '真人',
                                  data: memberPieData,
                                ),
                              ),
                              SizedBox(
                                width: chartWidth,
                                child: _PieBreakdownCard(
                                  title: '团体占比',
                                  emptyMessage: '当前周期内还没有团体数据。',
                                  centerLabel: '团体',
                                  data: groupPieData,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    if (memberPieData.isNotEmpty || groupPieData.isNotEmpty)
                      const SizedBox(height: 16),
                    _SectionCard(
                      title: '规格汇总',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: CounterCountField.values.map((field) {
                              return _MetricChip(
                                label: field.label,
                                value: '${typeTotals[field] ?? 0}',
                              );
                            }).toList(),
                          ),
                          if (customTypeTotals.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              '自定义类型',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: customTypeTotals.entries.map((entry) {
                                return _MetricChip(
                                  label: entry.key,
                                  value: '${entry.value}',
                                );
                              }).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '团体统计',
                      child: sortedGroupSummaries.isEmpty
                          ? const Text('当前周期内还没有成员记录。')
                          : Column(
                              children: sortedGroupSummaries.map((summary) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                summary.groupName,
                                                style: theme
                                                    .textTheme.titleMedium
                                                    ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              '¥${_formatAmount(summary.amount)}',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: CounterCountField.values
                                              .map((field) {
                                            return _MetricChip(
                                              label: field.shortLabel,
                                              value:
                                                  '${summary.counts[field] ?? 0}',
                                            );
                                          }).toList()
                                            ..add(
                                              _MetricChip(
                                                label: '多人切',
                                                value: '${summary.multiCount}',
                                              ),
                                            )
                                            ..addAll(
                                              summary.customCounts.entries.map(
                                                (entry) => _MetricChip(
                                                  label: entry.key,
                                                  value: '${entry.value}',
                                                ),
                                              ),
                                            ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '多人切',
                      child: sortedMultiSummaries.isEmpty
                          ? const Text('当前周期内还没有多人切记录。')
                          : Column(
                              children: sortedMultiSummaries.map((summary) {
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading:
                                      const Icon(Icons.people_alt_outlined),
                                  title: Text(summary.title),
                                  subtitle: Text(
                                    [
                                      summary.date,
                                      if (summary.groupLabel.isNotEmpty)
                                        summary.groupLabel,
                                      if (summary.specLabel.isNotEmpty)
                                        summary.specLabel,
                                      if (summary.participantCount > 0)
                                        '${summary.participantCount} 人',
                                      if (summary.notes.isNotEmpty)
                                        summary.notes.last,
                                    ].join(' · '),
                                  ),
                                  trailing: Text(
                                    '${summary.quantity} 次\n¥${_formatAmount(summary.amount)}',
                                    textAlign: TextAlign.right,
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '门票场次',
                      child: sortedTicketSummaries.isEmpty
                          ? const Text('当前周期内还没有门票记录。')
                          : Column(
                              children: sortedTicketSummaries.map((summary) {
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(
                                    Icons.confirmation_num_outlined,
                                  ),
                                  title: Text(summary.eventName),
                                  subtitle: Text(
                                    [
                                      summary.date,
                                      if (summary.sessionLabel.isNotEmpty)
                                        summary.sessionLabel,
                                      if (summary.notes.isNotEmpty)
                                        summary.notes.last,
                                    ].join(' · '),
                                  ),
                                  trailing: Text(
                                    '${summary.quantity} 张\n¥${_formatAmount(summary.amount)}',
                                    textAlign: TextAlign.right,
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: _memberStatsMode == MemberStatsMode.group
                          ? '成员贡献'
                          : '真人贡献',
                      child: memberEntries.isEmpty
                          ? Text(
                              _memberStatsMode == MemberStatsMode.group
                                  ? '当前周期内还没有成员记录。'
                                  : '当前周期内还没有真人维度数据。',
                            )
                          : Column(
                              children: memberEntries.take(20).map((entry) {
                                final percent = memberContributionTotal == 0
                                    ? 0.0
                                    : entry.count / memberContributionTotal;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  entry.name,
                                                  style: theme
                                                      .textTheme.titleMedium
                                                      ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                if (entry.groupLabel.isNotEmpty)
                                                  Text(
                                                    entry.groupLabel,
                                                    style: theme
                                                        .textTheme.bodySmall,
                                                  ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            '${entry.count}',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: LinearProgressIndicator(
                                          value: percent.clamp(0.0, 1.0),
                                          minHeight: 8,
                                          backgroundColor: theme.colorScheme
                                              .surfaceContainerHighest,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '流水明细',
                      child: filteredRecords.isEmpty
                          ? const Text('当前周期内还没有记录。')
                          : Column(
                              children: filteredRecords.take(50).map((record) {
                                final trailingAmount =
                                    '¥${_formatAmount(_effectiveTotalAmount(record))}';
                                final subtitle = _recordSubtitle(record);

                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(_recordIcon(record)),
                                  title: Text(_recordTitle(record)),
                                  subtitle: Text(subtitle),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(trailingAmount),
                                      if (_canMutateRecord(record))
                                        PopupMenuButton<_RecordAction>(
                                          tooltip: '记录操作',
                                          onSelected: (action) async {
                                            switch (action) {
                                              case _RecordAction.edit:
                                                await _editRecord(record);
                                                break;
                                              case _RecordAction.delete:
                                                await _deleteRecord(record);
                                                break;
                                            }
                                          },
                                          itemBuilder: (context) => const [
                                            PopupMenuItem(
                                              value: _RecordAction.edit,
                                              child: Text('编辑'),
                                            ),
                                            PopupMenuItem(
                                              value: _RecordAction.delete,
                                              child: Text('删除'),
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  String _formatAmount(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }
}

enum MemberStatsMode {
  group,
  person,
}

enum _RecordAction {
  edit,
  delete,
}

enum StatsScope {
  day('日统计'),
  week('周统计'),
  month('月统计'),
  year('年统计'),
  all('全部');

  final String label;

  const StatsScope(this.label);

  DateTimeRange? rangeFor(DateTime anchor) {
    final base = DateTime(anchor.year, anchor.month, anchor.day);
    switch (this) {
      case StatsScope.day:
        return DateTimeRange(
          start: base,
          end: base.add(const Duration(days: 1)),
        );
      case StatsScope.week:
        final start = base.subtract(Duration(days: base.weekday - 1));
        return DateTimeRange(
          start: start,
          end: start.add(const Duration(days: 7)),
        );
      case StatsScope.month:
        return DateTimeRange(
          start: DateTime(anchor.year, anchor.month),
          end: anchor.month == 12
              ? DateTime(anchor.year + 1, 1)
              : DateTime(anchor.year, anchor.month + 1),
        );
      case StatsScope.year:
        return DateTimeRange(
          start: DateTime(anchor.year),
          end: DateTime(anchor.year + 1),
        );
      case StatsScope.all:
        return null;
    }
  }

  DateTime shift(DateTime anchor, int offset) {
    switch (this) {
      case StatsScope.day:
        return anchor.add(Duration(days: offset));
      case StatsScope.week:
        return anchor.add(Duration(days: 7 * offset));
      case StatsScope.month:
        return DateTime(anchor.year, anchor.month + offset, anchor.day);
      case StatsScope.year:
        return DateTime(anchor.year + offset, anchor.month, anchor.day);
      case StatsScope.all:
        return anchor;
    }
  }
}

class _MonthSelection {
  final int year;
  final int month;

  const _MonthSelection({
    required this.year,
    required this.month,
  });
}

class _MonthPickerDialog extends StatefulWidget {
  final DateTime initialDate;

  const _MonthPickerDialog({
    required this.initialDate,
  });

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _selectedYear;
  late int _selectedMonth;

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialDate.year;
    _selectedMonth = widget.initialDate.month;
  }

  @override
  Widget build(BuildContext context) {
    final currentYear = DateTime.now().year;
    final years = List<int>.generate(
      12,
      (index) => currentYear - 5 + index,
    );

    return AlertDialog(
      title: const Text('选择月份'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<int>(
            initialValue: _selectedYear,
            decoration: const InputDecoration(labelText: '年份'),
            items: years
                .map(
                  (year) => DropdownMenuItem(
                    value: year,
                    child: Text('$year 年'),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _selectedYear = value;
              });
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _selectedMonth,
            decoration: const InputDecoration(labelText: '月份'),
            items: List<int>.generate(12, (index) => index + 1)
                .map(
                  (month) => DropdownMenuItem(
                    value: month,
                    child: Text('$month 月'),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                _selectedMonth = value;
              });
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _MonthSelection(
                year: _selectedYear,
                month: _selectedMonth,
              ),
            );
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _YearPickerDialog extends StatefulWidget {
  final int initialYear;

  const _YearPickerDialog({
    required this.initialYear,
  });

  @override
  State<_YearPickerDialog> createState() => _YearPickerDialogState();
}

class _YearPickerDialogState extends State<_YearPickerDialog> {
  late int _selectedYear;

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialYear;
  }

  @override
  Widget build(BuildContext context) {
    final currentYear = DateTime.now().year;
    final years = List<int>.generate(
      16,
      (index) => currentYear - 10 + index,
    );

    return AlertDialog(
      title: const Text('选择年份'),
      content: DropdownButtonFormField<int>(
        initialValue: _selectedYear,
        decoration: const InputDecoration(labelText: '年份'),
        items: years
            .map(
              (year) => DropdownMenuItem(
                value: year,
                child: Text('$year 年'),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value == null) {
            return;
          }
          setState(() {
            _selectedYear = value;
          });
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selectedYear),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _CalendarDaySummary {
  final DateTime date;
  final int recordCount;
  final int activityCount;
  final int cutCount;
  final int scanCount;
  final int ticketCount;
  final double amount;
  final List<String> activityLabels;

  const _CalendarDaySummary({
    required this.date,
    required this.recordCount,
    required this.activityCount,
    required this.cutCount,
    required this.scanCount,
    required this.ticketCount,
    required this.amount,
    required this.activityLabels,
  });

  bool get hasRecords => recordCount > 0;
}

class _CalendarDaySummaryBuilder {
  final DateTime date;
  int recordCount = 0;
  int cutCount = 0;
  int scanCount = 0;
  int ticketCount = 0;
  double amount = 0;
  final Set<String> activityKeys = <String>{};
  final List<String> activityLabels = <String>[];

  _CalendarDaySummaryBuilder({
    required this.date,
  });

  _CalendarDaySummary build() {
    return _CalendarDaySummary(
      date: date,
      recordCount: recordCount,
      activityCount: activityKeys.length,
      cutCount: cutCount,
      scanCount: scanCount,
      ticketCount: ticketCount,
      amount: amount,
      activityLabels: List<String>.from(activityLabels),
    );
  }
}

class _CalendarOverviewCard extends StatelessWidget {
  final DateTime month;
  final DateTime selectedDate;
  final StatsScope scope;
  final DateTimeRange? activeRange;
  final Map<DateTime, _CalendarDaySummary> summaries;
  final ValueChanged<DateTime> onDateSelected;
  final VoidCallback onPreviousMonth;
  final VoidCallback onNextMonth;
  final VoidCallback onHeaderTap;

  const _CalendarOverviewCard({
    required this.month,
    required this.selectedDate,
    required this.scope,
    required this.activeRange,
    required this.summaries,
    required this.onDateSelected,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onHeaderTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const recordIndicatorColor = Color(0xFF2563EB);
    const scanIndicatorColor = Color(0xFFD9480F);
    final firstDay = DateTime(month.year, month.month, 1);
    final daysInMonth = month.month == 12
        ? DateTime(month.year + 1, 1, 0).day
        : DateTime(month.year, month.month + 1, 0).day;
    final leadingSlots = firstDay.weekday - 1;
    final totalSlots = ((leadingSlots + daysInMonth + 6) ~/ 7) * 7;
    const weekLabels = ['一', '二', '三', '四', '五', '六', '日'];

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withAlpha(10),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: onPreviousMonth,
                icon: const Icon(Icons.chevron_left),
                tooltip: '上个月',
              ),
              Expanded(
                child: InkWell(
                  onTap: onHeaderTap,
                  borderRadius: BorderRadius.circular(18),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${month.year} 年 ${month.month} 月',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton.filledTonal(
                onPressed: onNextMonth,
                icon: const Icon(Icons.chevron_right),
                tooltip: '下个月',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _CalendarLegend(
                color: recordIndicatorColor,
                label: '有记录',
              ),
              _CalendarLegend(
                color: scanIndicatorColor,
                label: '有切图',
              ),
              _CalendarLegend(
                color: theme.colorScheme.primary.withAlpha(28),
                label: scope == StatsScope.week ? '当前选中周' : '当前选中日期',
                hollow: scope == StatsScope.week,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: weekLabels.map((label) {
              return Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalSlots,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.78,
            ),
            itemBuilder: (context, index) {
              final dayNumber = index - leadingSlots + 1;
              if (dayNumber <= 0 || dayNumber > daysInMonth) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                );
              }

              final date = DateTime(month.year, month.month, dayNumber);
              final summary = summaries[date];
              final hasRecords = summary?.hasRecords ?? false;
              final hasScans = (summary?.scanCount ?? 0) > 0;
              final isSelected = _sameDay(date, selectedDate);
              final isInActiveWeek = scope == StatsScope.week &&
                  activeRange != null &&
                  !date.isBefore(activeRange!.start) &&
                  date.isBefore(activeRange!.end);

              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => onDateSelected(date),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? theme.colorScheme.primaryContainer
                          : isInActiveWeek
                              ? theme.colorScheme.primary.withAlpha(16)
                              : theme.colorScheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected
                            ? theme.colorScheme.primary
                            : isInActiveWeek
                                ? theme.colorScheme.primary.withAlpha(80)
                                : Colors.transparent,
                        width: isSelected ? 1.6 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hasRecords
                                ? (isSelected
                                    ? recordIndicatorColor
                                    : recordIndicatorColor.withAlpha(24))
                                : Colors.transparent,
                            border: Border.all(
                              color: hasRecords
                                  ? recordIndicatorColor
                                  : theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Text(
                            '$dayNumber',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: hasRecords
                                  ? (isSelected
                                      ? Colors.white
                                      : recordIndicatorColor)
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (hasRecords || hasScans)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (hasRecords)
                                _CalendarStatusDot(
                                  color: recordIndicatorColor,
                                ),
                              if (hasScans) ...[
                                if (hasRecords) const SizedBox(width: 4),
                                _CalendarStatusDot(
                                  color: scanIndicatorColor,
                                ),
                              ],
                            ],
                          )
                        else
                          const SizedBox(height: 7),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  bool _sameDay(DateTime left, DateTime right) {
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
  }
}

class _CalendarDayDetailCard extends StatelessWidget {
  final DateTime date;
  final _CalendarDaySummary? summary;
  final String Function(DateTime value) dateFormatter;
  final List<ActivityRecordModel> records;
  final Map<int, List<ActivityRecordMediaModel>> mediaByRecordId;
  final String Function(ActivityRecordModel record) recordSubtitleBuilder;
  final double Function(ActivityRecordModel record) recordAmountBuilder;
  final String Function(double value) amountFormatter;
  final ValueChanged<ActivityRecordMediaModel> onPreviewMedia;

  const _CalendarDayDetailCard({
    required this.date,
    required this.summary,
    required this.dateFormatter,
    required this.records,
    required this.mediaByRecordId,
    required this.recordSubtitleBuilder,
    required this.recordAmountBuilder,
    required this.amountFormatter,
    required this.onPreviewMedia,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentSummary = summary;

    return _SectionCard(
      title: '当日摘要',
      child: currentSummary == null
          ? Text('${dateFormatter(date)} 还没有记录。')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateFormatter(date),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _MetricChip(
                      label: '偶活',
                      value: '${currentSummary.activityCount}',
                    ),
                    _MetricChip(
                      label: '切数',
                      value: '${currentSummary.cutCount}',
                    ),
                    if (currentSummary.scanCount > 0)
                      _MetricChip(
                        label: '切图',
                        value: '${currentSummary.scanCount}',
                      ),
                    if (currentSummary.ticketCount > 0)
                      _MetricChip(
                        label: '门票',
                        value: '${currentSummary.ticketCount}',
                      ),
                    _MetricChip(
                      label: '金额',
                      value: '¥${amountFormatter(currentSummary.amount)}',
                    ),
                  ],
                ),
                if (currentSummary.activityLabels.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        currentSummary.activityLabels.take(6).map((label) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(label),
                      );
                    }).toList(),
                  ),
                ],
                if (records.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '当天记录与切图',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...records.map((record) {
                    final media = record.id == null
                        ? const <ActivityRecordMediaModel>[]
                        : (mediaByRecordId[record.id!] ??
                            const <ActivityRecordMediaModel>[]);
                    final scanCount = media.where((item) => item.isScan).length;
                    final memoryCount = media.length - scanCount;

                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  record.isTicket
                                      ? Icons.confirmation_num_outlined
                                      : record.isMulti
                                          ? Icons.people_alt_outlined
                                          : Icons.photo_library_outlined,
                                  size: 18,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      record.isMulti
                                          ? record.multiDisplayName
                                          : record.subjectName,
                                      style:
                                          theme.textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      recordSubtitleBuilder(record),
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              Text(
                                '¥${amountFormatter(recordAmountBuilder(record))}',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                          if (media.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (scanCount > 0)
                                  _MetricChip(
                                    label: '切图',
                                    value: '$scanCount',
                                  ),
                                if (memoryCount > 0)
                                  _MetricChip(
                                    label: '纪念照',
                                    value: '$memoryCount',
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 96,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: media.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final item = media[index];
                                  return Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(14),
                                      onTap: () => onPreviewMedia(item),
                                      child: Ink(
                                        width: 78,
                                        height: 96,
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          border: Border.all(
                                            color: item.isScan
                                                ? const Color(0xFFD9480F)
                                                : theme
                                                    .colorScheme.outlineVariant,
                                            width: item.isScan ? 2 : 1,
                                          ),
                                        ),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(13),
                                          child: Image.file(
                                            File(item.path),
                                            fit: BoxFit.cover,
                                            errorBuilder:
                                                (context, error, stackTrace) {
                                              return Container(
                                                color: theme.colorScheme
                                                    .surfaceContainerLow,
                                                alignment: Alignment.center,
                                                child: const Icon(
                                                  Icons.broken_image_outlined,
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
    );
  }
}

class _CalendarLegend extends StatelessWidget {
  final Color color;
  final String label;
  final bool hollow;

  const _CalendarLegend({
    required this.color,
    required this.label,
    this.hollow = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hollow ? Colors.transparent : color,
            border: Border.all(color: color),
          ),
        ),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}

class _CalendarStatusDot extends StatelessWidget {
  final Color color;

  const _CalendarStatusDot({
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _PieDatum {
  final String label;
  final double value;
  final Color color;

  const _PieDatum({
    required this.label,
    required this.value,
    required this.color,
  });
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String hint;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.hint,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(90),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(height: 12),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 6),
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PieBreakdownCard extends StatelessWidget {
  final String title;
  final String emptyMessage;
  final String centerLabel;
  final List<_PieDatum> data;

  const _PieBreakdownCard({
    required this.title,
    required this.emptyMessage,
    required this.centerLabel,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return _SectionCard(
        title: title,
        child: Text(emptyMessage),
      );
    }

    final total = data.fold<double>(0, (sum, item) => sum + item.value);

    return _SectionCard(
      title: title,
      child: Column(
        children: [
          SizedBox(
            height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 42,
                    startDegreeOffset: -90,
                    sections: data.map((item) {
                      final percent = total == 0 ? 0.0 : item.value / total;
                      return PieChartSectionData(
                        color: item.color,
                        value: item.value,
                        radius: 54,
                        title: percent >= 0.08
                            ? '${(percent * 100).toStringAsFixed(0)}%'
                            : '',
                        titleStyle:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                      );
                    }).toList(),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      centerLabel,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      total.toStringAsFixed(
                          total == total.roundToDouble() ? 0 : 1),
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: data.map((item) {
              final percent = total == 0 ? 0.0 : item.value / total;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: item.color.withAlpha(26),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: item.color.withAlpha(80),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: item.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${item.label} ${item.value.toStringAsFixed(item.value == item.value.roundToDouble() ? 0 : 1)}'
                      ' · ${(percent * 100).toStringAsFixed(1)}%',
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetricChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _GroupSummary {
  final String groupName;
  final Map<CounterCountField, int> counts = {};
  final Map<String, int> customCounts = {};
  double amount = 0;
  int recordCount = 0;
  int multiCount = 0;

  _GroupSummary({
    required this.groupName,
  });

  int get totalCount =>
      counts.values.fold<int>(0, (sum, value) => sum + value) +
      customCounts.values.fold<int>(0, (sum, value) => sum + value) +
      multiCount;
}

class _MemberStatEntry {
  final String name;
  final String groupName;
  final bool isPersonEntry;
  final Set<String> groups = {};
  int count = 0;
  double amount = 0;

  _MemberStatEntry({
    required this.name,
    required this.groupName,
    required this.isPersonEntry,
  }) {
    if (groupName.trim().isNotEmpty) {
      groups.add(groupName.trim());
    }
  }

  String get groupLabel {
    final visibleGroups = groups
        .where((groupName) => groupName.trim().isNotEmpty)
        .toList()
      ..sort();
    if (visibleGroups.isEmpty) {
      return '';
    }
    if (!isPersonEntry || visibleGroups.length == 1) {
      return visibleGroups.first;
    }
    if (visibleGroups.length == 2) {
      return visibleGroups.join(' / ');
    }
    return '${visibleGroups[0]} / ${visibleGroups[1]} 等${visibleGroups.length}团';
  }

  String get chartLabel =>
      groupLabel.isEmpty || isPersonEntry ? name : '$name · $groupLabel';
}

class _MultiSummary {
  final String title;
  final String date;
  int quantity = 0;
  int participantCount = 0;
  double amount = 0;
  String specLabel = '';
  final Set<String> groups = {};
  final List<String> notes = [];

  _MultiSummary({
    required this.title,
    required this.date,
  });

  String get groupLabel {
    final visibleGroups = groups
        .where((groupName) => groupName.trim().isNotEmpty)
        .toList()
      ..sort();
    if (visibleGroups.isEmpty) {
      return '';
    }
    if (visibleGroups.length <= 2) {
      return visibleGroups.join(' / ');
    }
    return '${visibleGroups[0]} / ${visibleGroups[1]} 等${visibleGroups.length}团';
  }
}

class _TicketSummary {
  final String eventName;
  final String sessionLabel;
  final String date;
  int quantity = 0;
  double amount = 0;
  final List<String> notes = [];

  _TicketSummary({
    required this.eventName,
    required this.sessionLabel,
    required this.date,
  });
}
