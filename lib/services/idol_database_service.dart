import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/idol_database_models.dart';

class IdolDatabaseService {
  static const String _dbName = 'idol_database.db';
  static const int _version = 1;
  static const String _seedAssetPath = 'assets/data/china_idols_seed.json';

  static Database? _database;
  static Future<void>? _ensureSeedFuture;
  static IdolSeedBundle? _cachedSeedBundle;

  static Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), _dbName);

    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      sqfliteFfiInit();
      final databaseFactory = databaseFactoryFfi;
      return databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: _version,
          onCreate: _onCreate,
        ),
      );
    }

    return openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE idol_groups(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL DEFAULT 'manual',
        is_builtin INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE idol_members(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'manual',
        is_builtin INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(group_id) REFERENCES idol_groups(id) ON DELETE CASCADE,
        UNIQUE(group_id, name)
      )
    ''');

    await db.execute('''
      CREATE TABLE idol_meta(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_idol_members_group_id ON idol_members(group_id)',
    );
  }

  static Future<void> initializeBuiltInDataIfNeeded() async {
    _ensureSeedFuture ??= _initializeBuiltInDataIfNeededInternal();
    return _ensureSeedFuture!;
  }

  static Future<void> _initializeBuiltInDataIfNeededInternal() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM idol_groups'),
    );

    if ((count ?? 0) > 0) {
      return;
    }

    await restoreBuiltInData();
  }

  static Future<void> restoreBuiltInData() async {
    final db = await database;
    final bundle = await _loadSeedBundle();

    await db.transaction((txn) async {
      await txn.delete('idol_members');
      await txn.delete('idol_groups');
      await txn.delete('idol_meta');

      final memberBatch = txn.batch();
      for (final group in bundle.groups) {
        final groupId = await txn.insert('idol_groups', {
          'name': group.name,
          'source': bundle.sourceLabel,
          'is_builtin': 1,
        });

        for (final member in group.members) {
          memberBatch.insert('idol_members', {
            'group_id': groupId,
            'name': member.name,
            'status': member.status,
            'source': bundle.sourceLabel,
            'is_builtin': 1,
          });
        }
      }
      await memberBatch.commit(noResult: true);

      await txn.insert('idol_meta', {
        'key': 'source_url',
        'value': bundle.sourceUrl,
      });
      await txn.insert('idol_meta', {
        'key': 'source_label',
        'value': bundle.sourceLabel,
      });
      await txn.insert('idol_meta', {
        'key': 'generated_at',
        'value': bundle.generatedAt,
      });
    });
  }

  static Future<IdolSeedBundle> _loadSeedBundle() async {
    if (_cachedSeedBundle != null) {
      return _cachedSeedBundle!;
    }

    final raw = await rootBundle.loadString(_seedAssetPath);
    _cachedSeedBundle = IdolSeedBundle.fromJson(
      jsonDecode(raw) as Map<String, Object?>,
    );
    return _cachedSeedBundle!;
  }

  static Future<List<IdolGroup>> getGroups() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT
        idol_groups.id,
        idol_groups.name,
        idol_groups.source,
        idol_groups.is_builtin,
        COUNT(idol_members.id) AS member_count
      FROM idol_groups
      LEFT JOIN idol_members ON idol_members.group_id = idol_groups.id
      GROUP BY idol_groups.id
      ORDER BY idol_groups.name COLLATE NOCASE ASC
    ''');

    return maps.map(IdolGroup.fromMap).toList();
  }

  static Future<List<IdolMember>> getMembers({
    int? groupId,
    String query = '',
  }) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT
        idol_members.id,
        idol_members.group_id,
        idol_members.name,
        idol_members.status,
        idol_members.source,
        idol_members.is_builtin,
        idol_groups.name AS group_name
      FROM idol_members
      INNER JOIN idol_groups ON idol_groups.id = idol_members.group_id
      ORDER BY idol_groups.name COLLATE NOCASE ASC, idol_members.name COLLATE NOCASE ASC
    ''');

    return maps
        .map(IdolMember.fromMap)
        .where((member) => groupId == null || member.groupId == groupId)
        .where((member) => member.matchesQuery(query))
        .toList();
  }

  static Future<Map<String, String>> getMeta() async {
    final db = await database;
    final maps = await db.query('idol_meta');

    return {
      for (final row in maps)
        (row['key'] ?? '') as String: (row['value'] ?? '') as String,
    };
  }

  static Future<int> upsertGroup(IdolGroup group) async {
    final db = await database;
    final payload = {
      'name': group.name.trim(),
      'source': group.source,
      'is_builtin': group.isBuiltIn ? 1 : 0,
    };

    if (group.id == null) {
      return db.insert(
        'idol_groups',
        payload,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await db.update(
      'idol_groups',
      payload,
      where: 'id = ?',
      whereArgs: [group.id],
    );
    return group.id!;
  }

  static Future<void> deleteGroup(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'idol_members',
        where: 'group_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        'idol_groups',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  static Future<int> upsertMember(IdolMember member) async {
    final db = await database;
    final payload = {
      'group_id': member.groupId,
      'name': member.name.trim(),
      'status': member.status.trim(),
      'source': member.source,
      'is_builtin': member.isBuiltIn ? 1 : 0,
    };

    if (member.id == null) {
      return db.insert(
        'idol_members',
        payload,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await db.update(
      'idol_members',
      payload,
      where: 'id = ?',
      whereArgs: [member.id],
    );
    return member.id!;
  }

  static Future<void> deleteMember(int id) async {
    final db = await database;
    await db.delete(
      'idol_members',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
