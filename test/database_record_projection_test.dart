import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DatabaseService.clearAppData();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  CounterModel counterById(List<CounterModel> counters, int id) {
    return counters.singleWhere((counter) => counter.id == id);
  }

  test('multi record impact prefers participant personId over name fallback',
      () async {
    final firstId = await DatabaseService.insertCounter(
      CounterModel(
        name: '兔',
        groupName: '萝北',
        personId: 101,
        personName: '兔A',
        color: '#111111',
      ),
    );
    final secondId = await DatabaseService.insertCounter(
      CounterModel(
        name: '兔',
        groupName: '萝北',
        personId: 202,
        personName: '兔B',
        color: '#222222',
      ),
    );

    final record = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(
          memberName: '兔',
          groupName: '萝北',
          personId: 202,
          personName: '兔B',
        ),
        ActivityParticipant(
          memberName: '旁',
          groupName: '萝北',
          personId: 303,
          personName: '旁',
        ),
      ],
      field: CounterCountField.threeInch,
      occurredAt: DateTime(2026, 4, 26),
      quantity: 1,
    );

    final recordId =
        await DatabaseService.insertActivityRecordWithCounterImpact(record);
    var counters = await DatabaseService.getCounters();
    expect(counterById(counters, firstId).threeInchCount, 0);
    expect(counterById(counters, secondId).threeInchCount, 1);

    await DatabaseService.deleteActivityRecordWithCounterImpact(recordId);
    counters = await DatabaseService.getCounters();
    expect(counterById(counters, firstId).threeInchCount, 0);
    expect(counterById(counters, secondId).threeInchCount, 0);
  });

  test('updating a record reverses old impact and applies new impact once',
      () async {
    final firstId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A',
        groupName: 'G',
        personId: 1,
        personName: 'A',
        color: '#111111',
      ),
    );
    final secondId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'B',
        groupName: 'G',
        personId: 2,
        personName: 'B',
        color: '#222222',
      ),
    );

    final oldRecord = ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        id: firstId,
        name: 'A',
        groupName: 'G',
        personId: 1,
        personName: 'A',
        color: '#111111',
      ),
      occurredAt: DateTime(2026, 4, 26),
      deltas: const {CounterCountField.threeInch: 2},
    );
    final recordId =
        await DatabaseService.insertActivityRecordWithCounterImpact(oldRecord);

    final newRecord = ActivityRecordModel.counterAdjustment(
      id: recordId,
      counter: CounterModel(
        id: secondId,
        name: 'B',
        groupName: 'G',
        personId: 2,
        personName: 'B',
        color: '#222222',
      ),
      occurredAt: DateTime(2026, 4, 27),
      deltas: const {CounterCountField.fiveInch: 3},
    );
    await DatabaseService.updateActivityRecordWithCounterImpact(
      recordId,
      newRecord,
    );

    final counters = await DatabaseService.getCounters();
    expect(counterById(counters, firstId).count, 0);
    expect(counterById(counters, secondId).fiveInchCount, 3);
    expect(counterById(counters, secondId).count, 3);
  });

  test('recalculating counters rebuilds cached totals from records', () async {
    final counterId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A',
        groupName: 'G',
        personId: 1,
        personName: 'A',
        color: '#111111',
        threeInchCount: 99,
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.counterAdjustment(
        counter: CounterModel(
          id: counterId,
          name: 'A',
          groupName: 'G',
          personId: 1,
          personName: 'A',
          color: '#111111',
        ),
        occurredAt: DateTime(2026, 4, 26),
        deltas: const {CounterCountField.threeInch: 4},
      ),
    );

    final replayed =
        await DatabaseService.recalculateCountersFromActivityRecords();

    final counters = await DatabaseService.getCounters();
    expect(replayed, 1);
    expect(counterById(counters, counterId).threeInchCount, 4);
    expect(counterById(counters, counterId).count, 4);
  });

  test('counter and multi records preserve selected activity session', () {
    final counterRecord = ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        id: 1,
        name: 'A',
        groupName: 'G',
        color: '#111111',
      ),
      occurredAt: DateTime(2026, 7, 7),
      deltas: const {CounterCountField.threeInch: 1},
      activityName: '测试偶活',
      venueName: '测试场地',
      sessionLabel: '一部',
    );
    final multiRecord = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G'),
        ActivityParticipant(memberName: 'B', groupName: 'G'),
      ],
      field: CounterCountField.threeInch,
      occurredAt: DateTime(2026, 7, 7),
      activityName: '测试偶活',
      venueName: '测试场地',
      sessionLabel: '一部',
    );

    expect(counterRecord.sessionLabel, '一部');
    expect(multiRecord.sessionLabel, '一部');
  });

  testWidgets('manual counter record dialog rejects negative deltas',
      (tester) async {
    var dialogClosed = false;
    final counter = CounterModel(
      id: 1,
      name: 'A',
      groupName: 'G',
      color: '#111111',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () async {
                await showDialog<ActivityRecordDraft>(
                  context: context,
                  builder: (context) => AddActivityRecordDialog(
                    counters: [counter],
                    pricings: const [],
                    initialDraft: ActivityRecordDraft(
                      type: ActivityRecordType.counter,
                      counter: counter,
                      occurredAt: DateTime(2026, 4, 26),
                      counterDeltas: const {
                        CounterCountField.threeInch: -9,
                      },
                    ),
                  ),
                );
                dialogClosed = true;
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('新增记录'), findsOneWidget);

    await tester.tap(find.text('保存记录'));
    await tester.pumpAndSettle();

    expect(dialogClosed, isFalse);
    expect(find.text('新增记录'), findsOneWidget);
  });
}
