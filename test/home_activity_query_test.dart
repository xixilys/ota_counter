import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/custom_cheki_type_model.dart';
import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async => DatabaseService.clearAppData());
  tearDown(() async => DatabaseService.clearAppData());

  test('home support query skips tickets and plain counter records', () async {
    final counter = CounterModel(
      name: '成员A',
      groupName: '团体A',
      color: '#FFE135',
    );

    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: DateTime(2026, 10, 1),
        deltas: const {CounterCountField.threeInch: 1},
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: DateTime(2026, 10, 2),
        deltas: const {CounterCountField.threeInch: 1},
        customChekiCounts: const [
          ActivityRecordCustomChekiCount(
            typeId: 'custom-1',
            label: '签绘',
            count: 1,
            unitPrice: 30,
          ),
        ],
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: '成员A', groupName: '团体A'),
          ActivityParticipant(memberName: '成员B', groupName: '团体A'),
        ],
        field: CounterCountField.groupCut,
        occurredAt: DateTime(2026, 10, 3),
        quantity: 2,
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel(
        type: ActivityRecordType.multi,
        subjectName: '旧版双人切',
        groupName: '团体A',
        occurredAt: DateTime(2026, 10, 5),
        groupCutCount: 2,
        multiCutQuantity: 2,
        totalAmount: 0,
        participants: const [
          ActivityParticipant(memberName: '成员A', groupName: '团体A'),
          ActivityParticipant(memberName: '成员B', groupName: '团体A'),
        ],
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: '演出',
        occurredAt: DateTime(2026, 10, 4),
        quantity: 1,
        unitPrice: 80,
      ),
    );

    // Simulate a row written by the old schema where record_type was 'duo'.
    final db = await DatabaseService.database;
    await db.insert(
      DatabaseService.activityRecordTableName,
      {
        'record_type': 'duo',
        'source': 'local',
        'subject_name': '旧版双人切2',
        'group_name': '团体A',
        'occurred_at': '2026-10-06T00:00:00.000',
        'three_inch_count': 0,
        'five_inch_count': 0,
        'group_cut_count': 1,
        'multi_cut_quantity': 1,
        'total_amount': 0,
        'multi_participants_json': '[]',
        'custom_cheki_counts_json': '[]',
      },
    );

    final support = await DatabaseService.getHomeActivityRecords();
    expect(support, hasLength(4));
    expect(support.where((record) => record.isMulti), hasLength(3));
    expect(
      support.where((record) => record.effectiveCustomChekiCounts.isNotEmpty),
      hasLength(1),
    );
    expect(await DatabaseService.getActivityRecordCount(), 6);
  });
}
