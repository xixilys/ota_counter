import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/idol_database_models.dart';

class IdolDatabaseService {
  static const String _dbName = 'idol_database.db';
  static const int _version = 2;
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
          onUpgrade: _onUpgrade,
        ),
      );
    }

    return openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
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
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE idol_people(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL DEFAULT 'manual',
        is_builtin INTEGER NOT NULL DEFAULT 0
      )
    ''');

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
        person_id INTEGER,
        name TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'manual',
        is_builtin INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY(group_id) REFERENCES idol_groups(id) ON DELETE CASCADE,
        FOREIGN KEY(person_id) REFERENCES idol_people(id) ON DELETE SET NULL,
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
    await db.execute(
      'CREATE INDEX idx_idol_members_person_id ON idol_members(person_id)',
    );
  }

  static Future<void> _migrateToV2(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS idol_people(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        source TEXT NOT NULL DEFAULT 'manual',
        is_builtin INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'ALTER TABLE idol_members ADD COLUMN person_id INTEGER',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_idol_members_person_id ON idol_members(person_id)',
    );

    final memberRows = await db.query(
      'idol_members',
      columns: ['id', 'name', 'source', 'is_builtin'],
    );
    final peopleByKey = <String, int>{};

    await db.transaction((txn) async {
      for (final row in memberRows) {
        final memberId = (row['id'] as num?)?.toInt();
        if (memberId == null) {
          continue;
        }

        final personName = _defaultPersonNameForName(
          (row['name'] ?? '') as String,
        );
        if (personName.isEmpty) {
          continue;
        }

        final normalized = _normalizeLookupValue(personName);
        if (normalized.isEmpty) {
          continue;
        }

        final personId = peopleByKey[normalized] ??
            await _ensurePerson(
              txn,
              name: personName,
              source: (row['source'] ?? 'manual') as String,
              isBuiltIn: ((row['is_builtin'] ?? 0) as num).toInt() == 1,
            );
        peopleByKey[normalized] = personId;

        await txn.update(
          'idol_members',
          {'person_id': personId},
          where: 'id = ?',
          whereArgs: [memberId],
        );
      }
    });
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
        final normalizedGroupName = group.name.trim();
        if (normalizedGroupName.isEmpty) {
          continue;
        }

        final existingGroup = groupsByName[normalizedGroupName];
        late final int groupId;

        if (existingGroup == null) {
          groupId = await txn.insert('idol_groups', {
            'name': normalizedGroupName,
            'source': bundle.sourceLabel,
            'is_builtin': 1,
          });
          groupsByName[normalizedGroupName] = {
            'id': groupId,
            'name': normalizedGroupName,
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
        final mergedMembers = _mergeSeedMembers(group.members);
        final seedNames = <String>{};

        for (final entry in mergedMembers.entries) {
          final memberName = entry.key;
          final mergedStatus = entry.value;
          seedNames.add(memberName);

          final personId = await _ensurePerson(
            txn,
            name: _defaultPersonNameForName(memberName),
            source: bundle.sourceLabel,
            isBuiltIn: true,
          );

          final existingMember = membersByName[memberName];
          if (existingMember == null) {
            await txn.insert('idol_members', {
              'group_id': groupId,
              'person_id': personId,
              'name': memberName,
              'status': mergedStatus,
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
              'person_id': personId,
              'status': mergedStatus,
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

      await _cleanupUnusedPeople(txn);
      await _writeMeta(txn, bundle);
    });
  }

  static Future<void> restoreBuiltInData() async {
    final db = await database;
    final bundle = await _loadSeedBundle();

    await db.transaction((txn) async {
      await txn.delete('idol_members');
      await txn.delete('idol_groups');
      await txn.delete('idol_people');
      await txn.delete('idol_meta');

      final peopleByKey = <String, int>{};
      for (final group in bundle.groups) {
        final normalizedGroupName = group.name.trim();
        if (normalizedGroupName.isEmpty) {
          continue;
        }

        final groupId = await txn.insert('idol_groups', {
          'name': normalizedGroupName,
          'source': bundle.sourceLabel,
          'is_builtin': 1,
        });

        final mergedMembers = _mergeSeedMembers(group.members);
        for (final entry in mergedMembers.entries) {
          final memberName = entry.key;
          final mergedStatus = entry.value;
          final personName = _defaultPersonNameForName(memberName);
          final normalizedPerson = _normalizeLookupValue(personName);
          if (normalizedPerson.isEmpty) {
            continue;
          }

          final personId = peopleByKey[normalizedPerson] ??
              await _ensurePerson(
                txn,
                name: personName,
                source: bundle.sourceLabel,
                isBuiltIn: true,
              );
          peopleByKey[normalizedPerson] = personId;

          await txn.insert(
            'idol_members',
            {
              'group_id': groupId,
              'person_id': personId,
              'name': memberName,
              'status': mergedStatus,
              'source': bundle.sourceLabel,
              'is_builtin': 1,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }

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

  static Future<List<IdolPerson>> getPeople() async {
    final db = await database;
    final maps = await db.query(
      'idol_people',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return maps.map(IdolPerson.fromMap).toList();
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
        idol_members.person_id,
        idol_members.name,
        idol_members.status,
        idol_members.source,
        idol_members.is_builtin,
        idol_groups.name AS group_name,
        idol_people.name AS person_name
      FROM idol_members
      INNER JOIN idol_groups ON idol_groups.id = idol_members.group_id
      LEFT JOIN idol_people ON idol_people.id = idol_members.person_id
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

  static Future<int> upsertPerson(IdolPerson person) async {
    final db = await database;
    return db.transaction((txn) async {
      return _ensurePerson(
        txn,
        name: person.name,
        source: person.source,
        isBuiltIn: person.isBuiltIn,
        preferredId: person.id,
      );
    });
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
      await _cleanupUnusedPeople(txn);
    });
  }

  static Future<int> upsertMember(IdolMember member) async {
    final db = await database;
    return db.transaction((txn) async {
      final personId = await _ensurePerson(
        txn,
        name: member.resolvedPersonName,
        source: member.source,
        isBuiltIn: member.isBuiltIn,
        preferredId: member.personId,
      );

      final payload = {
        'group_id': member.groupId,
        'person_id': personId,
        'name': member.name.trim(),
        'status': member.status.trim(),
        'source': member.source,
        'is_builtin': member.isBuiltIn ? 1 : 0,
      };

      if (member.id == null) {
        return txn.insert(
          'idol_members',
          payload,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await txn.update(
        'idol_members',
        payload,
        where: 'id = ?',
        whereArgs: [member.id],
      );
      await _cleanupUnusedPeople(txn);
      return member.id!;
    });
  }

  static Future<void> deleteMember(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'idol_members',
        where: 'id = ?',
        whereArgs: [id],
      );
      await _cleanupUnusedPeople(txn);
    });
  }

  static Future<int> _ensurePerson(
    DatabaseExecutor db, {
    required String name,
    required String source,
    required bool isBuiltIn,
    int? preferredId,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError('Person name cannot be empty.');
    }

    if (preferredId != null) {
      await db.update(
        'idol_people',
        {
          'name': normalizedName,
          'source': source,
          'is_builtin': isBuiltIn ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [preferredId],
      );
      return preferredId;
    }

    final existing = await db.query(
      'idol_people',
      columns: ['id', 'is_builtin'],
      where: 'name = ?',
      whereArgs: [normalizedName],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final row = existing.first;
      final personId = ((row['id'] ?? 0) as num).toInt();
      final alreadyBuiltIn = ((row['is_builtin'] ?? 0) as num).toInt() == 1;
      if (!alreadyBuiltIn && isBuiltIn) {
        await db.update(
          'idol_people',
          {
            'source': source,
            'is_builtin': 1,
          },
          where: 'id = ?',
          whereArgs: [personId],
        );
      }
      return personId;
    }

    return db.insert(
      'idol_people',
      {
        'name': normalizedName,
        'source': source,
        'is_builtin': isBuiltIn ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  static Future<void> _cleanupUnusedPeople(DatabaseExecutor db) async {
    await db.execute('''
      DELETE FROM idol_people
      WHERE id NOT IN (
        SELECT DISTINCT person_id
        FROM idol_members
        WHERE person_id IS NOT NULL
      )
    ''');
  }

  static Map<String, String> _mergeSeedMembers(List<IdolSeedMember> members) {
    final membersByName = <String, Set<String>>{};
    for (final member in members) {
      final name = member.name.trim();
      if (name.isEmpty) {
        continue;
      }
      final status = member.status.trim();
      membersByName.putIfAbsent(name, () => <String>{}).add(status);
    }

    final merged = <String, String>{};
    for (final entry in membersByName.entries) {
      final statuses =
          entry.value.where((value) => value.isNotEmpty).toList()..sort();
      merged[entry.key] = statuses.join(' / ');
    }
    return merged;
  }

  static String _defaultPersonNameForName(String rawName) {
    final displayName = IdolMember(
      groupId: 0,
      groupName: '',
      name: rawName,
    ).displayName.trim();
    if (displayName.isNotEmpty) {
      return displayName;
    }
    return rawName.trim();
  }

  static String _normalizeLookupValue(String value) {
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
