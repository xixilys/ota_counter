import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
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

  test('multi record impact keeps the same person in the selected group',
      () async {
    final firstGroupId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A旧团名',
        groupName: 'G1',
        personId: 101,
        personName: 'A',
        color: '#111111',
      ),
    );
    final secondGroupId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A新团名',
        groupName: 'G2',
        personId: 101,
        personName: 'A',
        color: '#222222',
      ),
    );

    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(
            memberName: 'A新团名',
            groupName: 'G2',
            personId: 101,
            personName: 'A',
          ),
          ActivityParticipant(
            memberName: 'B',
            groupName: 'G2',
            personId: 202,
            personName: 'B',
          ),
        ],
        field: CounterCountField.threeInch,
        occurredAt: DateTime(2026, 4, 26),
      ),
    );

    final counters = await DatabaseService.getCounters();
    expect(counterById(counters, firstGroupId).count, 0);
    expect(counterById(counters, secondGroupId).threeInchCount, 1);
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

  test('deleting a counter removes multi records that could recreate it',
      () async {
    final deletedCounterId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A',
        groupName: 'G',
        personId: 1,
        personName: 'A',
        color: '#111111',
      ),
    );
    final otherCounterId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'B',
        groupName: 'G',
        personId: 2,
        personName: 'B',
        color: '#222222',
      ),
    );
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(
            memberName: 'A',
            groupName: 'G',
            personId: 1,
            personName: 'A',
          ),
          ActivityParticipant(
            memberName: 'B',
            groupName: 'G',
            personId: 2,
            personName: 'B',
          ),
        ],
        field: CounterCountField.threeInch,
        occurredAt: DateTime(2026, 4, 26),
      ),
    );

    await DatabaseService.deleteCounter(deletedCounterId);
    await DatabaseService.recalculateCountersFromActivityRecords();

    final counters = await DatabaseService.getCounters();
    expect(counters.any((counter) => counter.id == deletedCounterId), isFalse);
    expect(counterById(counters, otherCounterId).count, 0);
    expect(await DatabaseService.getActivityRecords(), isEmpty);
  });

  test('deleting a counter removes unlinked imported records and sync markers',
      () async {
    final counterId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A',
        groupName: 'G',
        personId: 1,
        personName: 'A',
        color: '#111111',
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel(
        type: ActivityRecordType.counter,
        source: 'ota_site',
        sourceRecordId: 'remote-1',
        personId: 1,
        personName: 'A',
        subjectName: 'A',
        groupName: 'G',
        occurredAt: DateTime(2026, 4, 26),
        threeInchCount: 2,
        totalAmount: 120,
      ),
    );
    await DatabaseService.syncActivityRecordsToCounters('ota_site');

    await DatabaseService.deleteCounter(counterId);

    expect(await DatabaseService.getActivityRecords(), isEmpty);
    final db = await DatabaseService.database;
    expect(await db.query(DatabaseService.counterSyncTableName), isEmpty);
  });

  test('deleting a counter does not remove a homonym with a different id',
      () async {
    final deletedCounterId = await DatabaseService.insertCounter(
      CounterModel(
        name: '同名成员',
        groupName: 'G',
        personId: 1,
        personName: '同名真人',
        color: '#111111',
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel(
        type: ActivityRecordType.counter,
        personId: 2,
        personName: '同名真人',
        subjectName: '同名成员',
        groupName: 'G',
        occurredAt: DateTime(2026, 4, 26),
        threeInchCount: 1,
        totalAmount: 60,
      ),
    );

    await DatabaseService.deleteCounter(deletedCounterId);

    final records = await DatabaseService.getActivityRecords();
    expect(records, hasLength(1));
    expect(records.single.personId, 2);
  });

  test('OTA sync keeps same-name counters separated by person id', () async {
    final firstId = await DatabaseService.insertCounter(
      CounterModel(
        name: '同名成员',
        groupName: 'G',
        personId: 1,
        personName: '真人一',
        color: '#111111',
      ),
    );
    final secondId = await DatabaseService.insertCounter(
      CounterModel(
        name: '同名成员',
        groupName: 'G',
        personId: 2,
        personName: '真人二',
        color: '#222222',
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel(
        type: ActivityRecordType.counter,
        source: 'ota_site',
        sourceRecordId: 'remote-person-1',
        personId: 1,
        personName: '真人一',
        subjectName: '同名成员',
        groupName: 'G',
        occurredAt: DateTime(2026, 4, 26),
        threeInchCount: 1,
        totalAmount: 60,
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel(
        type: ActivityRecordType.counter,
        source: 'ota_site',
        sourceRecordId: 'remote-person-2',
        personId: 2,
        personName: '真人二',
        subjectName: '同名成员',
        groupName: 'G',
        occurredAt: DateTime(2026, 4, 27),
        threeInchCount: 2,
        totalAmount: 120,
      ),
    );

    await DatabaseService.syncActivityRecordsToCounters('ota_site');

    final counters = await DatabaseService.getCounters();
    expect(counterById(counters, firstId).threeInchCount, 1);
    expect(counterById(counters, secondId).threeInchCount, 2);
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

  test('database persists explicit current-pricing mode', () async {
    final counterId = await DatabaseService.insertCounter(
      CounterModel(
        name: 'A',
        groupName: 'G',
        color: '#111111',
      ),
    );
    final recordId =
        await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: CounterModel(
          id: counterId,
          name: 'A',
          groupName: 'G',
          color: '#111111',
        ),
        occurredAt: DateTime(2026, 7, 18),
        deltas: const {CounterCountField.threeInch: 1},
        pricing: GroupPricingModel(
          groupName: 'G',
          label: '赠送券',
          threeInchPrice: 0,
          updatedAt: DateTime(2026, 7, 18),
        ),
      ),
    );

    final records = await DatabaseService.getActivityRecords();
    final restored = records.singleWhere((record) => record.id == recordId);

    expect(restored.usesCurrentPricing, isFalse);
    expect(restored.shouldResolveWithCurrentPricing, isFalse);
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

  testWidgets('editing a historical record previews its saved amount',
      (tester) async {
    final counter = CounterModel(
      id: 1,
      name: 'A',
      groupName: 'G',
      color: '#111111',
    );
    final original = ActivityRecordModel.counterAdjustment(
      counter: counter,
      occurredAt: DateTime(2026, 4, 26),
      deltas: const {CounterCountField.threeInch: 2},
      pricing: GroupPricingModel(
        groupName: 'G',
        label: '旧团价',
        threeInchPrice: 77,
        updatedAt: DateTime(2026, 4, 26),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AddActivityRecordDialog(
            counters: [counter],
            pricings: [
              GroupPricingModel(
                groupName: 'G',
                label: '新团价',
                threeInchPrice: 120,
                updatedAt: DateTime(2026, 7, 18),
              ),
            ],
            initialDraft: ActivityRecordDraft.fromRecord(
              original,
              resolvedCounter: counter,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('记录价格标签：旧团价'), findsOneWidget);
    expect(find.text('3寸 ¥77'), findsOneWidget);
    expect(find.text('预计金额：¥154'), findsOneWidget);
  });
}
