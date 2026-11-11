import 'dart:convert';

import '../services/database_service.dart';
import '../services/face/face_recognition_rules.dart';
import 'activity_record_model.dart';
import 'counter_model.dart';

String chartPersonStatsKey({
  required int? personId,
  required String personName,
  required String groupName,
  required String subjectName,
}) {
  if (personId != null) {
    return 'person:$personId';
  }

  final normalizedPersonName = _normalizeLookupPart(personName);
  if (normalizedPersonName.isNotEmpty) {
    return 'person-name:$normalizedPersonName';
  }

  return 'fallback:${_normalizeLookupPart(groupName)}|${_normalizeLookupPart(subjectName)}';
}

bool isGroupCutMultiRecord(ActivityRecordModel record) {
  return record.isMulti && record.multiCountField == CounterCountField.groupCut;
}

int chartTypeFieldContribution(
  ActivityRecordModel record,
  CounterCountField field,
) {
  if (!record.isMulti) {
    // Corrections can be negative and must cancel their original counts.
    return record.countForField(field);
  }
  return record.multiCountField == field ? record.effectiveMultiQuantity : 0;
}

int chartGroupSummaryGroupCutContribution(ActivityRecordModel record) {
  if (!isGroupCutMultiRecord(record)) {
    return 0;
  }
  return record.effectiveMultiQuantity;
}

int chartGroupSummaryMultiContribution(
  ActivityRecordModel record,
) {
  // Each involved group receives the physical photo quantity.
  if (!record.isMulti || isGroupCutMultiRecord(record)) {
    return 0;
  }
  return record.effectiveMultiQuantity;
}

String _normalizeLookupPart(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return '';
  }
  return trimmed.replaceAll(
    RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
    '',
  );
}

/// A statistics-only view. Ledger records and participant snapshots are never
/// rewritten, so editing and deletion still receive the original objects.
class ChartRecordScope {
  final List<CounterModel> counters;
  final bool showHiddenCounters;
  late final List<ActivityRecordModel> records;

  ChartRecordScope({
    required this.counters,
    required List<ActivityRecordModel> records,
    required this.showHiddenCounters,
  }) {
    this.records = records.where((record) {
      if (showHiddenCounters || record.isTicket) return true;
      if (record.isCounter) {
        return resolveCounterForActivityRecord(counters, record)?.isHidden !=
            true;
      }
      return record.effectiveParticipants.isEmpty ||
          participantsFor(record).isNotEmpty;
    }).toList(growable: false);
  }

  /// Match the database projection: aliases resolving to one counter are one
  /// slot. Unresolved participants retain effectiveParticipants' identity rules.
  List<ActivityParticipant> uniqueParticipantsFor(ActivityRecordModel record) {
    final seenCounterIds = <int>{};
    return record.effectiveParticipants.where((participant) {
      final id =
          DatabaseService.resolveCounterForParticipant(counters, participant)
              ?.id;
      return id == null || seenCounterIds.add(id);
    }).toList(growable: false);
  }

  List<ActivityParticipant> participantsFor(ActivityRecordModel record) {
    return uniqueParticipantsFor(record).where((participant) {
      return showHiddenCounters ||
          DatabaseService.resolveCounterForParticipant(counters, participant)
                  ?.isHidden !=
              true;
    }).toList(growable: false);
  }

  List<ActivityRecordModel> recordsBetween(DateTime start, DateTime end) {
    return records.where((record) {
      final day = recordActivityDay(record.occurredAt);
      return !day.isBefore(start) && day.isBefore(end);
    }).toList(growable: false);
  }

  /// Only an explicit legacy linkage can identify split ledger rows as one
  /// photo event. Different dates/specs/quantities remain separate projections:
  /// editing one row must not silently reconcile or rewrite its siblings.
  List<ChartMultiEvent> multiEvents(Iterable<ActivityRecordModel> records) {
    final events = <ChartMultiEvent>[];
    final linked = <String, ChartMultiEvent>{};
    for (final record in records.where((record) => record.isMulti)) {
      final groupId = record.groupRecordId;
      if (groupId == null || groupId.trim().isEmpty) {
        events.add(ChartMultiEvent([record]));
        continue;
      }
      final key = jsonEncode([
        groupId,
        recordActivityDay(record.occurredAt).toIso8601String(),
        record.multiCountField?.key,
        record.effectiveMultiQuantity,
      ]);
      final event = linked.putIfAbsent(key, () {
        final event = ChartMultiEvent([]);
        events.add(event);
        return event;
      });
      event.records.add(record);
    }
    return events;
  }

  List<ActivityParticipant> participantsForEvent(ChartMultiEvent event) {
    // Deduplicate identities for display only. Contributions and money always
    // come from the original rows, including separate participant shares.
    final participants = <String, ActivityParticipant>{};
    for (final record in event.records) {
      for (final participant in uniqueParticipantsFor(record)) {
        final key = identityForParticipant(participant,
                fallbackGroupName: record.groupName)
            .memberKey;
        participants.putIfAbsent(key, () => participant);
      }
    }
    return participants.values.toList(growable: false);
  }

  ChartStatsIdentity identityForRecord(ActivityRecordModel record) =>
      ChartStatsIdentity(
        counter: resolveCounterForActivityRecord(counters, record),
        counterId: record.counterId,
        groupName: record.groupName,
        memberName: record.subjectName,
        personId: record.personId,
        personName: record.personName,
      );

