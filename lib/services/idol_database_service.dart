import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../app_metadata.dart';
import '../models/idol_activity_event_model.dart';
import '../models/idol_database_models.dart';

class IdolDatabaseService {
  static const String _dbName = 'idol_database.db';
  static const int _version = 3;
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
    if (oldVersion < 3) {
      await _createActivityEventSchema(db);
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
    await _createActivityEventSchema(db);
  }

  static Future<void> _createActivityEventSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS idol_activity_events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source TEXT NOT NULL DEFAULT 'minecool',
        source_event_id TEXT NOT NULL,
        event_date TEXT NOT NULL,
        city TEXT NOT NULL DEFAULT '',
        venue TEXT NOT NULL DEFAULT '',
        event_name TEXT NOT NULL,
        open_time TEXT NOT NULL DEFAULT '',
        start_time TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        source_link TEXT NOT NULL DEFAULT '',
        poster_url TEXT NOT NULL DEFAULT '',
        groups_json TEXT NOT NULL DEFAULT '[]',
        synced_at TEXT NOT NULL,
        UNIQUE(source, source_event_id)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_idol_activity_events_date
      ON idol_activity_events(event_date, city, event_name)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_idol_activity_events_name
      ON idol_activity_events(event_name COLLATE NOCASE)
    ''');
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

    // Old versions had no explicit person identity. Keep migrated links null
    // until the user chooses a shared identity; names alone are insufficient.
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
      final isLatestBundle = meta['source_label'] == bundle.sourceLabel &&
          meta['generated_at'] == bundle.generatedAt;

      final currentTime = DateTime.tryParse(meta['generated_at'] ?? '');
      final assetTime = DateTime.tryParse(bundle.generatedAt);
      if (!isLatestBundle &&
          (currentTime == null ||
              (assetTime != null && assetTime.isAfter(currentTime)))) {
        await syncBuiltInData();
      }
      return;
    }

    // Initialization must not erase standalone people or manually edited data.
    await syncBuiltInData();
  }

  static Future<void> syncBuiltInData() async {
    final bundle = await _loadSeedBundle();
    await _syncBundle(bundle);
  }

  static Future<void> _syncBundle(IdolSeedBundle bundle) async {
    final db = await database;

    await db.transaction((txn) async {
      final timeRows = await txn.query('idol_meta',
          columns: ['value'], where: 'key = ?', whereArgs: ['generated_at']);
      final currentTime = timeRows.isEmpty
          ? null
          : DateTime.tryParse(timeRows.first['value'] as String);
      final incomingTime = DateTime.tryParse(bundle.generatedAt);
      if (currentTime != null &&
          incomingTime != null &&
          incomingTime.isBefore(currentTime)) {
        throw const FormatException('下载的偶像资料比本地快照旧，已保留本地资料');
      }
      final existingGroups = await txn.query('idol_groups');
      final groupsByName = <String, Map<String, Object?>>{
        for (final row in existingGroups) (row['name'] ?? '') as String: row,
      };

      for (final group in bundle.groups) {
        final groupSource =
            group.sourceLabel.isEmpty ? bundle.sourceLabel : group.sourceLabel;
        final memberSources = <String, String>{
          for (final member in group.members)
            member.name.trim():
                member.sourceLabel.isEmpty ? groupSource : member.sourceLabel,
        };
        final normalizedGroupName = group.name.trim();
        if (normalizedGroupName.isEmpty) {
          continue;
        }

        final existingGroup = groupsByName[normalizedGroupName];
        late final int groupId;

        if (existingGroup == null) {
          groupId = await txn.insert('idol_groups', {
            'name': normalizedGroupName,
            'source': groupSource,
            'is_builtin': 1,
          });
          groupsByName[normalizedGroupName] = {
            'id': groupId,
            'name': normalizedGroupName,
            'source': groupSource,
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
                'source': groupSource,
                'is_builtin': 1,
              },
              where: 'id = ?',
              whereArgs: [groupId],
            );
          }
        }

        final memberRows = await txn.query(
          'idol_members',
          columns: ['id', 'name', 'person_id', 'is_builtin'],
          where: 'group_id = ?',
          whereArgs: [groupId],
        );
        final membersByName = <String, Map<String, Object?>>{
          for (final row in memberRows) (row['name'] ?? '') as String: row,
        };
        final mergedMembers = _mergeSeedMembers(group.members);

        for (final entry in mergedMembers.entries) {
          final memberName = entry.key;
          final mergedStatus = entry.value;

          final existingMember = membersByName[memberName];
          if (existingMember == null) {
            await txn.insert('idol_members', {
              'group_id': groupId,
              // A matching display name does not establish a person's identity.
              'person_id': null,
              'name': memberName,
              'status': mergedStatus,
              'source': memberSources[memberName] ?? groupSource,
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
              // Preserve existing and explicitly chosen identity associations.
              'status': mergedStatus,
              'source': memberSources[memberName] ?? groupSource,
              'is_builtin': 1,
            },
            where: 'id = ?',
            whereArgs: [existingMember['id']],
          );
        }

        // Wiki snapshots can omit members because a page/template changed.
        // Absence is not reliable evidence of departure or deletion. Explicit
        // statuses (including former members) still update above.
      }

      await _writeMeta(txn, bundle);
    });
  }

  static Future<void> syncFromRemote({String? url}) async {
    final seedUrl = url ?? kIdolSeedUrl;
    final uri = Uri.tryParse(seedUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('偶像数据地址无效');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          '下载偶像数据失败 (${response.statusCode})',
          uri: uri,
        );
      }

      final body = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 30));
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('偶像数据格式不正确');
      }

      final bundle = IdolSeedBundle.fromJson(decoded);
      await _syncBundle(bundle);
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> syncActivityEventsFromRemote({String? url}) async {
    final eventsUrl = url ?? kIdolActivityEventsUrl;
    final uri = Uri.tryParse(eventsUrl);
    if (uri == null) {
      throw const FormatException('偶活数据地址无效');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 15));

      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          '下载偶活数据失败 (${response.statusCode})',
          uri: uri,
        );
      }

      final body = await utf8.decodeStream(response);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('偶活数据格式不正确');
      }

      final bundle = IdolActivityEventBundle.fromJson(decoded);
      await _syncActivityEventBundle(bundle);
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> syncActivityEventsFromRemoteIfStale({
    String? url,
    Duration maxAge = const Duration(hours: 12),
  }) async {
    final meta = await getMeta();
    final lastSyncedAt = DateTime.tryParse(
      meta['activity_events_synced_at'] ?? '',
    );
    if (lastSyncedAt != null &&
        DateTime.now().difference(lastSyncedAt).compareTo(maxAge) < 0) {
      return;
    }
    await syncActivityEventsFromRemote(url: url);
  }

  static Future<void> _syncActivityEventBundle(
    IdolActivityEventBundle bundle,
  ) async {
    final db = await database;
    final syncedAt = DateTime.now();

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final event in bundle.events) {
        batch.insert(
          'idol_activity_events',
          event.copyWithSyncedAt(syncedAt).toDbMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);

      await txn.delete(
        'idol_activity_events',
        where: 'source = ? AND synced_at != ?',
        whereArgs: ['minecool', syncedAt.toIso8601String()],
      );

      await txn.insert(
        'idol_meta',
        {
          'key': 'activity_events_source_url',
          'value': bundle.sourceUrl,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'idol_meta',
        {
          'key': 'activity_events_source_label',
          'value': bundle.sourceLabel,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'idol_meta',
        {
          'key': 'activity_events_generated_at',
          'value': bundle.generatedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'idol_meta',
        {
          'key': 'activity_events_synced_at',
          'value': syncedAt.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<List<IdolActivityEvent>> getActivityEvents({
    DateTime? from,
    DateTime? to,
    String query = '',
    int limit = 200,
  }) async {
    final db = await database;
    final where = <String>[];
    final whereArgs = <Object?>[];
    if (from != null) {
      where.add('event_date >= ?');
      whereArgs.add(_formatDate(from));
    }
    if (to != null) {
      where.add('event_date <= ?');
      whereArgs.add(_formatDate(to));
    }
    final normalizedQuery = query.trim();
    if (normalizedQuery.isNotEmpty) {
      where.add('''
        (
          event_name LIKE ? COLLATE NOCASE OR
          city LIKE ? COLLATE NOCASE OR
          venue LIKE ? COLLATE NOCASE OR
          groups_json LIKE ? COLLATE NOCASE
        )
      ''');
      final pattern = '%$normalizedQuery%';
      whereArgs.addAll([pattern, pattern, pattern, pattern]);
    }

    final maps = await db.query(
      'idol_activity_events',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: whereArgs,
      orderBy: 'event_date ASC, city COLLATE NOCASE ASC, event_name ASC',
      limit: limit,
    );
    return maps.map(IdolActivityEvent.fromMap).toList(growable: false);
  }

  static Future<void> restoreBuiltInData() async {
    final db = await database;
    final bundle = await _loadSeedBundle();

    await db.transaction((txn) async {
      await txn.delete('idol_members');
      await txn.delete('idol_groups');
      await txn.delete('idol_people');
      await txn.delete('idol_meta');

      for (final group in bundle.groups) {
        final groupSource =
            group.sourceLabel.isEmpty ? bundle.sourceLabel : group.sourceLabel;
        final memberSources = <String, String>{
          for (final member in group.members)
            member.name.trim():
                member.sourceLabel.isEmpty ? groupSource : member.sourceLabel,
        };
        final normalizedGroupName = group.name.trim();
        if (normalizedGroupName.isEmpty) {
          continue;
        }

        final groupId = await txn.insert('idol_groups', {
          'name': normalizedGroupName,
          'source': groupSource,
          'is_builtin': 1,
        });

        final mergedMembers = _mergeSeedMembers(group.members);
        for (final entry in mergedMembers.entries) {
          final memberName = entry.key;
          final mergedStatus = entry.value;

          await txn.insert(
            'idol_members',
            {
              'group_id': groupId,
              'person_id': null,
              'name': memberName,
              'status': mergedStatus,
              'source': memberSources[memberName] ?? groupSource,
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
    final where = groupId == null ? '' : 'WHERE idol_members.group_id = ?';
    final whereArgs = groupId == null ? <Object?>[] : <Object?>[groupId];
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
      $where
      ORDER BY idol_groups.name COLLATE NOCASE ASC, idol_members.name COLLATE NOCASE ASC
    ''', whereArgs);

    return maps
        .map(IdolMember.fromMap)
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
      return db.transaction((txn) async {
        final existing = await txn.query('idol_groups',
            columns: ['id'], where: 'name = ?', whereArgs: [group.name.trim()]);
        if (existing.isEmpty) {
          return txn.insert('idol_groups', payload);
        }
        final id = existing.first['id'] as int;
        await txn
            .update('idol_groups', payload, where: 'id = ?', whereArgs: [id]);
        return id;
      });
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
    return db.transaction((txn) async {
      final explicitName = member.personName.trim();
      final personId = explicitName.isEmpty
          ? member.personId
          : await _ensurePerson(
              txn,
              name: explicitName,
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
        final existing = await txn.query('idol_members',
            columns: ['id'],
            where: 'group_id = ? AND name = ?',
            whereArgs: [member.groupId, member.name.trim()]);
        if (existing.isEmpty) {
          return txn.insert('idol_members', payload);
        }
        final id = existing.first['id'] as int;
        await txn
            .update('idol_members', payload, where: 'id = ?', whereArgs: [id]);
        return id;
      }

      await txn.update(
        'idol_members',
        payload,
        where: 'id = ?',
        whereArgs: [member.id],
      );
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
      final statuses = entry.value.where((value) => value.isNotEmpty).toList()
        ..sort();
      merged[entry.key] = statuses.join(' / ');
    }
    return merged;
  }

  static String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }
}
