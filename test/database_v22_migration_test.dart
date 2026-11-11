import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  test(
      'v21 -> v22 adds durable enrollment receipts without losing face samples',
      () async {
    final path = p.join(await getDatabasesPath(), 'counter_app.db');
    final old = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 21,
            onCreate: (db, version) async {
              await db.execute('''CREATE TABLE counters(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              group_name TEXT NOT NULL DEFAULT '',
              person_id INTEGER,
              person_name TEXT NOT NULL DEFAULT '',
              count INTEGER NOT NULL,
              color TEXT NOT NULL,
              is_hidden INTEGER NOT NULL DEFAULT 0,
              three_inch_count INTEGER NOT NULL DEFAULT 0,
              five_inch_count INTEGER NOT NULL DEFAULT 0,
              unsigned_three_inch_count INTEGER NOT NULL DEFAULT 0,
              unsigned_five_inch_count INTEGER NOT NULL DEFAULT 0,
              group_cut_count INTEGER NOT NULL DEFAULT 0,
              three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
              five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0
            )
          ''');
              await db.insert('counters',
                  {'id': 7, 'name': '测试成员', 'count': 3, 'color': '#ffffff'});
              await db.execute('''CREATE TABLE face_samples(
        id INTEGER PRIMARY KEY AUTOINCREMENT, person_id INTEGER,
        person_name TEXT NOT NULL DEFAULT '', counter_id INTEGER,
        is_self INTEGER NOT NULL DEFAULT 0, media_id INTEGER,
        face_box_json TEXT NOT NULL DEFAULT '{}', embedding BLOB NOT NULL,
        model_id TEXT NOT NULL, quality REAL NOT NULL DEFAULT 0,
        source TEXT NOT NULL, created_at TEXT NOT NULL)''');
              await db.insert('face_samples', {
                'counter_id': 7,
                'embedding': Uint8List.fromList([0, 0, 128, 63]),
                'model_id': 'synthetic',
                'source': 'manual',
                'created_at': '2026-11-11',
              });
            }));
    await old.close();
    final db = await DatabaseService.database;
    expect(await db.getVersion(), 22);
    expect((await db.query('counters')).single['name'], '测试成员');
    expect((await db.query('face_samples')).single['source'], 'manual');
    await db.insert(DatabaseService.faceEnrollmentActionsTableName, {
      'server_url': 'http://localhost',
      'action_id': 'synthetic-id',
      'result_json': '{"faces_found":1,"used_face":1}',
    });
    // Independent connection reads the committed receipt, not process state.
    final reader = await databaseFactory.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      expect(
          (await reader.query(DatabaseService.faceEnrollmentActionsTableName))
              .single['action_id'],
          'synthetic-id');
    } finally {
      await reader.close();
    }
  });
}
