import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/chart_stats_helpers.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/chart_page.dart';

void main() {
  final visible = CounterModel(
      id: 1, name: 'A', groupName: 'G1', personId: 101, color: '#ffffff');
  final hidden = CounterModel(
      id: 2,
      name: 'B',
      groupName: 'G2',
      personId: 102,
      color: '#ffffff',
      isHidden: true);
  const a =
      ActivityParticipant(memberName: 'A', groupName: 'G1', personId: 101);
  const b =
      ActivityParticipant(memberName: 'B', groupName: 'G2', personId: 102);
  const unknown = ActivityParticipant(memberName: '历史成员', groupName: 'G3');

  ActivityRecordModel multi(
    List<ActivityParticipant> cast, {
    DateTime? at,
    CounterCountField field = CounterCountField.threeInch,
  }) =>
      ActivityRecordModel.multiCut(
          participants: cast,
          field: field,
          occurredAt: at ?? DateTime(2026, 1, 1),
          quantity: 2,
          totalPrice: 120);

  ChartRecordScope scope(List<ActivityRecordModel> records,
          {bool show = false, List<CounterModel>? counters}) =>
      ChartRecordScope(
          counters: counters ?? [visible, hidden],
          records: records,
          showHiddenCounters: show);

  for (final boundary in [DateTime(2026, 1, 1), DateTime(2026, 3, 1)]) {
    test('activity-day range includes date-only but moves 05:59 at $boundary',
        () {
      final midnight = multi([a], at: boundary);
      final early =
          multi([a], at: boundary.add(const Duration(hours: 5, minutes: 59)));
      final six = multi([a], at: boundary.add(const Duration(hours: 6)));
      final view = scope([midnight, early, six]);
      for (final period in [
        StatsScope.day,
        StatsScope.week,
        StatsScope.month,
        if (boundary.month == 1) StatsScope.year
      ]) {
        final current = period.rangeFor(boundary)!;
        final previous =
            period.rangeFor(boundary.subtract(const Duration(days: 1)))!;
        // A week can contain both adjacent days; test the actual range, too.
        if (previous.start == current.start) continue;
        expect(
            view.recordsBetween(current.start, current.end), [midnight, six]);
        expect(view.recordsBetween(previous.start, previous.end), [early]);
      }
      expect(
          view.recordsBetween(boundary, boundary.add(const Duration(days: 1))),
          [midnight, six]);
    });
  }

  test('Monday 05:59 stays in the previous week', () {
    final monday = DateTime(2026, 6, 1);
    final early =
        multi([a], at: monday.add(const Duration(hours: 5, minutes: 59)));
    final range = StatsScope.week.rangeFor(monday)!;
    expect(scope([early]).recordsBetween(range.start, range.end), isEmpty);
  });

  test(
      'hidden preference filters only proven hidden records and original objects survive',
      () {
    final one = ActivityRecordModel.counterAdjustment(
        counter: visible,
        occurredAt: DateTime(2026, 1, 1),
        deltas: {CounterCountField.threeInch: 2});
    final two = ActivityRecordModel.counterAdjustment(
        counter: hidden,
        occurredAt: one.occurredAt,
        deltas: {CounterCountField.threeInch: 3});
    final historical = one.copyWith(
        counterId: 999, subjectName: '未知', groupName: '失联', personId: 999);
    final partial = multi([a, b]);
    final allHidden = multi([b]);
    final unresolved = multi([b, unknown]);
    final empty =
        multi([], field: CounterCountField.groupCut).copyWith(groupName: '空团');
    final ticket =
        ActivityRecordModel.ticket(eventName: '演出', occurredAt: one.occurredAt);
    final records = [
      one,
      two,
      historical,
      partial,
      allHidden,
      unresolved,
      empty,
      ticket
    ];
    final closed = scope(records);
    expect(
        closed.records, [one, historical, partial, unresolved, empty, ticket]);
    expect(identical(closed.records[2], partial), isTrue);
    expect(partial.effectiveParticipants, [a, b]);
    expect(closed.participantsFor(partial), [a]);
    expect(closed.participantsFor(unresolved), [unknown]);
    expect(partial.multiTotalCount, 2);
    expect(partial.totalAmount, 120);
    expect(closed.multiGroupAmounts(partial, 120), {'G1': 60});
    expect(closed.multiGroupAmounts(unresolved, 120), {'G3': 60});
    expect(closed.multiGroupAmounts(allHidden, 120), isEmpty);
    final opened = scope(records, show: true);
    expect(opened.records, records);
    expect(opened.participantsFor(partial), [a, b]);
    expect(opened.multiGroupAmounts(partial, 120), {'G1': 60, 'G2': 60});
  });

  test('mixed name and person-id aliases resolve to one pre-filter slot', () {
    const byName = ActivityParticipant(memberName: 'A', groupName: 'G1');
    const byId =
        ActivityParticipant(memberName: '旧别名', groupName: 'G1', personId: 101);
    final record = multi([byName, byId, b]);
    expect(record.effectiveParticipants, hasLength(3));
    final closed = scope([record]);
    expect(closed.uniqueParticipantsFor(record), [byName, b]);
    expect(closed.participantsFor(record), [byName]);
    expect(closed.multiParticipantAmountShare(record, 120), 60);
    expect(closed.multiGroupAmounts(record, 120), {'G1': 60});
    final opened = scope([record], show: true);
    expect(opened.participantsFor(record), [byName, b]);
    expect(opened.multiGroupAmounts(record, 120), {'G1': 60, 'G2': 60});
    expect(closed.multiSummaryKey(record),
        closed.multiSummaryKey(multi([byName, b])));
    expect(record.effectiveParticipants, hasLength(3));
  });

  for (final reverse in [false, true]) {
    test(
        'person enrichment and empty-group fallback ignore alias order=$reverse',
        () {
      final currentA = visible.copyWith(personName: '真人A');
      const nameOnly = ActivityParticipant(memberName: 'A', groupName: 'G1');
      const identified = ActivityParticipant(memberName: '旧别名', personId: 101);
      final record = multi(
          reverse ? [identified, nameOnly, b] : [nameOnly, identified, b]);
      final view = scope([record], counters: [currentA, hidden], show: true);
      expect(record.effectiveParticipants, hasLength(3));
      expect(view.uniqueParticipantsFor(record), hasLength(2));
      final selectedA = view.uniqueParticipantsFor(record).first;
      final single = ActivityRecordModel.counterAdjustment(
          counter: currentA,
          occurredAt: record.occurredAt,
          deltas: {CounterCountField.threeInch: 2});
      expect(view.identityForParticipant(selectedA).personKey,
          view.identityForRecord(single).personKey);
      expect(view.multiGroupAmounts(record, 120), {'G1': 60, 'G2': 60});
      expect(record.effectiveParticipants.first.groupName, reverse ? '' : 'G1');
    });
  }

  test(
      'historical group and explicit identity survive current counter metadata',
      () {
    final current =
        visible.copyWith(groupName: 'G2', personId: 202, personName: '新人');
    final view = scope([], counters: [current]);
    final old = ActivityRecordModel.counterAdjustment(
        counter: visible.copyWith(personName: '旧人'),
        occurredAt: DateTime(2026),
        deltas: {CounterCountField.threeInch: 2});
    final recent = ActivityRecordModel.counterAdjustment(
        counter: current,
        occurredAt: old.occurredAt,
        deltas: {CounterCountField.threeInch: 3});
    expect(view.identityForRecord(old).groupName, 'G1');
    expect(view.identityForRecord(old).personKey, 'person:101');
    expect(view.identityForRecord(old).personLabel, '旧人');
    expect(view.identityForRecord(recent).personKey, 'person:202');
    expect(
        view.memberKeyForRecord(old), isNot(view.memberKeyForRecord(recent)));
    final nameOnlyOld = ActivityRecordModel(
        type: ActivityRecordType.counter,
        counterId: current.id,
        subjectName: 'A',
        groupName: 'G2',
        personName: '旧人',
        totalAmount: 0,
        occurredAt: old.occurredAt);
    expect(view.identityForRecord(nameOnlyOld).personId, isNull);
    expect(view.identityForRecord(nameOnlyOld).personKey, 'person-name:旧人');
    expect(view.identityForRecord(nameOnlyOld).memberLabel, 'A');
    expect(view.memberKeyForRecord(nameOnlyOld),
        isNot(view.memberKeyForRecord(recent)));
    final compatible = nameOnlyOld.copyWith(personName: '新人');
    expect(view.identityForRecord(compatible).personKey, 'person:202');
  });

  test('unlinking current person preserves explicit historical identity labels',
      () {
    final unlinked =
        CounterModel(id: 1, name: '新成员', groupName: 'G1', color: '#ffffff');
    final historical = ActivityRecordModel(
        type: ActivityRecordType.counter,
        counterId: 1,
        subjectName: '旧成员',
        groupName: 'G1',
        personId: 101,
        occurredAt: DateTime(2026),
        totalAmount: 0);
    final view = scope([historical], counters: [unlinked]);
    final identity = view.identityForRecord(historical);
    expect(identity.canEnrichFromCounter, isFalse);
    expect(identity.personKey, 'person:101');
    expect(identity.memberLabel, '旧成员');
    expect(identity.personLabel, '旧成员');
    // With no historical identity, the existing alias enrichment is still valid.
    final unidentified = ActivityRecordModel(
        type: ActivityRecordType.counter,
        counterId: 1,
        subjectName: '别名',
        groupName: 'G1',
        occurredAt: historical.occurredAt,
        totalAmount: 0);
    final alias = view.identityForRecord(unidentified);
    expect(alias.canEnrichFromCounter, isTrue);
    expect(alias.memberLabel, '新成员');
    expect(alias.personKey, isNot(identity.personKey));
  });

  test('empty group cuts keep their entire price with a named or unnamed group',
      () {
    final empty = multi([], field: CounterCountField.groupCut);
    expect(scope([empty]).multiGroupAmounts(empty, 120), {'未分组': 120});
    final named = empty.copyWith(groupName: '空团');
    expect(scope([named]).multiGroupAmounts(named, 120), {'空团': 120});
  });

  test(
      'member keys unify renamed records but separate equal names with different IDs',
      () {
    final renamed = visible.copyWith(name: '改名后');
    final old = ActivityRecordModel.counterAdjustment(
        counter: visible,
        occurredAt: DateTime(2026),
        deltas: {CounterCountField.threeInch: 2});
    final recent = ActivityRecordModel.counterAdjustment(
        counter: renamed,
        occurredAt: old.occurredAt,
        deltas: {CounterCountField.threeInch: 3});
    final otherCounter = renamed.copyWith(id: 3, personId: 103);
    final other = ActivityRecordModel.counterAdjustment(
        counter: otherCounter,
        occurredAt: old.occurredAt,
        deltas: {CounterCountField.threeInch: 4});
    final view = scope([old, recent, other], counters: [renamed, otherCounter]);
    expect(view.memberKeyForRecord(old), view.memberKeyForRecord(recent));
    expect(view.memberKeyForRecord(old), isNot(view.memberKeyForRecord(other)));
    expect(view.memberKeyForRecord(old), view.memberKeyForParticipant(a));
    final totals = <String, int>{};
    for (final record in view.records) {
      final key = view.memberKeyForRecord(record);
      totals[key] = (totals[key] ?? 0) + record.counterCountTotal;
    }
    expect(totals,
        {view.memberKeyForRecord(old): 5, view.memberKeyForRecord(other): 4});
    final orphanView = scope([], counters: []);
    expect(orphanView.memberKeyForRecord(old),
        isNot(orphanView.memberKeyForRecord(old.copyWith(counterId: 999))));
    expect(
        orphanView.memberKeyForParticipant(a),
        isNot(orphanView.memberKeyForParticipant(const ActivityParticipant(
            memberName: 'A', groupName: 'G1', personId: 999))));
    expect(
        orphanView.memberKeyForParticipant(unknown),
        isNot(orphanView.memberKeyForParticipant(
            const ActivityParticipant(memberName: '历史成员', groupName: '别团'))));
  });

  test('multi summary uses full unordered identities, spec and activity day',
      () {
    const c = ActivityParticipant(memberName: 'C', groupName: 'G3');
    const d = ActivityParticipant(memberName: 'D', groupName: 'G3');
    final first = multi([a, b, c]);
    final collided = multi([a, b, d]);
    final reversed = multi([c, b, a]);
    final differentSpec = multi([a, b, c], field: CounterCountField.fiveInch);
    final early = multi([a, b, c], at: DateTime(2026, 1, 2, 5, 59));
    final view = scope([]);
    expect(first.multiDisplayName, collided.multiDisplayName);
    expect(view.multiSummaryKey(first), isNot(view.multiSummaryKey(collided)));
    expect(view.multiSummaryKey(first), view.multiSummaryKey(reversed));
    expect(view.multiSummaryKey(first),
        isNot(view.multiSummaryKey(differentSpec)));
    expect(view.multiSummaryKey(first), view.multiSummaryKey(early));
    expect(view.multiSummaryKey(first),
        scope([], show: true).multiSummaryKey(first));
    final empty = multi([], field: CounterCountField.groupCut);
    expect(view.multiSummaryKey(empty.copyWith(groupName: 'G1')),
        isNot(view.multiSummaryKey(empty.copyWith(groupName: 'G2'))));
  });

  test(
      'ticket summaries separate venues and sessions, combine types on the activity day',
      () {
    final ticket = ActivityRecordModel.ticket(
        eventName: '巡演',
        venueName: '场馆X',
        sessionLabel: '夜场',
        occurredAt: DateTime(2025, 12, 31),
        ticketType: '预售');
    expect(chartTicketSummaryKey(ticket),
        isNot(chartTicketSummaryKey(ticket.copyWith(venueName: '场馆Y'))));
    expect(chartTicketSummaryKey(ticket),
        isNot(chartTicketSummaryKey(ticket.copyWith(sessionLabel: '午场'))));
    expect(
        chartTicketSummaryKey(ticket),
        chartTicketSummaryKey(ticket.copyWith(
            occurredAt: DateTime(2026, 1, 1, 5, 59), ticketType: '现场')));
    expect(
        chartTicketSummaryKey(ticket),
        isNot(chartTicketSummaryKey(
            ticket.copyWith(occurredAt: DateTime(2026, 1, 1, 6)))));
  });
}
