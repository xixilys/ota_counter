import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  test('opening an existing v21 database ensures legacy metadata columns',
      () async {
    final path = p.join(await getDatabasesPath(), 'counter_app.db');
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 21,
        onCreate: (db, version) async {
          // Existing current-version DB: onUpgrade will not run. Keep the
          // columns required by the normal activity-record indexes.
          await db.execute('''
            CREATE TABLE activity_records(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              record_type TEXT NOT NULL,
              source TEXT NOT NULL DEFAULT 'local',
              source_record_id TEXT,
              counter_id INTEGER,
              person_id INTEGER,
              subject_name TEXT NOT NULL,
              group_name TEXT NOT NULL DEFAULT '',
              occurred_at TEXT NOT NULL
            )
          ''');
          await db.insert('activity_records', {
            'id': 1,
            'record_type': 'counter',
            'subject_name': 'Synthetic member',
            'occurred_at': '2026-03-18T00:00:00.000',
          });
        },
      ),
    );
    await old.close();

    final db = await DatabaseService.database;
    expect(await db.getVersion(), 22);
    final row = (await db.query('activity_records')).single;
    expect(row['subject_name'], 'Synthetic member');
    expect(row, containsPair('group_record_id', null));
    expect(row, containsPair('is_system_adjustment', 0));

    await db.update(
        'activity_records',
        {
          'group_record_id': 'legacy-group-001',
          'is_system_adjustment': 1,
        },
        where: 'id = ?',
        whereArgs: [1]);
    final record = (await DatabaseService.getActivityRecords()).single;
    await DatabaseService.updateActivityRecord(
        1, record.copyWith(note: 'edit'));
    final edited = (await db.query('activity_records')).single;
    expect(edited['note'], 'edit');
    expect(edited['group_record_id'], 'legacy-group-001');
    expect(edited['is_system_adjustment'], 1);
    await db.close();
  });
}
