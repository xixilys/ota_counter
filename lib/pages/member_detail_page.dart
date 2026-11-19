import 'dart:io';

import 'package:flutter/material.dart';

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../models/activity_record_media_scope.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../services/face/face_sample_service.dart';
import '../services/person_card_service.dart';
import '../services/ticket_pricing_service.dart';
import '../widgets/add_activity_record_dialog.dart';
import '../widgets/dream/dream_kit.dart';
import '../widgets/counter_count_sheet.dart';
import '../widgets/person/person_cards_sheet.dart';
import '../widgets/person/person_group_switcher.dart';
import 'album/album_page.dart';
import 'album/album_widgets.dart';
import 'album/album_models.dart';
import 'idol_cut_overview_page.dart';
import 'face_recognition_settings_page.dart';
import 'member_face_enrollment_page.dart';
import 'record_memory_page.dart';

/// Records whose stored date is missing are persisted by old migrations as
/// 1970-01-01 (sometimes with a leftover time of day). They must be shown as
/// "日期未知" and sorted last, never as a fake 1970 journal page.
bool isUnknownActivityRecordDay(DateTime value) {
  return value.millisecondsSinceEpoch <= 0 || value.year <= 1970;
}

class MemberDetailPage extends StatefulWidget {
  final CounterModel displayCounter;
  final CounterModel primaryCounter;
  final List<CounterModel> sourceCounters;
  final CounterChangedCallback onCounterChanged;
  final CounterRecordDeletedCallback? onRecordDeleted;

