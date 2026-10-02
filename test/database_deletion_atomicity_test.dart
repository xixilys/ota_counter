import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('ota-delete-test-');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  setUp(() => DatabaseService.clearAppData());
  tearDown(() async {
    final db = await DatabaseService.database;
    await db.execute('DROP TRIGGER IF EXISTS reject_delete');
    await DatabaseService.clearAppData();
  });
  tearDownAll(() async {
    await (await DatabaseService.database).close();
    await directory.delete(recursive: true);
  });

  Future<int> add(String name) =>
      DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: CounterModel(name: name, groupName: 'G', color: '#ffffff'),
          occurredAt: DateTime(2026, 10, 2),
          deltas: const {CounterCountField.threeInch: 1},
        ),
      );

  test('rollback preserves photo files and committed deletion cleans them',
      () async {
    final recordId = await add('A');
    final photo = File('${directory.path}/photo.jpg');
    await photo.writeAsBytes([1, 2, 3]);
    final db = await DatabaseService.database;
    await db.insert(DatabaseService.activityRecordMediaTableName, {
      'record_id': recordId,
      'path': photo.path,
      'created_at': 1,
      'media_type': 'memory',
    });
    await db.execute(
        '''CREATE TRIGGER reject_delete BEFORE DELETE ON activity_records
      BEGIN SELECT RAISE(ABORT, 'injected deletion failure'); END''');
    await expectLater(
        DatabaseService.deleteActivityRecordWithCounterImpact(recordId),
        throwsA(isA<DatabaseException>()));
    expect(await photo.exists(), isTrue);
    expect(await DatabaseService.getActivityRecordMedia(recordId: recordId),
        hasLength(1));
    expect((await DatabaseService.getCounters()).single.count, 1);
    await db.execute('DROP TRIGGER reject_delete');
    await DatabaseService.deleteActivityRecordWithCounterImpact(recordId);
    expect(await photo.exists(), isFalse);
    expect(await DatabaseService.getActivityRecordMedia(recordId: recordId),
        isEmpty);
  });

  test('batch member deletion is all or nothing', () async {
    await add('A');
    await add('B');
    final counters = await DatabaseService.getCounters();
    final db = await DatabaseService.database;
    await db.execute('''CREATE TRIGGER reject_delete BEFORE DELETE ON counters
      WHEN OLD.name = 'B' BEGIN SELECT RAISE(ABORT, 'injected member failure'); END''');
    await expectLater(
        DatabaseService.deleteCounters(counters.map((c) => c.id!)),
        throwsA(isA<DatabaseException>()));
    expect(await DatabaseService.getCounters(), hasLength(2));
    expect(await DatabaseService.getActivityRecords(), hasLength(2));
    expect((await DatabaseService.getCounters()).map((c) => c.count),
        everyElement(1));
    await db.execute('DROP TRIGGER reject_delete');
    await DatabaseService.deleteCounters(counters.map((c) => c.id!));
    expect(await DatabaseService.getCounters(), isEmpty);
    expect(await DatabaseService.getActivityRecords(), isEmpty);
  });
}
