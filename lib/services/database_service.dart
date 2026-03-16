import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/counter_model.dart';

class DatabaseService {
  static const String _dbName = 'counter_app.db';
  static const String tableName = 'counters';
  static const int _version = 2;

  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), _dbName);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return await openDatabase(
        path,
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    }

    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await _createSchema(db);
  }

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _migrateToV2(db);
    }
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $tableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        count INTEGER NOT NULL,
        color TEXT NOT NULL,
        three_inch_count INTEGER NOT NULL DEFAULT 0,
        five_inch_count INTEGER NOT NULL DEFAULT 0,
        group_cut_count INTEGER NOT NULL DEFAULT 0,
        three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  static Future<void> _migrateToV2(Database db) async {
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN three_inch_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN five_inch_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN group_cut_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0',
    );

    await db.execute(
      'UPDATE $tableName SET three_inch_count = count WHERE count > 0',
    );
  }

  static Map<String, dynamic> _toDatabaseMap(CounterModel counter) {
    return {
      'name': counter.name,
      'count': counter.count,
      'color': counter.color,
      'three_inch_count': counter.threeInchCount,
      'five_inch_count': counter.fiveInchCount,
      'group_cut_count': counter.groupCutCount,
      'three_inch_shukudai_count': counter.threeInchShukudaiCount,
      'five_inch_shukudai_count': counter.fiveInchShukudaiCount,
    };
  }

  static Future<List<CounterModel>> getCounters() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(tableName);
    return List.generate(maps.length, (i) {
      return CounterModel.fromMap(maps[i]);
    });
  }

  static Future<int> insertCounter(CounterModel counter) async {
    final db = await database;
    return await db.insert(
      tableName,
      _toDatabaseMap(counter),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> updateCounter(int id, CounterModel counter) async {
    final db = await database;
    await db.update(
      tableName,
      _toDatabaseMap(counter),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> deleteCounter(int id) async {
    final db = await database;
    await db.delete(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