  const MemberDetailPage({
    super.key,
    required this.displayCounter,
    required this.primaryCounter,
    required this.sourceCounters,
    required this.onCounterChanged,
    this.onRecordDeleted,
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
  Map<int, DateTime> _latestActivity = const <int, DateTime>{};
  Map<int, List<ActivityRecordMediaModel>> _recordMediaByRecord =
      const <int, List<ActivityRecordMediaModel>>{};
  bool _loading = true;
  bool _dirty = false;
  CounterModel? _focusedCounter;

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

  bool _sameGroup(String a, String b) {
    final left = _normalizedLookupPart(a);
    final right = _normalizedLookupPart(b);
    return left.isEmpty || right.isEmpty || left == right;
  }

  bool _matchesCounter(CounterModel counter) {
    final fallbackKey =
        '${_normalizedLookupPart(counter.groupName)}|${_normalizedLookupPart(counter.name)}';
    for (final source in widget.sourceCounters) {
      if (source.id != null && counter.id == source.id) return true;
      if (source.personId != null && counter.personId != null) {
        if (source.personId == counter.personId) return true;
        continue;
      }
      // One side may be an old, unlinked alias. Compare the explicitly typed
      // person name (falling back to a linked card's name), but only inside the
      // same group so same-name people in other groups stay out.
      final sourceName = _normalizedLookupPart(
        source.personName.trim().isEmpty && source.personId != null
            ? source.name
            : source.personName,
      );
      final counterName = _normalizedLookupPart(
        counter.personName.trim().isEmpty && counter.personId != null
            ? counter.name
            : counter.personName,
      );
      if (sourceName.isNotEmpty &&
          sourceName == counterName &&
          _sameGroup(source.groupName, counter.groupName)) {
        return true;
      }
      final sourceKey =
          '${_normalizedLookupPart(source.groupName)}|${_normalizedLookupPart(source.name)}';
      if (sourceKey == fallbackKey) return true;
    }
    return false;
  }

  bool _matchesParticipant(ActivityParticipant participant) {
    if (participant.personId != null && _sourcePersonIds.isNotEmpty) {
      if (_sourcePersonIds.contains(participant.personId)) {
        return true;
      }
    }

    final participantPersonName = _normalizedLookupPart(participant.personName);
    if (participantPersonName.isNotEmpty &&
        _sourcePersonNames.contains(
          participantPersonName,
        )) {
      // A member can have duplicate historical person IDs after an idol
      // database refresh. Keep the record visible when the name and at least
      // one participant group still agree, while preserving same-name people
      // in different groups.
      final hasMatchingGroup = widget.sourceCounters.any((counter) {
        final counterPersonName = _normalizedLookupPart(counter.personName);
        if (counterPersonName != participantPersonName) {
          return false;
        }
        final participantGroup = _normalizedLookupPart(participant.groupName);
        final counterGroup = _normalizedLookupPart(counter.groupName);
        return participantGroup.isEmpty ||
            counterGroup.isEmpty ||
            participantGroup == counterGroup;
      });
      if (hasMatchingGroup) {
        return true;
      }
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
    if (record.personId != null && _sourcePersonIds.isNotEmpty) {
      if (_sourcePersonIds.contains(record.personId)) {
        return true;
      }
    }
    final recordPersonName = _normalizedLookupPart(record.personName);
    if (recordPersonName.isNotEmpty) {
      final hasMatchingGroup = widget.sourceCounters.any((counter) {
        final counterPersonName = _normalizedLookupPart(
          counter.personName.trim().isEmpty && counter.personId != null
              ? counter.name
              : counter.personName,
        );
        if (counterPersonName != recordPersonName) {
          return false;
        }
        return _sameGroup(counter.groupName, record.groupName);
      });
      if (hasMatchingGroup) {
        return true;
      }
    }
    final fallbackKey =
        '${_normalizedLookupPart(record.groupName)}|${_normalizedLookupPart(record.subjectName)}';
    if (_fallbackCounterKeys.contains(fallbackKey)) return true;
    // A mixed set may contain both a linked card and an old unlinked alias.
    // The record can still re-link to the linked card by id.
    for (final counter in matchedCounterIds) {
      if (record.counterId == counter) return true;
    }
    return false;
  }

  Future<void> _loadData() async {
    final counters = await DatabaseService.getCounters();
    final pricings = await DatabaseService.getGroupPricings();
    final latestActivity =
        await DatabaseService.getLastCounterActivityDays(counters: counters);
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
    final recordsById = {
      for (final record in relatedRecords)
        if (record.id != null) record.id!: record,
    };
    final scopedMedia = media.where((item) {
      final record = recordsById[item.recordId];
      return record != null &&
          activityRecordMediaBelongsToMember(
            media: item,
            record: record,
            ownerCounters: matchedCounters,
          );
    });
    final recordMediaCounts = <int, int>{};
    final recordMediaByRecord = <int, List<ActivityRecordMediaModel>>{};
    for (final item in scopedMedia) {
      recordMediaCounts[item.recordId] =
          (recordMediaCounts[item.recordId] ?? 0) + 1;
      recordMediaByRecord
          .putIfAbsent(item.recordId, () => <ActivityRecordMediaModel>[])
          .add(item);
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
      _latestActivity = latestActivity;
      _recordMediaCounts = recordMediaCounts;
      _recordMediaByRecord = recordMediaByRecord;
      _loading = false;
    });
  }

  String _formatDate(DateTime? value) {
    if (value == null || isUnknownActivityRecordDay(value)) {
      return '日期未知';
    }
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }

  String _formatShortDate(DateTime value) {
    return '${value.year}.${value.month.toString().padLeft(2, '0')}.'
        '${value.day.toString().padLeft(2, '0')}';
  }

  String _weekdayLabel(DateTime value) {
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return labels[value.weekday - 1];
  }

  int get _recordMediaTotal => _recordMediaCounts.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );

  /// Standard spec totals plus any custom cheki labels recorded on this
  /// member's ledger. The sum always matches [_currentTotalCount].
  Map<String, int> get _specTotals {
    final counters = _effectiveCounters;
    final three = counters.fold<int>(
      0,
      (sum, counter) => sum + counter.aggregatedThreeInchCount,
    );
    final five = counters.fold<int>(
      0,
      (sum, counter) => sum + counter.aggregatedFiveInchCount,
    );
    final shukudai = counters.fold<int>(
      0,
      (sum, counter) =>
          sum + counter.threeInchShukudaiCount + counter.fiveInchShukudaiCount,
    );
    final groupCut = counters.fold<int>(
      0,
      (sum, counter) => sum + counter.groupCutCount,
    );
    final custom = <String, int>{};
    for (final record in _records) {
      for (final item in record.effectiveCustomChekiCounts) {
        final label = item.label.trim();
        if (label.isEmpty) {
          continue;
        }
        custom[label] = (custom[label] ?? 0) + item.count;
      }
    }
    return {
      '3寸': three,
      '5寸': five,
      '宿': shukudai,
      '团切': groupCut,
      ...custom,
    };
  }

  List<DateTime> get _knownRecordDays {
    final days = <DateTime>{};
    for (final record in _records) {
      if (isUnknownActivityRecordDay(record.occurredAt)) {
        continue;
      }
      days.add(DateTime(
        record.occurredAt.year,
        record.occurredAt.month,
        record.occurredAt.day,
      ));
    }
    final sorted = days.toList()..sort();
    return sorted;
  }

  DateTime? get _firstMetDay =>
      _knownRecordDays.isEmpty ? null : _knownRecordDays.first;

  DateTime? get _lastMetDay =>
      _knownRecordDays.isEmpty ? null : _knownRecordDays.last;

  int get _companionDayCount => _knownRecordDays.length;

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
    final focused = _focusedCounter;
    if (focused != null) {
      for (final counter in _matchedCounters) {
        if (counter.id == focused.id) return counter;
      }
    }
    if (_matchedCounters.isNotEmpty) {
      final preferredId =
          PersonCardService.currentCardIdForAny(_matchedCounters);
      if (preferredId != null) {
        for (final counter in _matchedCounters) {
          if (counter.id == preferredId) return counter;
        }
      }
      final ranked = [..._matchedCounters]..sort((a, b) {
          final aDay = a.id == null ? null : _latestActivity[a.id];
          final bDay = b.id == null ? null : _latestActivity[b.id];
          final timeCompare =
              (bDay ?? DateTime(0)).compareTo(aDay ?? DateTime(0));
          if (timeCompare != 0) return timeCompare;
          return b.count.compareTo(a.count);
        });
      return ranked.first;
    }
    return widget.primaryCounter;
  }

