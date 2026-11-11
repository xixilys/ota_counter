import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

/// A v20 database (the schema shipped in v1.5.4) upgraded to the latest
/// schema keeps its data and gains face samples, enrollment receipts and
/// the media provenance columns.
void main() {
  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  test(
      'v20 -> latest adds face samples, enrollment receipts and media columns, keeps rows',
      () async {
    final path = p.join(await getDatabasesPath(), 'counter_app.db');
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 20,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE counters(
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
          await db.execute('''
            CREATE TABLE activity_record_media(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              record_id INTEGER NOT NULL,
              path TEXT NOT NULL,
              created_at TEXT NOT NULL,
              media_type TEXT NOT NULL DEFAULT 'memory',
              processing_mode TEXT NOT NULL DEFAULT 'none',
              is_reversed INTEGER NOT NULL DEFAULT 0,
              owner_person_id INTEGER,
              owner_person_name TEXT NOT NULL DEFAULT '',
              owner_group_name TEXT NOT NULL DEFAULT ''
            )
          ''');
          await db.insert('counters', {
            'name': '小树',
            'count': 3,
            'color': '#22C55E',
          });
          await db.insert('activity_record_media', {
            'record_id': 7,
            'path': '/old/photo.jpg',
            'created_at': '2026-03-14T20:00:00.000',
          });
        },
      ),
    );
    await old.close();

    final db = await DatabaseService.database;
    expect(await db.getVersion(), 22);
    final receiptColumns = (await db.rawQuery(
      'PRAGMA table_info(face_enrollment_actions)',
    ))
        .map((row) => row['name'])
        .toSet();
    expect(receiptColumns,
        containsAll(['server_url', 'action_id', 'result_json', 'failure']));

    final mediaColumns = (await db.rawQuery(
      'PRAGMA table_info(activity_record_media)',
    ))
        .map((row) => row['name'])
        .toSet();
    expect(mediaColumns,
        containsAll(['captured_at', 'source_hash', 'crop_quad_json']));

    final faceColumns = (await db.rawQuery('PRAGMA table_info(face_samples)'))
        .map((row) => row['name'])
        .toSet();
    expect(
      faceColumns,
      containsAll([
        'id',
        'person_id',
        'person_name',
        'counter_id',
        'is_self',
        'media_id',
        'face_box_json',
        'embedding',
        'model_id',
        'quality',
        'source',
        'created_at',
      ]),
    );

    final media = await DatabaseService.getActivityRecordMedia();
    expect(media.single.path, '/old/photo.jpg');
    expect(media.single.sourceHash, '');
    expect(media.single.capturedAt, isNull);
    final counters = await DatabaseService.getCounters();
    expect(counters.single.name, '小树');

    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    ))
        .map((row) => row['name'])
        .toSet();
    expect(indexes, contains('idx_activity_record_media_source_hash'));
  });
}
