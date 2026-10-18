import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/idol_database_models.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory databasesDirectory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databasesDirectory =
        await Directory.systemTemp.createTemp('ota-identity-reconcile-');
    await databaseFactory.setDatabasesPath(databasesDirectory.path);
  });

  tearDownAll(() async {
    await (await DatabaseService.database).close();
    await (await IdolDatabaseService.database).close();
    await databasesDirectory.delete(recursive: true);
  });

  setUp(() async {
    await DatabaseService.clearAppData();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  test('reconcile repairs counters and records after an idol refresh',
      () async {
    final groupName = '测试团${DateTime.now().microsecondsSinceEpoch}';
    const memberName = '测试成员';
    const stalePersonId = 9999999;

    final groupId = await IdolDatabaseService.upsertGroup(
      IdolGroup(name: groupName),
    );
    addTearDown(() => IdolDatabaseService.deleteGroup(groupId));
    await IdolDatabaseService.upsertMember(
      IdolMember(
        groupId: groupId,
        groupName: groupName,
        name: memberName,
        personName: memberName,
      ),
    );
    final member = (await IdolDatabaseService.getMembers(groupId: groupId))
        .singleWhere((item) => item.name == memberName);
    final canonicalPersonId = member.personId;
    expect(canonicalPersonId, isNotNull);

    final counterId = await DatabaseService.insertCounter(
      CounterModel(
        name: memberName,
        groupName: groupName,
        personId: stalePersonId,
        personName: memberName,
        color: '#123456',
        threeInchCount: 3,
      ),
    );
    await DatabaseService.insertCounter(
      CounterModel(
        name: memberName,
        groupName: groupName,
        personId: 7777777,
        personName: memberName,
        color: '#123456',
        threeInchCount: 2,
      ),
    );
    final counterRecordId = await DatabaseService.insertActivityRecord(
      ActivityRecordModel(
        type: ActivityRecordType.counter,
        subjectName: memberName,
        groupName: groupName,
        personId: stalePersonId,
        personName: memberName,
        occurredAt: DateTime(2026, 1, 2),
        threeInchCount: 1,
        totalAmount: 0,
      ),
    );
    final multiRecordId = await DatabaseService.insertActivityRecord(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(
            memberName: memberName,
            groupName: '', // filled below with the generated group name
            personId: stalePersonId,
            personName: memberName,
          ),
          ActivityParticipant(
            memberName: '搭档',
            groupName: '',
            personId: 8888888,
            personName: '搭档',
          ),
        ],
        field: CounterCountField.threeInch,
        occurredAt: DateTime(2026, 1, 3),
        quantity: 1,
      ),
    );
    // Give the multi record a real group name so the group-scoped identity
    // lookup can resolve it.
    final db = await DatabaseService.database;
    await db.update(
      DatabaseService.activityRecordTableName,
      {'group_name': groupName},
      where: 'id = ?',
      whereArgs: [multiRecordId],
    );

    await DatabaseService.reconcileCounterIdentities();

    final counter = (await DatabaseService.getCounters())
        .singleWhere((item) => item.id == counterId);
    expect(counter.personId, canonicalPersonId);
    expect(counter.personName, member.resolvedPersonName);
    expect(counter.threeInchCount, 5);
    expect(
      (await DatabaseService.getCounters())
          .where((item) => item.groupName == groupName),
      hasLength(1),
    );

    final records = await DatabaseService.getActivityRecords();
    final counterRecord =
        records.singleWhere((item) => item.id == counterRecordId);
    expect(counterRecord.personId, canonicalPersonId);

    final multiRecord = records.singleWhere((item) => item.id == multiRecordId);
    final repairedParticipant = multiRecord.effectiveParticipants
        .singleWhere((item) => item.memberName == memberName);
    expect(repairedParticipant.personId, canonicalPersonId);
    expect(repairedParticipant.personName, member.resolvedPersonName);
  });
}
