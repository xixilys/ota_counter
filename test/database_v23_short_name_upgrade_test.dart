import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  test('a database already stamped v23 without short_name gains the column',
      () async {
    // Emulators that installed the earlier v23 build have a database that
    // reports version 23 but predates the 卡面简称 column. Opening it must still
    // add the column and keep every existing counter.
    final path = p.join(await getDatabasesPath(), 'counter_app.db');
    final stale = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 23,
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
          await db.insert('counters', {
            'id': 1,
            'name': '小雪',
            'group_name': '测试团',
            'count': 3,
            'color': '#ffffff',
          });
        },
      ),
    );
    await stale.close();

    final db = await DatabaseService.database;
    expect(await db.getVersion(), 23);
    final columns = await db.rawQuery(
      'PRAGMA table_info(${DatabaseService.tableName})',
    );
    expect(columns.map((row) => row['name']), contains('short_name'));

    final counters = await DatabaseService.getCounters();
    expect(counters.single.name, '小雪');
    expect(counters.single.shortName, '');
    expect(counters.single.displayShortName, '雪');

    await DatabaseService.updateCounter(
      1,
      counters.single.copyWith(shortName: '雪雪'),
    );
    final saved = await DatabaseService.getCounters();
    expect(saved.single.shortName, '雪雪');
  });
}
