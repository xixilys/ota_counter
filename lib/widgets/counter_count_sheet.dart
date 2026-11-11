import 'dart:async';

import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../models/idol_activity_event_model.dart';
import '../models/idol_database_models.dart';
import '../services/database_service.dart';
import '../services/idol_database_service.dart';
import 'no_autofill_text_field.dart';

/// Persists a quick-count change.
///
/// [updatedCounter] holds the absolute counts the sheet now shows and
/// [baseCounter] the counts that were last confirmed as saved for the same
/// target. The saved record must contain exactly `updated - base`; comparing
/// against any other copy (for example the home page cache) double-counts or
/// drops taps when that copy is stale or a previous save is still in flight.
typedef CounterChangedCallback = Future<CounterSaveResult> Function(
  CounterModel updatedCounter,
  DateTime occurredAt, {
  String activityName,
  String venueName,
  String sessionLabel,
  CounterModel? baseCounter,
});

/// Deletes exactly one saved activity record and returns the refreshed
/// counter. Used by the quick-count undo snackbar.
typedef CounterRecordDeletedCallback = Future<CounterModel?> Function(
  int recordId,
  CounterModel beforeCounter,
);

class CounterSaveResult {
  final CounterModel counter;

  /// Id of the activity record created by this save, when one was created.
  final int? recordId;

  const CounterSaveResult({
    required this.counter,
    this.recordId,
  });
}

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

class _UndoBarData {
  final String message;
  final _PendingCounterSave? request;
  final int? recordId;

  const _UndoBarData({
    required this.message,
    this.request,
    this.recordId,
  });

  bool get canUndo => request != null && recordId != null;
}

class _PendingCounterSave {
  final String targetKey;
  final CounterModel counter;
  final CounterModel beforeCounter;
  final CounterCountField field;
  final int delta;
  final DateTime occurredAt;
  final String activityName;
  final String venueName;
  final String sessionLabel;

  const _PendingCounterSave({
    required this.targetKey,
    required this.counter,
    required this.beforeCounter,
    required this.field,
    required this.delta,
    required this.occurredAt,
    required this.activityName,
    required this.venueName,
    required this.sessionLabel,
  });
}

class CounterCountSheet extends StatefulWidget {
  final CounterModel counter;
  final List<CounterModel> allCounters;
  final CounterChangedCallback onCounterChanged;
  final CounterRecordDeletedCallback? onRecordDeleted;
  final VoidCallback? onViewDetails;

  const CounterCountSheet({
    super.key,
    required this.counter,
    required this.allCounters,
    required this.onCounterChanged,
    this.onRecordDeleted,
    this.onViewDetails,
  });

  @override
  State<CounterCountSheet> createState() => _CounterCountSheetState();
}

