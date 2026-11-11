import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/chart_stats_helpers.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/pages/chart_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';

import 'chart_page_statistics_test.dart'
    show component, section, expectSummary, openChart;
import 'support/isolated_test_databases.dart';
import 'unassigned_group_cut_edit_test.dart'
    show settleDatabaseWidgets, textField;

// Synthetic legacy shape, not copied from a private backup. Each source row
// stores one member, their full contribution and only their own ¥60 share.
ActivityRecordModel legacyRow(
  int id,
  String member, {
  String? groupId = 'linked-photo',
  String group = 'G',
  CounterCountField field = CounterCountField.threeInch,
  DateTime? at,
}) {
  final row = ActivityRecordModel.multiCut(
    id: id,
    participants: [ActivityParticipant(memberName: member, groupName: group)],
    field: field,
    occurredAt: at ?? activityDayOf(DateTime.now()),
    quantity: 1,
    totalPrice: 60,
  ).toMap();
  row['group_record_id'] = groupId;
  row['multi_participants_json'] = null; // old primary/secondary-name fallback
  return ActivityRecordModel.fromMap(row);
}

void main() {
  setUpAll(() async => useIsolatedTestDatabases());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
  });

  ChartRecordScope view(
    List<ActivityRecordModel> records, {
    List<CounterModel> counters = const [],
    bool showHidden = true,
  }) =>
      ChartRecordScope(
          counters: counters, records: records, showHiddenCounters: showHidden);

  test(
      'legacy linkage round-trips snake/camel keys and copyWith without losing rows',
      () {
    final first = legacyRow(1, 'A', groupId: ' exact-id ');
    final second = legacyRow(2, 'B', groupId: ' exact-id ');
    expect(first.groupRecordId, ' exact-id ');
    expect(first.copyWith(note: '编辑').toMap()['group_record_id'], ' exact-id ');
    final camel = first.toMap()..remove('group_record_id');
    camel['groupRecordId'] = 'camel';
    expect(ActivityRecordModel.fromMap(camel).groupRecordId, 'camel');
    final scope = view([first, second]);
    final event = scope.multiEvents(scope.records).single;
    expect(event.quantity, 1);
    expect(event.records, [first, second]);
    expect(identical(event.records.first, first), isTrue);
    expect(scope.records.map((r) => r.id), [1, 2]);
    expect(
        scope.participantsForEvent(event).map((p) => p.memberName), ['A', 'B']);
    expect(
        scope.records.fold<int>(0, (n, r) => n + r.multiContributionTotal), 2);
    expect(scope.records.map((r) => r.multiParticipantAmountShare), [60, 60]);
    expect(scope.records.fold<double>(0, (n, r) => n + r.totalAmount), 120);
  });

  test('same day and cast never link ordinary, empty-id or independent events',
      () {
    final a = legacyRow(1, 'A');
    final b = legacyRow(2, 'B');
    final independent = [
      a.copyWith(groupRecordId: 'other'),
      b.copyWith(groupRecordId: 'other'),
    ];
    final ordinary = ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G')
        ],
        field: CounterCountField.threeInch,
        occurredAt: a.occurredAt,
        totalPrice: 120);
    final records = [
      a,
      b,
      ...independent,
      ordinary,
      ordinary.copyWith(id: 8),
      legacyRow(9, 'A', groupId: null),
      legacyRow(10, 'B', groupId: ''),
      legacyRow(11, 'B', groupId: '  ')
    ];
    final scope = view(records);
    final events = scope.multiEvents(scope.records);
    expect(events, hasLength(7));
    expect(events.fold<int>(0, (n, e) => n + e.quantity), 7);
    expect(events[0].linkedSummaryKey, isNot(events[1].linkedSummaryKey));
    expect(events[2].linkedSummaryKey, isNull);
    expect(scope.multiSummaryKey(ordinary),
        scope.multiSummaryKey(ordinary.copyWith(id: 8)));
    expect(scope.records, records);
  });

  test('do not reconcile conflicting date, spec or quantity within a linked id',
      () {
    final a = legacyRow(1, 'A', at: DateTime(2026, 1, 1));
    final records = [
      a,
      legacyRow(2, 'B', at: a.occurredAt),
      legacyRow(3, 'C', at: DateTime(2026, 1, 2)),
      legacyRow(4, 'D', at: a.occurredAt, field: CounterCountField.fiveInch),
      legacyRow(5, 'E', at: a.occurredAt)
          .copyWith(multiCutQuantity: 2, threeInchCount: 2)
    ];
    final scope = view(records);
    expect(
        scope.multiEvents(scope.records).map((e) => e.quantity), [1, 1, 1, 2]);
    for (final period in [
      StatsScope.day,
      StatsScope.week,
      StatsScope.month,
      StatsScope.year
    ]) {
      final range = period.rangeFor(a.occurredAt)!;
      final filtered = scope.recordsBetween(range.start, range.end);
      expect(scope.multiEvents(filtered).fold<int>(0, (n, e) => n + e.quantity),
          period == StatsScope.day ? 4 : 5);
    }
  });

  test('opening balances remain ordinary counts even with matching group ids',
      () {
    final row = legacyRow(1, 'A').toMap()
      ..['record_type'] = 'counter'
      ..['is_system_adjustment'] = 1
      ..['three_inch_count'] = 689;
    final balance = ActivityRecordModel.fromMap(row);
    final scope = view([
      balance,
      balance.copyWith(id: 2),
      legacyRow(3, 'A'),
      legacyRow(4, 'B')
    ]);
    expect(
        scope.records
            .where((r) => r.isCounter)
            .fold<int>(0, (n, r) => n + r.counterCountTotal),
        1378);
    expect(scope.multiEvents(scope.records).single.quantity, 1);
  });

  for (final hiddenCount in [0, 1, 2]) {
    for (final showHidden in [false, true]) {
      test(
          'linked rows hidden=$hiddenCount show=$showHidden keep visible shares',
          () {
        final records = [legacyRow(1, 'A'), legacyRow(2, 'B')];
        final counters = [
          for (var i = 0; i < 2; i++)
            CounterModel(
                id: i + 1,
                name: i == 0 ? 'A' : 'B',
                groupName: 'G',
                color: '#ffffff',
                isHidden: i < hiddenCount)
        ];
        final scope = view(records, counters: counters, showHidden: showHidden);
        final visible = showHidden ? 2 : 2 - hiddenCount;
        expect(scope.records, hasLength(visible));
        expect(
            scope.multiEvents(scope.records), hasLength(visible == 0 ? 0 : 1));
        expect(scope.records.fold<double>(0, (n, r) => n + r.totalAmount),
            visible * 60);
        expect(scope.records.expand(scope.participantsFor), hasLength(visible));
        expect(
            scope.records.map((r) => scope.multiGroupAmounts(r, r.totalAmount)),
            everyElement({'G': 60}));
        expect(records.map((r) => r.effectiveParticipants.single.memberName),
            ['A', 'B']);
      });
    }
  }

  testWidgets(
      'separate linked ids and ordinary multis keep their own counts and summaries',
      (tester) async {
    final day = activityDayOf(DateTime.now());
    await tester.runAsync(() async {
      for (final groupId in ['first', 'second']) {
        await DatabaseService.insertActivityRecordWithCounterImpact(
            legacyRow(1, 'A', groupId: groupId));
        await DatabaseService.insertActivityRecordWithCounterImpact(
            legacyRow(2, 'B', groupId: groupId));
      }
      for (var i = 0; i < 2; i++) {
        await DatabaseService.insertActivityRecordWithCounterImpact(
            ActivityRecordModel.multiCut(
                participants: const [
              ActivityParticipant(memberName: 'A', groupName: 'G'),
              ActivityParticipant(memberName: 'B', groupName: 'G')
            ],
                field: CounterCountField.threeInch,
                occurredAt: day,
                totalPrice: 120));
      }
    });
    await openChart(tester);
    expectSummary('记录数', '6');
    expectSummary('多人切总数', '4');
    expectSummary('切奇合计', '4');
    expectSummary('总金额', '¥480');
    final detail =
        tester.widget(component('_CalendarDayDetailCard')) as dynamic;
    expect(detail.summary.cutCount, 4);
    expect(detail.summary.recordCount, 6);
    expect(find.descendant(of: section('团体统计'), matching: find.text('贡献 4')),
        findsOneWidget);
    expect(find.descendant(of: section('多人切'), matching: find.byType(ListTile)),
        findsNWidgets(3));
    expect(
        find.descendant(of: section('多人切'), matching: find.text('1 次\n¥120')),
        findsNWidgets(2));
    expect(
        find.descendant(of: section('多人切'), matching: find.text('2 次\n¥240')),
        findsOneWidget);
    final members = section('成员贡献');
    expect(find.descendant(of: members, matching: find.text('4')),
        findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cross-group linked event counts once in each involved group, not once per row',
      (tester) async {
    await tester.runAsync(() async {
      await DatabaseService.insertActivityRecordWithCounterImpact(
          legacyRow(1, 'A', group: 'G1'));
      await DatabaseService.insertActivityRecordWithCounterImpact(
          legacyRow(2, 'B', group: 'G2'));
    });
    await openChart(tester);
    expectSummary('多人切总数', '1');
    expectSummary('总金额', '¥120');
    final groups = section('团体统计');
    expect(find.descendant(of: groups, matching: find.text('贡献 1')),
        findsNWidgets(2));
    expect(find.descendant(of: groups, matching: find.text('¥60')),
        findsNWidgets(2));
    expect(find.descendant(of: section('多人切'), matching: find.text('B × A')),
        findsOneWidget);
    expect(
        find.descendant(of: section('多人切'), matching: find.text('1 次\n¥120')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'chart edit and delete keep original row IDs and refresh the linked projection',
      (tester) async {
    Future<void> settleChart() async {
      await settleDatabaseWidgets(tester);
      await tester.runAsync(() async {
        for (var i = 0;
            i < 200 && component('_CalendarDayDetailCard').evaluate().isEmpty;
            i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(component('_CalendarDayDetailCard'), findsOneWidget);
    }

    final ids = <int>[];
    late List<ActivityRecordModel> before;
    await tester.runAsync(() async {
      await IdolDatabaseService.initializeBuiltInDataIfNeeded();
      ids.add(await DatabaseService.insertActivityRecordWithCounterImpact(
          legacyRow(1, 'A')));
      ids.add(await DatabaseService.insertActivityRecordWithCounterImpact(
          legacyRow(2, 'B')));
      before = await DatabaseService.getActivityRecords();
    });
    await openChart(tester);
    Finder rowA() => find.ancestor(
        of: find.descendant(of: section('流水明细'), matching: find.text('A')),
        matching: find.byType(ListTile));
    await tester
        .tap(find.descendant(of: rowA(), matching: find.byTooltip('记录操作')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await settleDatabaseWidgets(tester);
    expect(find.byType(AddActivityRecordDialog), findsOneWidget);
    await tester.ensureVisible(textField('备注'));
    await tester.enterText(textField('备注'), '仅编辑A');
    await tester.tap(find.text('保存修改'));
    await settleChart();
    expect(find.byType(AddActivityRecordDialog), findsNothing);
    final after = (await tester.runAsync(DatabaseService.getActivityRecords))!;
    expect(after, hasLength(2));
    for (final original in before) {
      expect(
          after.singleWhere((r) => r.id == original.id).toMap(),
          original.toMap()
            ..['note'] = original.id == ids.first ? '仅编辑A' : original.note);
    }
    expectSummary('记录数', '2');
    expectSummary('多人切总数', '1');
    expectSummary('总金额', '¥120');
    expect(
        (tester.widget(component('_CalendarDayDetailCard')) as dynamic)
            .summary
            .cutCount,
        1);
    await tester
        .tap(find.descendant(of: rowA(), matching: find.byTooltip('记录操作')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await settleChart();
    final remaining =
        (await tester.runAsync(DatabaseService.getActivityRecords))!;
    expect(remaining.single.toMap(),
        before.singleWhere((r) => r.id == ids.last).toMap());
    expectSummary('记录数', '1');
    expectSummary('多人切总数', '1');
    expectSummary('总金额', '¥60');
    final counters = (await tester.runAsync(DatabaseService.getCounters))!;
    expect(counters.singleWhere((c) => c.name == 'A').threeInchCount, 0);
    expect(counters.singleWhere((c) => c.name == 'B').threeInchCount, 1);
    expect(tester.takeException(), isNull);
  });

  for (final field in [
    CounterCountField.threeInch,
    CounterCountField.groupCut
  ]) {
    for (final showHidden in [false, true]) {
      testWidgets(
          'linked $field showHidden=$showHidden counts one in all rendered statistics',
          (tester) async {
        SharedPreferences.setMockInitialValues(
            {'show_hidden_counters': showHidden});
        final ids = <int>[];
        await tester.runAsync(() async {
          await DatabaseService.insertCounter(CounterModel(
              name: 'B', groupName: 'G', color: '#ffffff', isHidden: true));
          for (final row in [
            legacyRow(1, 'A', field: field),
            legacyRow(2, 'B', field: field)
          ]) {
            ids.add(await DatabaseService.insertActivityRecordWithCounterImpact(
                row));
          }
        });
        await openChart(tester);
        expectSummary('记录数', showHidden ? '2' : '1');
        expectSummary('多人切总数', '1');
        expectSummary('切奇合计', '1');
        expectSummary('总金额', showHidden ? '¥120' : '¥60');
        final detail =
            tester.widget(component('_CalendarDayDetailCard')) as dynamic;
        expect(detail.summary.cutCount, 1);
        expect(detail.summary.recordCount, showHidden ? 2 : 1);
        expect(detail.summary.amount, showHidden ? 120 : 60);
        expect((detail.records as List<ActivityRecordModel>).map((r) => r.id),
            showHidden ? unorderedEquals(ids) : [ids.first]);
        // Field summary uses short labels and an independent quantity text.
        expect(find.descendant(of: section('规格汇总'), matching: find.text('1')),
            findsOneWidget);
        expect(
            find.descendant(of: section('团体统计'), matching: find.text('贡献 1')),
            findsOneWidget);
        expect(
            find.descendant(
                of: section('团体统计'),
                matching: find.text(showHidden ? '¥120' : '¥60')),
            findsOneWidget);
        final multi = section('多人切');
        expect(
            find.descendant(
                of: multi, matching: find.text(showHidden ? 'B × A' : 'A')),
            findsOneWidget);
        expect(
            find.descendant(
                of: multi,
                matching: find.text(showHidden ? '1 次\n¥120' : '1 次\n¥60')),
            findsOneWidget);
        expect(
            find.descendant(
                of: multi,
                matching: find.textContaining(showHidden ? '2 人' : '1 人')),
            findsOneWidget);
        // Contributions must remain per source row, in both membership modes.
        for (final mode in ['按团籍', '按真人']) {
          await tester.tap(find.text(mode));
          await tester.pumpAndSettle();
          final members = section(mode == '按团籍' ? '成员贡献' : '真人贡献');
          expect(find.descendant(of: members, matching: find.text('1')),
              showHidden ? findsNWidgets(2) : findsOneWidget);
          expect(
              tester
                  .widgetList<LinearProgressIndicator>(find.descendant(
                      of: members,
                      matching: find.byType(LinearProgressIndicator)))
                  .map((p) => p.value),
              showHidden ? [0.5, 0.5] : [1.0]);
        }
        for (final label in ['周统计', '月统计', '年统计', '全部', '日统计']) {
          await tester.tap(find.text(label));
          await tester.pumpAndSettle();
          expectSummary('多人切总数', '1');
          expectSummary('总金额', showHidden ? '¥120' : '¥60');
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