  ChartStatsIdentity identityForParticipant(
    ActivityParticipant participant, {
    String fallbackGroupName = '',
  }) {
    final counter =
        DatabaseService.resolveCounterForParticipant(counters, participant);
    final group = participant.groupName.trim().isNotEmpty
        ? participant.groupName
        : (counter?.groupName.trim().isNotEmpty == true
            ? counter!.groupName
            : fallbackGroupName);
    return ChartStatsIdentity(
      counter: counter,
      groupName: group,
      memberName: participant.memberName,
      personId: participant.personId,
      personName: participant.personName,
    );
  }

  String memberKeyForRecord(ActivityRecordModel record) =>
      identityForRecord(record).memberKey;

  String memberKeyForParticipant(ActivityParticipant participant) =>
      identityForParticipant(participant).memberKey;

  String multiSummaryKey(ActivityRecordModel record) {
    // Use the complete, original cast, not only its visible subset. Otherwise
    // distinct events can collide when a participant is hidden.
    final identities = uniqueParticipantsFor(record)
        .map((participant) => identityForParticipant(participant,
                fallbackGroupName: record.groupName)
            .memberKey)
        .toSet()
        .toList()
      ..sort();
    return jsonEncode([
      recordActivityDay(record.occurredAt).toIso8601String(),
      record.multiCountField?.key,
      identities,
      if (identities.isEmpty) record.groupName.trim(),
    ]);
  }

  double multiParticipantAmountShare(
      ActivityRecordModel record, double amount) {
    final count = uniqueParticipantsFor(record).length;
    return count == 0 ? 0 : amount / count;
  }

  Map<String, double> multiGroupAmounts(
    ActivityRecordModel record,
    double amount,
  ) {
    final fallback =
        record.groupName.trim().isEmpty ? '未分组' : record.groupName.trim();
    if (record.effectiveParticipants.isEmpty) return {fallback: amount};
    final amounts = <String, double>{};
    // Hidden slots keep their original share; never redistribute their spend.
    final share = multiParticipantAmountShare(record, amount);
    for (final participant in participantsFor(record)) {
      final historicalGroup = identityForParticipant(participant,
              fallbackGroupName: record.groupName)
          .groupName;
      final group = historicalGroup.isEmpty ? '未分组' : historicalGroup;
      amounts[group] = (amounts[group] ?? 0) + share;
    }
    return amounts;
  }
}

/// A photo-count projection, never a replacement ledger record. Every source
/// row stays available for money, member contributions, media and mutations.
class ChartMultiEvent {
  final List<ActivityRecordModel> records;

  ChartMultiEvent(this.records);

  ActivityRecordModel get representative => records.first;
  int get quantity => representative.effectiveMultiQuantity;
  CounterCountField? get field => representative.multiCountField;
  DateTime get day => recordActivityDay(representative.occurredAt);

  String? get linkedSummaryKey {
    final id = representative.groupRecordId;
    if (id == null || id.trim().isEmpty) return null;
    return jsonEncode(
        ['legacy-multi', id, day.toIso8601String(), field?.key, quantity]);
  }
}

/// Historical IDs/names are evidence, not labels to replace with today's
/// counter metadata. Only compatible missing identity fields may be enriched.
class ChartStatsIdentity {
  final CounterModel? counter;
  final int? counterId;
  final String groupName;
  final String memberName;
  final int? historicalPersonId;
  final String historicalPersonName;

  ChartStatsIdentity({
    required this.counter,
    int? counterId,
    required String groupName,
    required this.memberName,
    required int? personId,
    required String personName,
  })  : counterId = counter?.id ?? counterId,
        groupName = groupName.trim(),
        historicalPersonId = personId != null && personId > 0 ? personId : null,
        historicalPersonName = personName.trim();

  bool get canEnrichFromCounter {
    final current = counter;
    if (current == null) return false;
    if (historicalPersonId != null) {
      // An unlinked counter is not confirmation of the historical person.
      return historicalPersonId == current.personId;
    }
    if (historicalPersonName.isEmpty) return true;
    final currentName =
        current.personName.trim().isEmpty ? current.name : current.personName;
    return _normalizeLookupPart(historicalPersonName) ==
        _normalizeLookupPart(currentName);
  }

  int? get personId =>
      historicalPersonId ?? (canEnrichFromCounter ? counter?.personId : null);

  String get personName => historicalPersonName.isNotEmpty
      ? historicalPersonName
      : (canEnrichFromCounter ? counter!.personName.trim() : '');

  String get personKey {
    if (personId != null) return 'person:$personId';
    if (personName.isNotEmpty) {
      return 'person-name:${_normalizeLookupPart(personName)}';
    }
    if (canEnrichFromCounter && counterId != null) return 'counter:$counterId';
    return chartPersonStatsKey(
        personId: null,
        personName: '',
        groupName: groupName,
        subjectName: memberName);
  }

  // A stable counter is a linkage, not permission to erase a historical group
  // seat or a previous person's explicit identity.
  String get memberKey => jsonEncode([
        groupName.toLowerCase(),
        counterId == null ? personKey : 'counter:$counterId',
        personId != null || personName.isNotEmpty ? personKey : '',
      ]);

  String get memberLabel => canEnrichFromCounter &&
          groupName.toLowerCase() == counter!.groupName.trim().toLowerCase()
      ? counter!.name
      : memberName;

  String get personLabel => personName.isNotEmpty ? personName : memberLabel;
}

String chartTicketSummaryKey(ActivityRecordModel record) => jsonEncode([
      recordActivityDay(record.occurredAt).toIso8601String(),
      record.resolvedActivityName,
      record.resolvedVenueName,
      record.sessionLabel.trim(),
    ]);
