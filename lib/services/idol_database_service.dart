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
      final bundle = await _loadSeedBundle();
      final meta = await getMeta();
      final isLatestBundle =
          meta['source_label'] == bundle.sourceLabel &&
          meta['generated_at'] == bundle.generatedAt;

      if (!isLatestBundle) {
        await syncBuiltInData();
      }
      return;
    }

    await restoreBuiltInData();
  }

  static Future<void> syncBuiltInData() async {
    final db = await database;
    final bundle = await _loadSeedBundle();

    await db.transaction((txn) async {
      final existingGroups = await txn.query('idol_groups');
      final groupsByName = <String, Map<String, Object?>>{
        for (final row in existingGroups) (row['name'] ?? '') as String: row,
      };

      for (final group in bundle.groups) {
        final existingGroup = groupsByName[group.name];
        late final int groupId;

        if (existingGroup == null) {
          groupId = await txn.insert('idol_groups', {
            'name': group.name,
            'source': bundle.sourceLabel,
            'is_builtin': 1,
          });
          groupsByName[group.name] = {
            'id': groupId,
            'name': group.name,
            'source': bundle.sourceLabel,
            'is_builtin': 1,
          };
        } else {
          groupId = ((existingGroup['id'] ?? 0) as num).toInt();
          final isBuiltIn =
              ((existingGroup['is_builtin'] ?? 0) as num).toInt() == 1;

          if (isBuiltIn) {
            await txn.update(
              'idol_groups',
              {
                'source': bundle.sourceLabel,
                'is_builtin': 1,
              },
              where: 'id = ?',
              whereArgs: [groupId],
            );
          }
        }

        final memberRows = await txn.query(
          'idol_members',
          columns: ['id', 'name', 'is_builtin'],
          where: 'group_id = ?',
          whereArgs: [groupId],
        );
        final membersByName = <String, Map<String, Object?>>{
          for (final row in memberRows) (row['name'] ?? '') as String: row,
        };
        final seedNames = <String>{};

        for (final member in group.members) {
          final name = member.name.trim();
          if (name.isEmpty) {
            continue;
          }

          seedNames.add(name);
          final existingMember = membersByName[name];

          if (existingMember == null) {
            await txn.insert('idol_members', {
              'group_id': groupId,
              'name': name,
              'status': member.status.trim(),
              'source': bundle.sourceLabel,
              'is_builtin': 1,
            });
            continue;
          }

          final isBuiltIn =
              ((existingMember['is_builtin'] ?? 0) as num).toInt() == 1;
          if (!isBuiltIn) {
            continue;
          }

          await txn.update(
            'idol_members',
            {
              'status': member.status.trim(),
              'source': bundle.sourceLabel,
              'is_builtin': 1,
            },
            where: 'id = ?',
            whereArgs: [existingMember['id']],
          );
        }

        final deleteWhere = StringBuffer('group_id = ? AND is_builtin = 1');
        final deleteArgs = <Object?>[groupId];
        if (seedNames.isNotEmpty) {
          final placeholders = List.filled(seedNames.length, '?').join(', ');
          deleteWhere.write(' AND name NOT IN ($placeholders)');
          deleteArgs.addAll(seedNames);
        }

        await txn.delete(
          'idol_members',
          where: deleteWhere.toString(),
          whereArgs: deleteArgs,
        );
      }

      await _writeMeta(txn, bundle);
    });
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

        // Some upstream sources may list the same member multiple times with
        // different status (e.g. current vs past roster). We keep a single row
        // per (group, member) and merge distinct status strings.
        final membersByName = <String, Set<String>>{};
        for (final member in group.members) {
          final name = member.name.trim();
          if (name.isEmpty) {
            continue;
          }
          final status = member.status.trim();
          membersByName.putIfAbsent(name, () => <String>{}).add(status);
        }

        for (final entry in membersByName.entries) {
          final statuses =
              entry.value.where((value) => value.isNotEmpty).toList()..sort();
          final mergedStatus = statuses.join(' / ');

          memberBatch.insert(
            'idol_members',
            {
              'group_id': groupId,
              'name': entry.key,
              'status': mergedStatus,
              'source': bundle.sourceLabel,
              'is_builtin': 1,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await memberBatch.commit(noResult: true);

      await _writeMeta(txn, bundle);
    });
  }

  static Future<void> _writeMeta(
    DatabaseExecutor db,
    IdolSeedBundle bundle,
  ) async {
    final batch = db.batch();
    batch.insert(
      'idol_meta',
      {
        'key': 'source_url',
        'value': bundle.sourceUrl,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'idol_meta',
      {
        'key': 'source_label',
        'value': bundle.sourceLabel,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    batch.insert(
      'idol_meta',
      {
        'key': 'generated_at',
        'value': bundle.generatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await batch.commit(noResult: true);
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