class _CounterCountSheetState extends State<CounterCountSheet> {
  late CounterModel _counter;
  late DateTime _occurredAt;
  late List<CounterRecordTarget> _targets;
  late String _selectedTargetKey;
  List<IdolActivityEvent> _activityEvents = [];
  String _activityName = '';
  String _venueName = '';
  String _sessionLabel = '';
  bool _enableUnsignedOptions = false;
  bool _targetsLoading = false;
  bool _activityEventsLoading = false;
  bool _showMoreSpecs = false;
  String? _activitySyncWarning;
  final List<_PendingCounterSave> _pendingCounterSaves = [];
  final Map<String, CounterModel> _lastPersistedCounters = {};
  bool _saveQueueRunning = false;
  _UndoBarData? _undoBar;
  Timer? _undoBarTimer;

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
    _lastPersistedCounters[_selectedTargetKey] = widget.counter;
    _loadUnsignedOptions();
    _loadRecordTargets();
  }

  @override
  void dispose() {
    _undoBarTimer?.cancel();
    super.dispose();
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

  String _targetKey(CounterModel counter) {
    final groupKey = _groupKey(counter.groupName);
    if (counter.personId != null) {
      return 'person:${counter.personId}|group:$groupKey';
    }
    final personName = _normalizeLookupValue(counter.personName);
    if (personName.isNotEmpty) {
      return 'person-name:$personName|group:$groupKey';
    }
    return 'group:$groupKey|name:${_normalizeLookupValue(counter.name)}';
  }

  bool _isCurrentTarget(CounterModel counter) {
    return _targetKey(counter) == _targetKey(widget.counter);
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
    return member.personName.trim();
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
      key: _targetKey(counter),
      label: labelOverride ??
          _buildTargetLabel(
            counter.groupName,
            counter.name,
            isCurrent: _isCurrentTarget(counter),
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
    if (currentPersonId != null && candidatePersonId != null) {
      return currentPersonId == candidatePersonId;
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
      personName: member.personName.trim().isEmpty
          ? _explicitCounterPersonName(widget.counter)
          : member.personName.trim(),
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
        final key = _targetKey(counter);
        targetsByKey[key] = _buildTarget(
          counter,
          labelOverride: _buildTargetLabel(
            counter.groupName,
            counter.name,
            isCurrent: _isCurrentTarget(counter),
          ),
        );
      }

      for (final member in matchedMembers) {
        final existingCounter = _findExistingCounterForMember(member);
        final targetCounter =
            existingCounter ?? _buildDraftCounterForMember(member);
        final key = _targetKey(targetCounter);
        targetsByKey[key] = _buildTarget(
          targetCounter,
          labelOverride: _buildTargetLabel(
            targetCounter.groupName,
            targetCounter.name,
            isCurrent: _isCurrentTarget(targetCounter),
          ),
        );
      }

      final nextTargets = targetsByKey.values.toList()
        ..sort((a, b) {
          final aIsCurrent = a.key == _targetKey(widget.counter);
          final bIsCurrent = b.key == _targetKey(widget.counter);
          if (aIsCurrent != bIsCurrent) {
            return aIsCurrent ? -1 : 1;
          }
          return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        });

      setState(() {
        _targets = nextTargets;
        for (final target in nextTargets) {
          _lastPersistedCounters.putIfAbsent(
            target.key,
            () => target.counter,
          );
        }
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

  Future<CounterSaveResult> _persistCounter(
    _PendingCounterSave request,
  ) async {
    return widget.onCounterChanged(
      request.counter,
      request.occurredAt,
      activityName: request.activityName,
      venueName: request.venueName,
      sessionLabel: request.sessionLabel,
      // Read at drain time: an earlier save for this target may have just
      // completed (and created the card) while this request was queued.
      baseCounter: _lastPersistedCounters[request.targetKey],
    );
  }

  bool _hasPendingSaveFor(String targetKey) {
    return _pendingCounterSaves.any((entry) => entry.targetKey == targetKey);
  }

  void _enqueueCounterSave(_PendingCounterSave request) {
    _pendingCounterSaves.add(request);
    if (!_saveQueueRunning) {
      unawaited(_drainCounterSaveQueue());
    }
  }

  Future<void> _drainCounterSaveQueue() async {
    if (_saveQueueRunning) {
      return;
    }
    _saveQueueRunning = true;

    try {
      while (_pendingCounterSaves.isNotEmpty) {
        final request = _pendingCounterSaves.removeAt(0);

        try {
          final result = await _persistCounter(request);
          _lastPersistedCounters[request.targetKey] = result.counter;
          if (!mounted) {
            continue;
          }

          final hasNewerSave = _hasPendingSaveFor(request.targetKey);
          if (!hasNewerSave) {
            setState(() {
              _replaceTargetCounter(result.counter);
              if (_selectedTargetKey == request.targetKey) {
                _counter = result.counter;
              }
            });
            if (result.recordId != null) {
              _showUndoBar(request, result.recordId!);
            }
          }
        } catch (error) {
          if (!mounted) {
            continue;
          }

          final fallbackCounter = _lastPersistedCounters[request.targetKey];
          if (!_hasPendingSaveFor(request.targetKey) &&
              fallbackCounter != null) {
            setState(() {
              _replaceTargetCounter(fallbackCounter);
              if (_selectedTargetKey == request.targetKey) {
                _counter = fallbackCounter;
              }
            });
          }
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('计数保存失败：$error')),
          );
        }
      }
    } finally {
      _saveQueueRunning = false;
      if (_pendingCounterSaves.isNotEmpty) {
        unawaited(_drainCounterSaveQueue());
      }
    }
  }

  void _showUndoBar(_PendingCounterSave request, int recordId) {
    _undoBarTimer?.cancel();
    setState(() {
      _undoBar = _UndoBarData(
        message: '${request.field.label} +${request.delta}',
        request: request,
        recordId: recordId,
      );
    });
    _undoBarTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _undoBar = null;
      });
    });
  }

  void _hideUndoBar() {
    _undoBarTimer?.cancel();
    if (_undoBar != null) {
      setState(() {
        _undoBar = null;
      });
    }
  }

  Future<void> _undoSavedRecord(
    _PendingCounterSave request,
    int recordId,
  ) async {
    final onRecordDeleted = widget.onRecordDeleted;
    if (onRecordDeleted == null) {
      return;
    }

    CounterModel? refreshed;
    try {
      refreshed = await onRecordDeleted(recordId, request.beforeCounter);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _undoBar = _UndoBarData(message: '撤销失败：$error');
        _undoBarTimer?.cancel();
        _undoBarTimer = Timer(const Duration(seconds: 3), () {
          if (!mounted) {
            return;
          }
          setState(() {
            _undoBar = null;
          });
        });
      });
      return;
    }
    if (!mounted) {
      return;
    }

    final counter = refreshed ?? request.beforeCounter;
    setState(() {
      _lastPersistedCounters[request.targetKey] = counter;
      _replaceTargetCounter(counter);
      if (_selectedTargetKey == request.targetKey) {
        _counter = counter;
      }
      _undoBar = const _UndoBarData(message: '已撤销');
      _undoBarTimer?.cancel();
      _undoBarTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) {
          return;
        }
        setState(() {
          _undoBar = null;
        });
      });
    });
  }

  Future<void> _loadActivityEvents({bool syncRemote = false}) async {
    setState(() {
      _activityEventsLoading = true;
    });

    if (syncRemote) {
      try {
        await IdolDatabaseService.syncActivityEventsFromRemoteIfStale();
        _activitySyncWarning = null;
      } catch (error) {
        // Keep using the cached roster when the upstream is unreachable.
        _activitySyncWarning = '$error';
      }
    }

    final now = DateTime.now();
    final events = await IdolDatabaseService.getActivityEvents(
      from: DateTime(now.year, now.month, now.day).subtract(
        const Duration(days: 30),
      ),
      to: DateTime(now.year, now.month, now.day).add(
        const Duration(days: 240),
      ),
      limit: 500,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _activityEvents = events;
      _activityEventsLoading = false;
    });
  }

  Future<void> _pickActivityEvent() async {
    if (_activityEvents.isEmpty && !_activityEventsLoading) {
      try {
        await _loadActivityEvents(syncRemote: true);
      } catch (error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _activityEventsLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('偶活场次加载失败：$error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }
    if (!mounted) {
      return;
    }
    final warning = _activitySyncWarning;
    _activitySyncWarning = null;
    if (warning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('演出名单更新失败，正在使用本地缓存：$warning'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    if (_activityEvents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有可用的偶活场次，请检查网络后重试'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<IdolActivityEvent>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => _ActivityEventSearchSheet(
        events: _activityEvents,
      ),
    );
    if (selected == null || !mounted) {
      return;
    }

    setState(() {
      _occurredAt = DateTime(
        selected.eventDate.year,
        selected.eventDate.month,
        selected.eventDate.day,
      );
      _activityName = selected.eventName;
      _venueName = selected.venue;
      _sessionLabel = selected.sessionLabel;
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
    final beforeCounter = _counter;
    final updatedCounter = _counter.changeCount(field, delta);
    if (updatedCounter.countForField(field) == _counter.countForField(field)) {
      return;
    }
    final targetKey = _selectedTargetKey;

    setState(() {
      _counter = updatedCounter;
      _replaceTargetCounter(updatedCounter);
    });
    _hideUndoBar();
    _enqueueCounterSave(
      _PendingCounterSave(
        targetKey: targetKey,
        counter: updatedCounter,
        beforeCounter: beforeCounter,
        field: field,
        delta: delta,
        occurredAt: _occurredAt,
        activityName: _activityName,
        venueName: _venueName,
        sessionLabel: _sessionLabel,
      ),
    );
  }

  Future<void> _editCount(CounterCountField field) async {
    final currentValue = _counter.countForField(field);
    final controller = TextEditingController(
      text: currentValue.toString(),
    );
    final nextValue = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        void submitValue() {
          final parsed = int.tryParse(controller.text.trim());
          if (parsed == null || parsed < 0) {
            return;
          }
          if (parsed < currentValue) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('不能直接减少数量，请删除对应流水后再重算计数。'),
              ),
            );
            return;
          }
          Navigator.of(dialogContext).pop(parsed);
        }

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
            onSubmitted: (_) => submitValue(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: submitValue,
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

    final delta = nextValue - currentValue;
    if (delta == 0) {
      return;
    }

    _changeCount(field, delta);
  }

  List<CounterCountField> get _visibleSpecFields {
    return CounterCountField.visibleValues(
      enableUnsigned:
          _enableUnsignedOptions || _counter.hasUnsignedCounts,
      includeGroupCut: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visibleFields = _visibleSpecFields;
    final usedFields = visibleFields
        .where((field) => _counter.countForField(field) > 0)
        .toList(growable: false);
    // A member who has never been counted still gets one easy row: 3寸.
    final primaryFields = usedFields.isEmpty
        ? [visibleFields.first]
        : usedFields;
    final moreFields = visibleFields
        .where((field) => !primaryFields.contains(field))
        .toList(growable: false);

    Widget specRow(CounterCountField field) {
      return _SpecCountRow(
        field: field,
        value: _counter.countForField(field),
        onEditValue: () => _editCount(field),
        onAddOne: () => _changeCount(field, 1),
        onAddFive: () => _changeCount(field, 5),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _counter.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontSize: 24,
                            ),
                          ),
                          if (_counter.groupName.trim().isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              _counter.groupName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            '总计 ${_counter.count}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onViewDetails != null)
                      TextButton(
                        onPressed: widget.onViewDetails,
                        child: const Text('查看详情'),
                      ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (_targetsLoading) ...[
                const SizedBox(height: 4),
                const LinearProgressIndicator(),
              ],
              if (_targets.length > 1) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _selectedTargetKey,
                  decoration: const InputDecoration(
                    labelText: '记录到团体',
                    helperText: '默认当前团体，也可以切到这个真人的其他团籍',
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
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _CompactInfoTile(
                      icon: Icons.schedule_outlined,
                      label: '记录日期',
                      value: _formatDate(_occurredAt),
                      onTap: _pickDateTime,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _CompactInfoTile(
                      icon: Icons.event_available_outlined,
                      label: '选择演出',
                      value: _activityName.isEmpty
                          ? '自动填日期和场地'
                          : [
                              _activityName,
                              if (_venueName.isNotEmpty) _venueName,
                              if (_sessionLabel.isNotEmpty) _sessionLabel,
                            ].join(' · '),
                      busy: _activityEventsLoading,
                      onTap: _pickActivityEvent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SpecGroup(
                children: [
                  for (var i = 0; i < primaryFields.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    specRow(primaryFields[i]),
                  ],
                ],
              ),
              if (moreFields.isNotEmpty) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _showMoreSpecs = !_showMoreSpecs;
                    });
                  },
                  icon: Icon(
                    _showMoreSpecs
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                  ),
                  label: Text(
                    _showMoreSpecs
                        ? '收起更多规格'
                        : '更多规格（${moreFields.length}）',
                  ),
                ),
                if (_showMoreSpecs) ...[
                  const SizedBox(height: 2),
                  _SpecGroup(
                    children: [
                      for (var i = 0; i < moreFields.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        specRow(moreFields[i]),
                      ],
                    ],
                  ),
                ],
              ],
              const SizedBox(height: 8),
              _ReadOnlyGroupCutRow(
                field: CounterCountField.groupCut,
                value: _counter.groupCutCount,
              ),
              if (_undoBar != null) ...[
                const SizedBox(height: 10),
                _CounterUndoBar(
                  data: _undoBar!,
                  onUndo: () {
                    final request = _undoBar?.request;
                    final recordId = _undoBar?.recordId;
                    if (request == null || recordId == null) {
                      return;
                    }
                    _hideUndoBar();
                    unawaited(_undoSavedRecord(request, recordId));
                  },
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityEventSearchSheet extends StatefulWidget {
  final List<IdolActivityEvent> events;

  const _ActivityEventSearchSheet({
    required this.events,
  });

  @override
  State<_ActivityEventSearchSheet> createState() =>
      _ActivityEventSearchSheetState();
}

class _ActivityEventSearchSheetState extends State<_ActivityEventSearchSheet> {
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
    final events = widget.events.where((event) {
      if (normalized.isEmpty) {
        return true;
      }
      return event.eventName.toLowerCase().contains(normalized) ||
          event.city.toLowerCase().contains(normalized) ||
          event.venue.toLowerCase().contains(normalized) ||
          event.groupLabel.toLowerCase().contains(normalized);
    }).toList(growable: false);

    return FractionallySizedBox(
      heightFactor: 0.85,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '选择偶活场次',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: '活动 / 城市 / 场地 / 团体',
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
              child: events.isEmpty
                  ? const Center(child: Text('没有匹配的场次'))
                  : ListView.builder(
                      itemCount: events.length,
                      itemBuilder: (context, index) {
                        final event = events[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(event.eventName),
                          subtitle: Text(
                            [
                              _formatDate(event.eventDate),
                              event.displaySubtitle,
                            ]
                                .where((item) => item.trim().isNotEmpty)
                                .join(' · '),
                          ),
                          onTap: () => Navigator.of(context).pop(event),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }
}

class _CounterUndoBar extends StatelessWidget {
  final _UndoBarData data;
  final VoidCallback onUndo;

  const _CounterUndoBar({
    required this.data,
    required this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                data.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (data.canUndo)
              TextButton(
                onPressed: onUndo,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.inversePrimary,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('撤销'),
              ),
          ],
        ),
      ),
    );
  }
}

class _SpecGroup extends StatelessWidget {
  final List<Widget> children;

  const _SpecGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(children: children),
    );
  }
}

class _SpecCountRow extends StatelessWidget {
  final CounterCountField field;
  final int value;
  final VoidCallback onEditValue;
  final VoidCallback onAddOne;
  final VoidCallback onAddFive;

  const _SpecCountRow({
    required this.field,
    required this.value,
    required this.onEditValue,
    required this.onAddOne,
    required this.onAddFive,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              field.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
          ),
          _CountValueChip(
            key: ValueKey<String>('quick-count-value-${field.key}'),
            value: value,
            onTap: onEditValue,
          ),
          const SizedBox(width: 8),
          _AddCountButton(
            key: ValueKey<String>('quick-add-one-${field.key}'),
            label: '+1',
            emphasized: true,
            onPressed: onAddOne,
          ),
          const SizedBox(width: 6),
          _AddCountButton(
            key: ValueKey<String>('quick-add-five-${field.key}'),
            label: '+5',
            onPressed: onAddFive,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

class _CountValueChip extends StatelessWidget {
  final int value;
  final VoidCallback onTap;

  const _CountValueChip({
    super.key,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: '点数字修改总数',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 38, minHeight: 36),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _AddCountButton extends StatelessWidget {
  final String label;
  final bool emphasized;
  final VoidCallback onPressed;

  const _AddCountButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = emphasized
        ? FilledButton.styleFrom(
            minimumSize: const Size(58, 44),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          )
        : FilledButton.styleFrom(
            backgroundColor: scheme.surface,
            foregroundColor: scheme.primary,
            minimumSize: const Size(48, 44),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.outlineVariant),
            ),
          );
    return FilledButton(
      onPressed: onPressed,
      style: style,
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class _CompactInfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool busy;
  final VoidCallback onTap;

  const _CompactInfoTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadOnlyGroupCutRow extends StatelessWidget {
  final CounterCountField field;
  final int value;

  const _ReadOnlyGroupCutRow({
    required this.field,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(field.label, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '只读',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: scheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
