import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/widgets/counter_card.dart';
import 'package:ota_counter/widgets/counter_count_sheet.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  testWidgets('counter card breakdown keeps group cut in the totals', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
      threeInchCount: 2,
      fiveInchCount: 1,
      threeInchShukudaiCount: 4,
      fiveInchShukudaiCount: 5,
      groupCutCount: 3,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              child: CounterCard(
                counter: counter,
                totalCount: counter.count,
                breakdownEntries: const [
                  CounterCountBadgeData(label: '3寸', value: 2),
                  CounterCountBadgeData(label: '5寸', value: 1),
                  CounterCountBadgeData(label: '3寸宿', value: 4),
                  CounterCountBadgeData(label: '5寸宿', value: 5),
                  CounterCountBadgeData(label: '团切', value: 3),
                ],
                percentage: 0.5,
                onTap: () {},
                onDelete: () {},
                onEdit: () {},
                gridColumns: 2,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('3寸'), findsOneWidget);
    expect(find.text('5寸'), findsOneWidget);
    expect(find.text('3寸宿'), findsOneWidget);
    expect(find.text('5寸宿'), findsOneWidget);
    expect(find.text('团切'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('home card breakdown adds up to the card total', () {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
      threeInchCount: 7,
      fiveInchCount: 2,
      unsignedThreeInchCount: 3,
      threeInchShukudaiCount: 1,
      groupCutCount: 4,
    );

    final entries = buildHomeBreakdownEntries(counter, const {'拍立得': 2});
    final tileTotal = entries.fold<int>(0, (sum, entry) => sum + entry.value);

    expect(tileTotal, counter.count + 2);
    expect(
      entries.map((entry) => entry.label),
      containsAll(<String>['3寸', '5寸', '3寸宿', '5寸宿', '团切', '拍立得']),
    );
  });

  testWidgets('counter sheet shows group cut as read only', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
      groupCutCount: 4,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = "",
              venueName = "",
              sessionLabel = "",
              baseCounter,
            }) async => CounterSaveResult(counter: updatedCounter),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('团切'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('团切请通过多人切记录处理，这里仅展示当前累计数量。'), findsNothing);
  });

  testWidgets('counter sheet quick count keeps edit and additive buttons', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = "",
              venueName = "",
              sessionLabel = "",
              baseCounter,
            }) async => CounterSaveResult(counter: updatedCounter),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.remove), findsNothing);
    expect(find.text('+1'), findsWidgets);
    expect(find.text('+5'), findsWidgets);
    expect(find.text('+10'), findsNothing);
    expect(find.text('+50'), findsNothing);
    expect(find.text('+100'), findsNothing);

    await tester.tap(find.text('+1').first);
    await tester.pumpAndSettle();

    expect(find.text('总计 1'), findsOneWidget);

    await tester.tap(find.text('1').first);
    await tester.pumpAndSettle();

    expect(find.text('修改3寸'), findsOneWidget);
  });

  testWidgets('counter sheet serializes rapid quick-count saves', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      id: 1,
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );
    final firstSaveGate = Completer<void>();
    final requestedCounts = <int>[];
    var activeSaves = 0;
    var maxActiveSaves = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = '',
              venueName = '',
              sessionLabel = '',
              baseCounter,
            }) async {
              activeSaves += 1;
              maxActiveSaves =
                  activeSaves > maxActiveSaves ? activeSaves : maxActiveSaves;
              requestedCounts.add(updatedCounter.threeInchCount);
              if (requestedCounts.length == 1) {
                await firstSaveGate.future;
              }
              activeSaves -= 1;
              return CounterSaveResult(counter: updatedCounter);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('+1').first);
    await tester.pump();
    await tester.tap(find.text('+1').first);
    await tester.pump();

    expect(find.text('总计 2'), findsOneWidget);
    expect(requestedCounts, [1]);
    expect(maxActiveSaves, 1);

    firstSaveGate.complete();
    await tester.pumpAndSettle();

    expect(requestedCounts, [1, 2]);
    expect(maxActiveSaves, 1);
    expect(find.text('总计 2'), findsOneWidget);
  });

  testWidgets('counter sheet exposes activity event picker', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = "",
              venueName = "",
              sessionLabel = "",
              baseCounter,
            }) async => CounterSaveResult(counter: updatedCounter),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('选择演出'), findsOneWidget);
    expect(find.text('自动填日期和场地'), findsOneWidget);
  });

  testWidgets('counter sheet direct edit cannot decrease a count', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
      threeInchCount: 10,
    );
    var saveCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = "",
              venueName = "",
              sessionLabel = "",
              baseCounter,
            }) async {
              saveCalls += 1;
              return CounterSaveResult(counter: updatedCounter);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('10').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '5');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saveCalls, 0);
    expect(find.text('总计 10'), findsOneWidget);
  });



  testWidgets('quick sheet offers a detail action when wired', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );
    var detailOpened = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = "",
              venueName = "",
              sessionLabel = "",
              baseCounter,
            }) async =>
                CounterSaveResult(counter: updatedCounter),
            onViewDetails: () => detailOpened += 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('查看详情'), findsOneWidget);
    await tester.tap(find.text('查看详情'));
    await tester.pump();
    expect(detailOpened, 1);
  });

  testWidgets('quick count +1 undo deletes the created record and restores total', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      id: 1,
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );
    int? deletedRecordId;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CounterCountSheet(
            counter: counter,
            allCounters: [counter],
            onCounterChanged: (
              updatedCounter,
              occurredAt, {
              activityName = "",
              venueName = "",
              sessionLabel = "",
              baseCounter,
            }) async =>
                CounterSaveResult(counter: updatedCounter, recordId: 77),
            onRecordDeleted: (recordId, beforeCounter) async {
              deletedRecordId = recordId;
              return counter;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('+1').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('总计 1'), findsOneWidget);
    expect(find.text('3寸 +1'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();

    expect(deletedRecordId, 77);
    expect(find.text('总计 0'), findsOneWidget);
  });

  testWidgets('counter sheet keeps quick buttons on one row in compact width', (
    WidgetTester tester,
  ) async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: CounterCountSheet(
                counter: counter,
                allCounters: [counter],
                onCounterChanged: (
                  updatedCounter,
                  occurredAt, {
                  activityName = "",
                  venueName = "",
                  sessionLabel = "",
                  baseCounter,
                }) async => CounterSaveResult(counter: updatedCounter),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    final firstButtonY = tester.getCenter(find.text('+1').first).dy;
    for (final label in ['+5']) {
      expect(
        (tester.getCenter(find.text(label).first).dy - firstButtonY).abs(),
        lessThan(1),
      );
    }
  });
}