  Future<void> _openPersonCards() async {
    final changed = await showPersonCardsSheet(
      context,
      anchor: _sheetCounter,
    );
    if (changed) {
      _dirty = true;
      await _loadData();
    }
  }

  Future<void> _openQuickCount() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => CounterCountSheet(
        counter: _sheetCounter,
        allCounters: _allCounters,
        onCounterChanged: (
          updatedCounter,
          occurredAt, {
          activityName = '',
          venueName = '',
          sessionLabel = '',
          baseCounter,
        }) async {
          final saved = await widget.onCounterChanged(
            updatedCounter,
            occurredAt,
            activityName: activityName,
            venueName: venueName,
            sessionLabel: sessionLabel,
            baseCounter: baseCounter,
          );
          _dirty = true;
          return saved;
        },
        onRecordDeleted: widget.onRecordDeleted,
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
    final unknownDateRecords = <ActivityRecordModel>[];
    for (final record in _records) {
      if (isUnknownActivityRecordDay(record.occurredAt)) {
        unknownDateRecords.add(record);
        continue;
      }
      final day = DateTime(
        record.occurredAt.year,
        record.occurredAt.month,
        record.occurredAt.day,
      );
      grouped.putIfAbsent(day, () => <ActivityRecordModel>[]).add(record);
    }

    _RecordDayGroup buildGroup(
      DateTime? day,
      List<ActivityRecordModel> records,
    ) {
      final media = <ActivityRecordMediaModel>[];
      for (final record in records) {
        final recordId = record.id;
        if (recordId == null) {
          continue;
        }
        media.addAll(_recordMediaByRecord[recordId] ??
            const <ActivityRecordMediaModel>[]);
      }
      media.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return _RecordDayGroup(
        day: day,
        records: records,
        media: media,
      );
    }

    final groups = grouped.entries
        .map((entry) => buildGroup(entry.key, entry.value))
        .toList()
      ..sort((a, b) => b.day!.compareTo(a.day!));

    // A missing date is not a 1970 memory. Keep it as one clearly-labelled
    // journal entry at the very end; stored records stay untouched.
    if (unknownDateRecords.isNotEmpty) {
      groups.add(buildGroup(null, unknownDateRecords));
    }
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

  ActivityRecordDraft _draftFromRecord(ActivityRecordModel record) {
    return ActivityRecordDraft.fromRecord(
      record,
      resolvedCounter: resolveCounterForActivityRecord(_allCounters, record),
    );
  }

  Future<ActivityRecordModel?> _buildRecordFromDraft(
    ActivityRecordDraft draft, {
    int? id,
    String source = 'local',
    String? sourceRecordId,
  }) async {
    return draft.toActivityRecord(
      pricings: _pricings,
      id: id,
      source: source,
      sourceRecordId: sourceRecordId,
    );
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
      await DatabaseService.updateActivityRecordWithCounterImpact(
        record.id!,
        updatedRecord,
      );
      await TicketPricingService.rememberRecord(updatedRecord);
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
      await DatabaseService.deleteActivityRecordWithCounterImpact(record.id!);
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
          ownerCounters: _matchedCounters,
          albumTitle: widget.displayCounter.name,
          albumDate: dayGroup.day,
        ),
      ),
    );
    await _loadData();
  }

  Future<void> _openIdolCutOverview() async {
    final recordsWithId =
        _records.where((record) => record.id != null).toList();
    if (recordsWithId.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有可展示的切图记录')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => IdolCutOverviewPage(
          idolName: widget.displayCounter.name,
          records: recordsWithId,
          ownerCounters: _matchedCounters,
        ),
      ),
    );
    await _loadData();
  }

  Future<void> _openFaceEnrollment() async {
    if (!await FaceRecognitionSettingsPage.ensureEnabled(context) || !mounted) {
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => MemberFaceEnrollmentPage(
        member: FaceSampleService.memberFromCounter(_sheetCounter),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final focus = _sheetCounter;
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final displayCounter = _matchedCounters.isNotEmpty
        ? focus.copyWith(
            name: widget.displayCounter.name,
            groupName: _groupLabel(),
          )
        : widget.displayCounter;
    final rawColor = displayCounter.colorValue;
    final accent = DreamPalette.accent(rawColor, brightness);

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
              onPressed: _loading
                  ? null
                  : () => AlbumPage.openForMember(
                        context,
                        personId: widget.displayCounter.personId,
                        memberName: widget.displayCounter.name,
                        groupName: widget.displayCounter.groupName,
                        colorHex: widget.displayCounter.color,
                      ),
              icon: const Icon(Icons.photo_library_outlined),
              tooltip: '切册',
            ),
            IconButton(
              onPressed: _loading ? null : _openIdolCutOverview,
              icon: const Icon(Icons.grid_view_rounded),
              tooltip: '切总览',
            ),
            IconButton(
              onPressed: _loading ? null : _openPersonCards,
              icon: const Icon(Icons.groups_2_outlined),
              tooltip: '跨团卡片',
            ),
            IconButton(
              onPressed: _loading ? null : _openQuickCount,
              icon: const Icon(Icons.addchart_outlined),
              tooltip: '快捷计数',
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _loading ? null : _openQuickCount,
          backgroundColor: accent,
          foregroundColor: DreamPalette.onColor(accent),
          icon: const Icon(Icons.edit_note_outlined),
          label: const Text('快捷计数'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _loadData,
                child: DreamPaperBackground(
                  accent: accent,
                  ruled: true,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 96),
                    children: [
                      _MemberScrapbookHero(
                        name: displayCounter.name,
                        groupName: _groupLabel(),
                        accent: accent,
                        rawColor: rawColor,
                        totalCount: _currentTotalCount,
                        recordCount: _records.length,
                        mediaCount: _recordMediaTotal,
                        specs: _specTotals,
                        firstMet: _firstMetDay,
                        lastMet: _lastMetDay,
                        companionDays: _companionDayCount,
                        hasUnknownDates:
                            _dayGroups.any((group) => group.isUnknownDate),
                        onFaceTap: _openFaceEnrollment,
                        formatShortDate: _formatShortDate,
                        switcher: _matchedCounters.length > 1
                            ? PersonGroupSwitcher(
                                cards: _effectiveCounters,
                                selected: _sheetCounter,
                                onSelected: (counter) {
                                  setState(() => _focusedCounter = counter);
                                  _dirty = true;
                                },
                                onManage: _openPersonCards,
                              )
                            : null,
                      ),
                      const SizedBox(height: 18),
                      DreamSectionHeader(
                        title: '手帐日记',
                        countLabel: '${_dayGroups.length} 天',
                        trailingText: _records.isEmpty ? null : '按日期倒序',
                        accent: accent,
                      ),
                      const SizedBox(height: 12),
                      if (_records.isEmpty)
                        _EmptyScrapbook(
                          accent: accent,
                          onQuickCount: _openQuickCount,
                        )
                      else
                        ..._dayGroups.map((dayGroup) {
                          final activityLabels = dayGroup.records
                              .map(_recordTitle)
                              .where((item) => item.trim().isNotEmpty)
                              .toSet()
                              .toList()
                            ..sort();
                          final date = dayGroup.day;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: _JournalDayCard(
                              dayGroup: dayGroup,
                              accent: accent,
                              scheme: scheme,
                              dateLabel: dayGroup.isUnknownDate
                                  ? '日期未知'
                                  : _formatDate(date),
                              weekdayLabel: date == null
                                  ? '旧记录没有可用的日期，已排在最末'
                                  : _weekdayLabel(date),
                              activityLabels: activityLabels,
                              recordTitle: _recordTitle,
                              recordIcon: _recordIcon,
                              recordSummary: _recordDaySummary,
                              canMutateRecord: _canMutateRecord,
                              onEditRecord: _editRecord,
                              onDeleteRecord: _deleteRecord,
                              onOpenMemory: () => _openMemoryPage(dayGroup),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// The member's scrapbook cover: a polaroid print in their 応援色 with the
/// name, total sticker, spec tickets, a first/last/companion timeline and the
/// face-enrollment entry.
class _MemberScrapbookHero extends StatelessWidget {
  final String name;
  final String groupName;
  final Color accent;
  final Color rawColor;
  final int totalCount;
  final int recordCount;
  final int mediaCount;
  final Map<String, int> specs;
  final DateTime? firstMet;
  final DateTime? lastMet;
  final int companionDays;
  final bool hasUnknownDates;
  final VoidCallback onFaceTap;
  final String Function(DateTime value) formatShortDate;
  final Widget? switcher;

  const _MemberScrapbookHero({
    required this.name,
    required this.groupName,
    required this.accent,
    required this.rawColor,
    required this.totalCount,
    required this.recordCount,
    required this.mediaCount,
    required this.specs,
    required this.firstMet,
    required this.lastMet,
    required this.companionDays,
    required this.hasUnknownDates,
    required this.onFaceTap,
    required this.formatShortDate,
    this.switcher,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final photo = DreamPalette.photo(rawColor, brightness);
    final deep = DreamPalette.photoDeep(rawColor, brightness);
    final ink = DreamPalette.onColor(photo);

    return PolaroidFrame(
      framePadding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
      photoRadius: 3,
      tapeColor: DreamPalette.tape(rawColor, brightness),
      tapeLabel: '推し',
      tapeWidth: 58,
      tapeHeight: 21,
      tapeTop: -8,
      tapeLeft: 22,
      tapeAngle: -0.12,
      photo: SizedBox(
        height: 108,
        width: double.infinity,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [photo, deep],
                ),
              ),
            ),
            Positioned(
              left: 16,
              top: 18,
              right: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 27,
                        height: 1.08,
                        fontWeight: FontWeight.w900,
                        color: ink,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  SparkleMark(
                    size: 22,
                    color: ink.withValues(alpha: 0.72),
                    variant: SparkleVariant.sparkle,
                    dot: true,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 16,
              bottom: 13,
              child: Row(
                children: [
                  for (var i = 0; i < 5; i++)
                    Container(
                      width: 4,
                      height: 24 + (i.isEven ? 0 : 6),
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: ink.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                ],
              ),
            ),
            Positioned(
              right: 16,
              bottom: 14,
              child: Text(
                firstMet == null
                    ? '还没有记下初遇'
                    : '初遇 ${formatShortDate(firstMet!)}',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: ink.withValues(alpha: 0.72),
                ),
              ),
            ),
          ],
        ),
      ),
      caption: Padding(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        groupName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '$recordCount 条记录 · $mediaCount 张存图',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                StickerBadge(
                  value: '$totalCount',
                  label: '张',
                  color: accent,
                  shape: StickerShape.burst,
                  size: 82,
                  outlineWidth: 3,
                  valueFontSize: 26,
                  labelFontSize: 9,
                  semanticLabel: '$name 共 $totalCount 张切奇',
                ),
              ],
            ),
            if (switcher != null) ...[
              const SizedBox(height: 8),
              switcher!,
            ],
            const SizedBox(height: 13),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final entry in specs.entries)
                  _SpecTicket(
                    label: entry.key,
                    value: entry.value,
                    accent: accent,
                    scheme: scheme,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: DreamPalette.wash(
                  rawColor,
                  scheme.surfaceContainerLowest,
                  brightness,
                  strength: 0.10,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: accent.withValues(alpha: 0.16),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _TimelineCell(
                      label: '初遇',
                      value:
                          firstMet == null ? '待记录' : formatShortDate(firstMet!),
                    ),
                  ),
                  _TimelineDivider(color: accent.withValues(alpha: 0.28)),
                  Expanded(
                    child: _TimelineCell(
                      label: '最近',
                      value:
                          lastMet == null ? '待记录' : formatShortDate(lastMet!),
                    ),
                  ),
                  _TimelineDivider(color: accent.withValues(alpha: 0.28)),
                  Expanded(
                    child: _TimelineCell(
                      label: '手帐天数',
                      value: '$companionDays 天',
                    ),
                  ),
                ],
              ),
            ),
            if (hasUnknownDates) ...[
              const SizedBox(height: 6),
              Text(
                '另有一组旧记录没有日期，已放在日记最末的「日期未知」页。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onFaceTap,
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(2, 7, 2, 3),
                  child: Row(
                    children: [
                      Icon(Icons.face_outlined, size: 19, color: accent),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '登记人脸',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '从照片认识这位成员，管理或清除样本',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineCell extends StatelessWidget {
  final String label;
  final String value;

  const _TimelineCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimelineDivider extends StatelessWidget {
  final Color color;

  const _TimelineDivider({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: color,
    );
  }
}

class _SpecTicket extends StatelessWidget {
  final String label;
  final int value;
  final Color accent;
  final ColorScheme scheme;

  const _SpecTicket({
    required this.label,
    required this.value,
    required this.accent,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    final fill = Color.alphaBlend(
      accent.withValues(alpha: 0.10),
      scheme.surfaceContainerLowest,
    );
    return TicketNotchEdge(
      notchRadius: 4,
      notchPosition: 0.5,
      borderRadius: BorderRadius.circular(10),
      color: fill,
      borderColor: accent.withValues(alpha: 0.22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '$value',
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w900,
                height: 1,
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One journal page for a day. The date is a printed heading, records are
/// handwritten lines and the day's photos are polaroid thumbnails; a missing
/// date is labelled explicitly instead of pretending to be 1970.
class _JournalDayCard extends StatelessWidget {
  final _RecordDayGroup dayGroup;
  final Color accent;
  final ColorScheme scheme;
  final String dateLabel;
  final String weekdayLabel;
  final List<String> activityLabels;
  final String Function(ActivityRecordModel record) recordTitle;
  final IconData Function(ActivityRecordModel record) recordIcon;
  final String Function(ActivityRecordModel record) recordSummary;
  final bool Function(ActivityRecordModel record) canMutateRecord;
  final void Function(ActivityRecordModel record) onEditRecord;
  final void Function(ActivityRecordModel record) onDeleteRecord;
  final VoidCallback onOpenMemory;

  const _JournalDayCard({
    required this.dayGroup,
    required this.accent,
    required this.scheme,
    required this.dateLabel,
    required this.weekdayLabel,
    required this.activityLabels,
    required this.recordTitle,
    required this.recordIcon,
    required this.recordSummary,
    required this.canMutateRecord,
    required this.onEditRecord,
    required this.onDeleteRecord,
    required this.onOpenMemory,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final isUnknown = dayGroup.isUnknownDate;
    final fill = isUnknown
        ? scheme.surfaceContainerLow
        : DreamPalette.wash(
            accent,
            scheme.surface,
            brightness,
            strength: 0.045,
          );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isUnknown
                  ? scheme.outlineVariant
                  : accent.withValues(alpha: 0.18),
            ),
            boxShadow: DreamPalette.pageShadow(brightness),
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (isUnknown)
                              const Padding(
                                padding: EdgeInsets.only(right: 6),
                                child: Icon(
                                  Icons.help_outline_rounded,
                                  size: 17,
                                ),
                              ),
                            Flexible(
                              child: Text(
                                dateLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          weekdayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        if (activityLabels.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 5,
                            children: [
                              for (final item in activityLabels.take(3))
                                _JournalTag(
                                  label: item,
                                  accent: accent,
                                  scheme: scheme,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  StickerBadge(
                    value: '${dayGroup.records.length}',
                    label: '条',
                    color: accent,
                    outlineWidth: 2,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    valueFontSize: 14,
                    labelFontSize: 7,
                    minWidth: 32,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (dayGroup.media.isNotEmpty)
                _mediaStrip(theme)
              else
                _emptyMedia(theme),
              const SizedBox(height: 10),
              ...dayGroup.records.map((record) {
                final canMutate = canMutateRecord(record);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Material(
                    color: scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(13),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(13),
                      onTap: canMutate ? () => onEditRecord(record) : null,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 9, 6, 9),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: Color.alphaBlend(
                                  accent.withValues(alpha: 0.12),
                                  scheme.surfaceContainerLowest,
                                ),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                recordIcon(record),
                                size: 16,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    recordTitle(record),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      height: 1.25,
                                    ),
                                  ),
                                  if (recordSummary(record).isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      recordSummary(record),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          theme.textTheme.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (canMutate)
                              PopupMenuButton<_RecordCardAction>(
                                tooltip: '记录操作',
                                padding: EdgeInsets.zero,
                                onSelected: (action) async {
                                  switch (action) {
                                    case _RecordCardAction.edit:
                                      onEditRecord(record);
                                    case _RecordCardAction.delete:
                                      onDeleteRecord(record);
                                  }
                                },
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: _RecordCardAction.edit,
                                    child: Text('编辑'),
                                  ),
                                  PopupMenuItem(
                                    value: _RecordCardAction.delete,
                                    child: Text('删除'),
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onOpenMemory,
                  icon: Icon(
                    dayGroup.mediaCount > 0
                        ? Icons.photo_library_outlined
                        : Icons.add_photo_alternate_outlined,
                    size: 17,
                  ),
                  label: Text(
                    dayGroup.mediaCount > 0
                        ? '查看当日存图 ${dayGroup.mediaCount}'
                        : '补上当日存图',
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -5,
          right: 26,
          child: Transform.rotate(
            angle: 0.10,
            child: WashiTape(
              color: DreamPalette.tape(
                isUnknown ? scheme.primary : accent,
                brightness,
              ),
              width: 44,
              height: 12,
              folds: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _mediaStrip(ThemeData theme) {
    final media = dayGroup.media;
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: media.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = media[index];
          final tilt = index.isEven ? -1.1 : 1.0;
          return Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onOpenMemory,
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 66,
                child: PolaroidFrame(
                  tilt: tilt,
                  framePadding: const EdgeInsets.fromLTRB(3, 3, 3, 3),
                  captionTop: 2,
                  captionBottom: 1,
                  shadow: false,
                  photoRadius: 1.5,
                  photo: SizedBox(
                    height: 58,
                    width: double.infinity,
                    child: item.isScan
                        ? AlbumPhotoThumb(
                            photo: AlbumPhoto.attachment(item),
                            cacheWidth: 180,
                          )
                        : Image.file(
                            File(item.path),
                            fit: BoxFit.cover,
                            cacheWidth: 180,
                            errorBuilder: (context, error, stackTrace) {
                              return ColoredBox(
                                color: scheme.surfaceContainerHigh,
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                              );
                            },
                          ),
                  ),
                  caption: Text(
                    item.mediaType.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 7,
                      height: 1,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _emptyMedia(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.06),
          scheme.surfaceContainerLowest,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accent.withValues(alpha: 0.14),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.photo_camera_back_outlined,
            size: 17,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '这一天还没存图，拍立得相册空着',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            '点下方补上',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _JournalTag extends StatelessWidget {
  final String label;
  final Color accent;
  final ColorScheme scheme;

  const _JournalTag({
    required this.label,
    required this.accent,
    required this.scheme,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.10),
          scheme.surfaceContainerLowest,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    );
  }
}

class _EmptyScrapbook extends StatelessWidget {
  final Color accent;
  final VoidCallback onQuickCount;

  const _EmptyScrapbook({
    required this.accent,
    required this.onQuickCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          SparkleMark(
            size: 28,
            color: accent,
            variant: SparkleVariant.star,
            dot: true,
          ),
          const SizedBox(height: 10),
          Text(
            '这本手帐还空着',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '先记一次切，之后这张卡片就会按日期长出手帐日记。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: onQuickCount,
            icon: const Icon(Icons.edit_note_outlined, size: 18),
            label: const Text('快捷计数'),
          ),
        ],
      ),
    );
  }
}

enum _RecordCardAction {
  edit,
  delete,
}

class _RecordDayGroup {
  /// Null means the stored records had no usable date (legacy 1970 epoch).
  final DateTime? day;
  final List<ActivityRecordModel> records;
  final List<ActivityRecordMediaModel> media;

  const _RecordDayGroup({
    required this.day,
    required this.records,
    required this.media,
  });

  bool get isUnknownDate => day == null;
  int get mediaCount => media.length;
}
