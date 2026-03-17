import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../models/idol_database_models.dart';
import 'idol_database_service.dart';

class DatabaseService {
  static const String _dbName = 'counter_app.db';
  static const String tableName = 'counters';
  static const String groupPricingTableName = 'group_pricings';
  static const String activityRecordTableName = 'activity_records';
  static const String counterSyncTableName = 'counter_sync_log';
  static const int _version = 8;

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

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _migrateToV2(db);
    }
    if (oldVersion < 3) {
      await _migrateToV3(db);
    }
    if (oldVersion < 4) {
      await _migrateToV4(db);
    }
    if (oldVersion < 5) {
      await _migrateToV5(db);
    }
    if (oldVersion < 6) {
      await _migrateToV6(db);
    }
    if (oldVersion < 7) {
      await _migrateToV7(db);
    }
    if (oldVersion < 8) {
      await _migrateToV8(db);
    }
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        group_name TEXT NOT NULL DEFAULT '',
        count INTEGER NOT NULL,
        color TEXT NOT NULL,
        is_hidden INTEGER NOT NULL DEFAULT 0,
        three_inch_count INTEGER NOT NULL DEFAULT 0,
        five_inch_count INTEGER NOT NULL DEFAULT 0,
        group_cut_count INTEGER NOT NULL DEFAULT 0,
        three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $groupPricingTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_name TEXT NOT NULL UNIQUE,
        label TEXT NOT NULL DEFAULT '',
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        three_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        five_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $activityRecordTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_type TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'local',
        source_record_id TEXT,
        counter_id INTEGER,
        subject_name TEXT NOT NULL,
        group_name TEXT NOT NULL DEFAULT '',
        session_label TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        occurred_at TEXT NOT NULL,
        pricing_label TEXT NOT NULL DEFAULT '',
        three_inch_count INTEGER NOT NULL DEFAULT 0,
        five_inch_count INTEGER NOT NULL DEFAULT 0,
        group_cut_count INTEGER NOT NULL DEFAULT 0,
        three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        ticket_quantity INTEGER NOT NULL DEFAULT 0,
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        three_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        five_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        ticket_unit_price REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_records_occurred_at
      ON $activityRecordTableName(occurred_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_records_group_name
      ON $activityRecordTableName(group_name)
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_records_source_remote
      ON $activityRecordTableName(source, source_record_id)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $counterSyncTableName(
        source TEXT NOT NULL,
        source_record_id TEXT NOT NULL,
        applied_at TEXT NOT NULL,
        PRIMARY KEY(source, source_record_id)
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

  static Future<void> _migrateToV3(Database db) async {
    await db.execute(
      "ALTER TABLE $tableName ADD COLUMN group_name TEXT NOT NULL DEFAULT ''",
    );
  }

  static Future<void> _migrateToV4(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $groupPricingTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_name TEXT NOT NULL UNIQUE,
        label TEXT NOT NULL DEFAULT '',
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        three_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        five_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _migrateToV5(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $activityRecordTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_type TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'local',
        source_record_id TEXT,
        counter_id INTEGER,
        subject_name TEXT NOT NULL,
        group_name TEXT NOT NULL DEFAULT '',
        session_label TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        occurred_at TEXT NOT NULL,
        pricing_label TEXT NOT NULL DEFAULT '',
        three_inch_count INTEGER NOT NULL DEFAULT 0,
        five_inch_count INTEGER NOT NULL DEFAULT 0,
        group_cut_count INTEGER NOT NULL DEFAULT 0,
        three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        ticket_quantity INTEGER NOT NULL DEFAULT 0,
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        three_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        five_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        ticket_unit_price REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_records_occurred_at
      ON $activityRecordTableName(occurred_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_records_group_name
      ON $activityRecordTableName(group_name)
    ''');
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_records_source_remote
      ON $activityRecordTableName(source, source_record_id)
    ''');
  }

  static Future<void> _migrateToV6(Database db) async {
    await db.execute(
      "ALTER TABLE $activityRecordTableName ADD COLUMN source TEXT NOT NULL DEFAULT 'local'",
    );
    await db.execute(
      "ALTER TABLE $activityRecordTableName ADD COLUMN source_record_id TEXT",
    );
    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_activity_records_source_remote
      ON $activityRecordTableName(source, source_record_id)
    ''');
  }

  static Future<void> _migrateToV7(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $counterSyncTableName(
        source TEXT NOT NULL,
        source_record_id TEXT NOT NULL,
        applied_at TEXT NOT NULL,
        PRIMARY KEY(source, source_record_id)
      )
    ''');
  }

  static Future<void> _migrateToV8(Database db) async {
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0',
    );
  }

  static Map<String, dynamic> _toDatabaseMap(CounterModel counter) {
    return {
      'name': counter.name,
      'group_name': counter.groupName,
      'count': counter.count,
      'color': counter.color,
      'is_hidden': counter.isHidden ? 1 : 0,
      'three_inch_count': counter.threeInchCount,
      'five_inch_count': counter.fiveInchCount,
      'group_cut_count': counter.groupCutCount,
      'three_inch_shukudai_count': counter.threeInchShukudaiCount,
      'five_inch_shukudai_count': counter.fiveInchShukudaiCount,
    };
  }

  static Map<String, Object?> _pricingToDatabaseMap(
    GroupPricingModel pricing,
  ) {
    return pricing.toMap()..remove('id');
  }

  static Map<String, Object?> _recordToDatabaseMap(
    ActivityRecordModel record,
  ) {
    return record.toMap()..remove('id');
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

  static Future<List<GroupPricingModel>> getGroupPricings() async {
    final db = await database;
    final maps = await db.query(
      groupPricingTableName,
      orderBy: 'group_name COLLATE NOCASE ASC',
    );
    return maps.map(GroupPricingModel.fromMap).toList();
  }

  static Future<GroupPricingModel?> getGroupPricingByName(
      String groupName) async {
    final normalized = groupName.trim();
    if (normalized.isEmpty) {
      return null;
    }

    final db = await database;
    final maps = await db.query(
      groupPricingTableName,
      where: 'group_name = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return GroupPricingModel.fromMap(maps.first);
  }

  static Future<int> upsertGroupPricing(GroupPricingModel pricing) async {
    final db = await database;
    if (pricing.id != null) {
      await db.update(
        groupPricingTableName,
        _pricingToDatabaseMap(pricing),
        where: 'id = ?',
        whereArgs: [pricing.id],
      );
      return pricing.id!;
    }

    return db.insert(
      groupPricingTableName,
      _pricingToDatabaseMap(pricing),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteGroupPricing(int id) async {
    final db = await database;
    await db.delete(
      groupPricingTableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<ActivityRecordModel>> getActivityRecords() async {
    final db = await database;
    final maps = await db.query(
      activityRecordTableName,
      orderBy: 'occurred_at DESC, id DESC',
    );
    return maps.map(ActivityRecordModel.fromMap).toList();
  }

  static Future<int> insertActivityRecord(ActivityRecordModel record) async {
    final db = await database;
    return db.insert(
      activityRecordTableName,
      _recordToDatabaseMap(record),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteActivityRecord(int id) async {
    final db = await database;
    await db.delete(
      activityRecordTableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> clearAppData() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(counterSyncTableName);
      await txn.delete(activityRecordTableName);
      await txn.delete(groupPricingTableName);
      await txn.delete(tableName);
    });
  }

  static Future<Set<String>> getActivityRecordSourceIds(String source) async {
    final db = await database;
    final maps = await db.query(
      activityRecordTableName,
      columns: ['source_record_id'],
      where: 'source = ? AND source_record_id IS NOT NULL',
      whereArgs: [source],
    );
    return maps
        .map((row) => row['source_record_id'] as String?)
        .whereType<String>()
        .toSet();
  }

  static Future<int> syncActivityRecordsToCounters(String source) async {
    final db = await database;
    final themeLookup = await _buildCounterThemeLookup();

    return db.transaction((txn) async {
      final syncedMaps = await txn.query(
        counterSyncTableName,
        columns: ['source_record_id'],
        where: 'source = ?',
        whereArgs: [source],
      );
      final syncedIds = syncedMaps
          .map((row) => row['source_record_id'] as String?)
          .whereType<String>()
          .toSet();

      final recordMaps = await txn.query(
        activityRecordTableName,
        where:
            'source = ? AND record_type = ? AND source_record_id IS NOT NULL',
        whereArgs: [source, ActivityRecordType.counter.dbValue],
        orderBy: 'occurred_at ASC, id ASC',
      );
      if (recordMaps.isEmpty) {
        return 0;
      }

      final counterMaps = await txn.query(tableName);
      final countersByKey = <String, CounterModel>{};
      for (final row in counterMaps) {
        final counter = CounterModel.fromMap(row);
        final key = _normalizeCounterKey(counter.name, counter.groupName);
        if (key.isEmpty) {
          continue;
        }
        countersByKey[key] = counter;
      }

      var appliedCount = 0;
      for (final map in recordMaps) {
        final record = ActivityRecordModel.fromMap(map);
        final sourceRecordId = record.sourceRecordId?.trim();
        if (sourceRecordId == null ||
            sourceRecordId.isEmpty ||
            syncedIds.contains(sourceRecordId)) {
          continue;
        }

        final counterName = record.subjectName.trim();
        if (counterName.isEmpty) {
          continue;
        }

        final key = _normalizeCounterKey(counterName, record.groupName);
        if (key.isEmpty) {
          continue;
        }

        final existingCounter = countersByKey[key];
        final resolvedThemeColor = _resolveCounterThemeColor(
          name: counterName,
          groupName: record.groupName.trim(),
          lookup: themeLookup,
        );
        final updatedCounter = (existingCounter ??
                CounterModel(
                  name: counterName,
                  groupName: record.groupName.trim(),
                  color: resolvedThemeColor ?? _defaultImportedCounterColor,
                ))
            .copyWith(
          color: _shouldApplyAutoThemeColor(existingCounter?.color)
              ? (resolvedThemeColor ??
                  existingCounter?.color ??
                  _defaultImportedCounterColor)
              : existingCounter?.color,
          threeInchCount:
              (existingCounter?.threeInchCount ?? 0) + record.threeInchCount,
          fiveInchCount:
              (existingCounter?.fiveInchCount ?? 0) + record.fiveInchCount,
          groupCutCount:
              (existingCounter?.groupCutCount ?? 0) + record.groupCutCount,
          threeInchShukudaiCount:
              (existingCounter?.threeInchShukudaiCount ?? 0) +
                  record.threeInchShukudaiCount,
          fiveInchShukudaiCount: (existingCounter?.fiveInchShukudaiCount ?? 0) +
              record.fiveInchShukudaiCount,
        );

        CounterModel persistedCounter;
        if (existingCounter?.id != null) {
          await txn.update(
            tableName,
            _toDatabaseMap(updatedCounter),
            where: 'id = ?',
            whereArgs: [existingCounter!.id],
          );
          persistedCounter = updatedCounter.copyWith(id: existingCounter.id);
        } else {
          final insertedId = await txn.insert(
            tableName,
            _toDatabaseMap(updatedCounter),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          persistedCounter = updatedCounter.copyWith(id: insertedId);
        }

        countersByKey[key] = persistedCounter;
        await txn.insert(
          counterSyncTableName,
          {
            'source': source,
            'source_record_id': sourceRecordId,
            'applied_at': DateTime.now().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        syncedIds.add(sourceRecordId);
        appliedCount += 1;
      }

      return appliedCount;
    });
  }

  static Future<int> autoAssignCounterThemeColors({
    bool overwriteExisting = false,
  }) async {
    final db = await database;
    final counters = await getCounters();
    if (counters.isEmpty) {
      return 0;
    }

    final themeLookup = await _buildCounterThemeLookup();
    if (themeLookup.byGroupAndMember.isEmpty &&
        themeLookup.byUniqueMember.isEmpty) {
      return 0;
    }

    var updatedCount = 0;
    await db.transaction((txn) async {
      for (final counter in counters) {
        if (counter.id == null) {
          continue;
        }
        if (!overwriteExisting && !_shouldApplyAutoThemeColor(counter.color)) {
          continue;
        }

        final resolvedThemeColor = _resolveCounterThemeColor(
          name: counter.name,
          groupName: counter.groupName,
          lookup: themeLookup,
        );
        if (resolvedThemeColor == null) {
          continue;
        }
        if (_normalizeHexColor(counter.color) == resolvedThemeColor) {
          continue;
        }

        final nextCounter = counter.copyWith(color: resolvedThemeColor);
        await txn.update(
          tableName,
          _toDatabaseMap(nextCounter),
          where: 'id = ?',
          whereArgs: [counter.id],
        );
        updatedCount += 1;
      }
    });

    return updatedCount;
  }

  static const String _defaultImportedCounterColor = '#FFE135';

  static Future<_CounterThemeLookup> _buildCounterThemeLookup() async {
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final members = await IdolDatabaseService.getMembers();

    final byGroupAndMember = <String, String>{};
    final memberColorSets = <String, Set<String>>{};

    for (final member in members) {
      final themeColor = _normalizeHexColor(member.themeColorHex);
      if (themeColor == null) {
        continue;
      }

      final normalizedGroup = _normalizeLookupPart(member.groupName);
      for (final candidateName in _buildMemberNameAliases(member)) {
        final normalizedMember = _normalizeLookupPart(candidateName);
        if (normalizedMember.isEmpty) {
          continue;
        }

        if (normalizedGroup.isNotEmpty) {
          byGroupAndMember.putIfAbsent(
            '$normalizedGroup|$normalizedMember',
            () => themeColor,
          );
        }

        final colorsForMember = memberColorSets.putIfAbsent(
          normalizedMember,
          () => <String>{},
        );
        colorsForMember.add(themeColor);
      }
    }

    return _CounterThemeLookup(
      byGroupAndMember: byGroupAndMember,
      byUniqueMember: {
        for (final entry in memberColorSets.entries)
          if (entry.value.length == 1) entry.key: entry.value.first,
      },
    );
  }

  static Set<String> _buildMemberNameAliases(IdolMember member) {
    final candidates = <String>{
      member.name,
      member.displayName,
    };

    final expanded = <String>{};
    for (final candidate in candidates) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty) {
        continue;
      }

      expanded.add(trimmed);
      expanded.addAll(
        trimmed
            .split(RegExp(r'[—－\-/／|]+'))
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty),
      );

      final withoutAscii = trimmed.replaceAll(RegExp(r'[A-Za-z0-9]+'), ' ');
      if (withoutAscii.trim().isNotEmpty) {
        expanded.add(withoutAscii.trim());
      }

      final withoutDecorations = trimmed.replaceAll(
        RegExp(r'[^0-9A-Za-z\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]+'),
        ' ',
      );
      if (withoutDecorations.trim().isNotEmpty) {
        expanded.add(withoutDecorations.trim());
      }
    }

    return expanded;
  }

  static String? _resolveCounterThemeColor({
    required String name,
    required String groupName,
    required _CounterThemeLookup lookup,
  }) {
    final normalizedName = _normalizeLookupPart(name);
    if (normalizedName.isEmpty) {
      return null;
    }

    final normalizedGroup = _normalizeLookupPart(groupName);
    if (normalizedGroup.isNotEmpty) {
      final groupMatch =
          lookup.byGroupAndMember['$normalizedGroup|$normalizedName'];
      if (groupMatch != null) {
        return groupMatch;
      }
    }

    return lookup.byUniqueMember[normalizedName];
  }

  static bool _shouldApplyAutoThemeColor(String? color) {
    final normalized = _normalizeHexColor(color);
    return normalized == null || normalized == _defaultImportedCounterColor;
  }

  static String? _normalizeHexColor(String? color) {
    if (color == null) {
      return null;
    }

    final trimmed = color.trim().toUpperCase();
    if (!RegExp(r'^#[0-9A-F]{6}$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  static String _normalizeCounterKey(String name, String groupName) {
    final normalizedName = _normalizeLookupPart(name);
    if (normalizedName.isEmpty) {
      return '';
    }
    final normalizedGroup = _normalizeLookupPart(groupName);
    return '$normalizedGroup|$normalizedName';
  }

  static String _normalizeLookupPart(String value) {
    final trimmed = value.trim().toLowerCase();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.replaceAll(
      RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
      '',
    );
  }
}

class _CounterThemeLookup {
  final Map<String, String> byGroupAndMember;
  final Map<String, String> byUniqueMember;

  const _CounterThemeLookup({
    required this.byGroupAndMember,
    required this.byUniqueMember,
  });
}
