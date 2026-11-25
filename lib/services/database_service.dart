import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/activity_record_model.dart';
import '../models/activity_record_media_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../models/idol_database_models.dart';
import 'album_clarity_service.dart';
import 'album_camera_recovery.dart';
import 'idol_database_service.dart';

class DatabaseService {
  static const String _dbName = 'counter_app.db';
  static const String tableName = 'counters';
  static const String groupPricingTableName = 'group_pricings';
  static const String activityRecordTableName = 'activity_records';
  static const String activityRecordMediaTableName = 'activity_record_media';
  static const String counterSyncTableName = 'counter_sync_log';
  static const String merchKindTableName = 'merch_kinds';
  static const String merchPurchaseTableName = 'merch_purchases';

  /// On-device face embeddings for 批量拍切. Private: deliberately left out of
  /// full backups (see ExportImportService._buildFullBackupBundle).
  static const String faceSamplesTableName = 'face_samples';
  static const String faceEnrollmentActionsTableName =
      'face_enrollment_actions';
  static const int _version = 23;

  static Database? _database;
  static Future<Database>? _databaseOpening;
  static final Map<String, Set<String>> _tableColumnsCache = {};

  static Future<Database> get database {
    final cachedDatabase = _database;
    if (cachedDatabase != null) {
      return Future<Database>.value(cachedDatabase);
    }

    final openingDatabase = _databaseOpening;
    if (openingDatabase != null) {
      return openingDatabase;
    }

    final future = _openDatabaseOnce();
    _databaseOpening = future;
    return future;
  }

  static Future<Database> _openDatabaseOnce() async {
    try {
      final openedDatabase = await _initDatabase();
      _database = openedDatabase;
      return openedDatabase;
    } finally {
      _databaseOpening = null;
    }
  }

  static Future<Database> _initDatabase() async {
    final path = join(await getDatabasesPath(), _dbName);
    late final Database db;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      db = await openDatabase(
        path,
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onOpen: _onOpen,
      );
      await _ensureLatestSchema(db);
      return db;
    }

    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;

    db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onOpen: _onOpen,
      ),
    );
    await _ensureLatestSchema(db);
    return db;
  }

  static Future<void> _onCreate(Database db, int version) async {
    await _createSchema(db);
    await _ensureLatestSchema(db);
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
    if (oldVersion < 9) {
      await _migrateToV9(db);
    }
    if (oldVersion < 10) {
      await _migrateToV10(db);
    }
    if (oldVersion < 11) {
      await _migrateToV11(db);
    }
    if (oldVersion < 12) {
      await _migrateToV12(db);
    }
    if (oldVersion < 13) {
      await _migrateToV13(db);
    }
    if (oldVersion < 14) {
      await _migrateToV14(db);
    }
    if (oldVersion < 15) {
      await _migrateToV15(db);
    }
    if (oldVersion < 16) {
      await _migrateToV16(db);
    }
    if (oldVersion < 17) {
      await _migrateToV17(db);
    }
    if (oldVersion < 18) {
      await _migrateToV18(db);
    }
    if (oldVersion < 19) {
      await _migrateToV19(db);
    }
    if (oldVersion < 20) {
      await _migrateToV20(db);
    }
    if (oldVersion < 21) {
      await _migrateToV21(db);
    }
    if (oldVersion < 23) {
      await _migrateToV23(db);
    }
    await _ensureLatestSchema(db);
  }

  static Future<void> _onOpen(Database db) async {
    await _ensureLatestSchema(db);
  }

  static Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        group_name TEXT NOT NULL DEFAULT '',
        person_id INTEGER,
        person_name TEXT NOT NULL DEFAULT '',
        short_name TEXT NOT NULL DEFAULT '',
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
      CREATE INDEX IF NOT EXISTS idx_counters_person_id
      ON $tableName(person_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_counters_name_group
      ON $tableName(name COLLATE NOCASE, group_name COLLATE NOCASE)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $groupPricingTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_name TEXT NOT NULL UNIQUE,
        label TEXT NOT NULL DEFAULT '',
        enable_unsigned INTEGER NOT NULL DEFAULT 0,
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        unsigned_three_inch_price REAL NOT NULL DEFAULT 0,
        unsigned_five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        double_cut_price REAL NOT NULL DEFAULT 0,
        three_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        five_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        custom_cheki_types_json TEXT NOT NULL DEFAULT '[]',
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $activityRecordTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_type TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'local',
        source_record_id TEXT,
        group_record_id TEXT,
        is_system_adjustment INTEGER DEFAULT 0,
        counter_id INTEGER,
        person_id INTEGER,
        person_name TEXT NOT NULL DEFAULT '',
        subject_name TEXT NOT NULL,
        secondary_subject_name TEXT NOT NULL DEFAULT '',
        group_name TEXT NOT NULL DEFAULT '',
        session_label TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        occurred_at TEXT NOT NULL,
        pricing_label TEXT NOT NULL DEFAULT '',
        uses_current_pricing INTEGER,
        three_inch_count INTEGER NOT NULL DEFAULT 0,
        five_inch_count INTEGER NOT NULL DEFAULT 0,
        unsigned_three_inch_count INTEGER NOT NULL DEFAULT 0,
        unsigned_five_inch_count INTEGER NOT NULL DEFAULT 0,
        group_cut_count INTEGER NOT NULL DEFAULT 0,
        three_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        five_inch_shukudai_count INTEGER NOT NULL DEFAULT 0,
        multi_cut_quantity INTEGER NOT NULL DEFAULT 0,
        double_cut_quantity INTEGER NOT NULL DEFAULT 0,
        ticket_quantity INTEGER NOT NULL DEFAULT 0,
        ticket_type TEXT NOT NULL DEFAULT '',
        ticket_is_free INTEGER,
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        unsigned_three_inch_price REAL NOT NULL DEFAULT 0,
        unsigned_five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        double_cut_unit_price REAL NOT NULL DEFAULT 0,
        three_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        five_inch_shukudai_price REAL NOT NULL DEFAULT 0,
        ticket_unit_price REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL DEFAULT 0,
        multi_participants_json TEXT NOT NULL DEFAULT '[]',
        custom_cheki_counts_json TEXT NOT NULL DEFAULT '[]'
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
      CREATE INDEX IF NOT EXISTS idx_activity_records_counter_id
      ON $activityRecordTableName(counter_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_records_person_id
      ON $activityRecordTableName(person_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_records_type
      ON $activityRecordTableName(record_type)
    ''');
    await _createTicketTypeCatalogSchema(db);
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ticket_price_presets(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scope_key TEXT NOT NULL,
        event_name TEXT NOT NULL DEFAULT '',
        venue_name TEXT NOT NULL DEFAULT '',
        group_name TEXT NOT NULL DEFAULT '',
        ticket_type TEXT NOT NULL,
        unit_price REAL NOT NULL DEFAULT 0,
        is_free INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        UNIQUE(scope_key, ticket_type)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_ticket_price_presets_scope
      ON ticket_price_presets(scope_key, ticket_type)
    ''');
    await _createMerchSchema(db);
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $activityRecordMediaTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'memory',
        processing_mode TEXT NOT NULL DEFAULT 'none',
        is_reversed INTEGER NOT NULL DEFAULT 0,
        owner_person_id INTEGER,
        owner_person_name TEXT NOT NULL DEFAULT '',
        owner_group_name TEXT NOT NULL DEFAULT '',
        captured_at TEXT,
        source_hash TEXT NOT NULL DEFAULT '',
        crop_quad_json TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_record_media_record_id
      ON $activityRecordMediaTableName(record_id, created_at DESC)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $counterSyncTableName(
        source TEXT NOT NULL,
        source_record_id TEXT NOT NULL,
        applied_at TEXT NOT NULL,
        PRIMARY KEY(source, source_record_id)
      )
    ''');
    await _createFaceSamplesSchema(db);
    // Durable receipts survive ACK/network failures and sample-cap eviction.
    // Stored locally only, together with the private face samples.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $faceEnrollmentActionsTableName(
        server_url TEXT NOT NULL,
        action_id TEXT NOT NULL,
        result_json TEXT,
        failure TEXT,
        PRIMARY KEY(server_url, action_id)
      )
    ''');
    _tableColumnsCache.clear();
  }

  static Future<void> _createFaceSamplesSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $faceSamplesTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        person_id INTEGER,
        person_name TEXT NOT NULL DEFAULT '',
        counter_id INTEGER,
        is_self INTEGER NOT NULL DEFAULT 0,
        media_id INTEGER,
        face_box_json TEXT NOT NULL DEFAULT '{}',
        embedding BLOB NOT NULL,
        model_id TEXT NOT NULL,
        quality REAL NOT NULL DEFAULT 0,
        source TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_face_samples_person
      ON $faceSamplesTableName(is_self, person_id, person_name)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_face_samples_media
      ON $faceSamplesTableName(media_id)
    ''');
  }

  /// 周边 purchases are their own ledger: they are purchases, not cheki
  /// activity, so they must not feed member counters, chart revenue or the
  /// MCP record stream. Full backups include both tables.
  static Future<void> _createMerchSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $merchKindTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        default_price REAL NOT NULL DEFAULT 0,
        is_preset INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $merchPurchaseTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL DEFAULT '',
        member_name TEXT NOT NULL DEFAULT '',
        group_name TEXT NOT NULL DEFAULT '',
        event_name TEXT NOT NULL DEFAULT '',
        venue_name TEXT NOT NULL DEFAULT '',
        session_label TEXT NOT NULL DEFAULT '',
        note TEXT NOT NULL DEFAULT '',
        quantity INTEGER NOT NULL DEFAULT 1,
        unit_price REAL NOT NULL DEFAULT 0,
        total_amount REAL NOT NULL DEFAULT 0,
        photo_path TEXT NOT NULL DEFAULT '',
        occurred_at TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_merch_purchases_occurred_at
      ON $merchPurchaseTableName(occurred_at DESC)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_merch_purchases_kind
      ON $merchPurchaseTableName(kind)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_merch_purchases_member
      ON $merchPurchaseTableName(member_name)
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
        double_cut_price REAL NOT NULL DEFAULT 0,
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
        secondary_subject_name TEXT NOT NULL DEFAULT '',
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
        double_cut_quantity INTEGER NOT NULL DEFAULT 0,
        ticket_quantity INTEGER NOT NULL DEFAULT 0,
        three_inch_price REAL NOT NULL DEFAULT 0,
        five_inch_price REAL NOT NULL DEFAULT 0,
        group_cut_price REAL NOT NULL DEFAULT 0,
        double_cut_unit_price REAL NOT NULL DEFAULT 0,
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

  static Future<void> _migrateToV9(Database db) async {
    await db.execute(
      'ALTER TABLE $groupPricingTableName ADD COLUMN double_cut_price REAL NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN secondary_subject_name TEXT NOT NULL DEFAULT \'\'',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN double_cut_quantity INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN double_cut_unit_price REAL NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _migrateToV10(Database db) async {
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN person_id INTEGER',
    );
    await db.execute(
      "ALTER TABLE $tableName ADD COLUMN person_name TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN person_id INTEGER',
    );
    await db.execute(
      "ALTER TABLE $activityRecordTableName ADD COLUMN person_name TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN multi_cut_quantity INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      "ALTER TABLE $activityRecordTableName ADD COLUMN multi_participants_json TEXT NOT NULL DEFAULT '[]'",
    );

    await _backfillIdentityAndMultiData(db);
  }

  static Future<void> _migrateToV11(Database db) async {
    await db.execute(
      'ALTER TABLE $groupPricingTableName ADD COLUMN enable_unsigned INTEGER NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _migrateToV12(Database db) async {
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN unsigned_three_inch_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $tableName ADD COLUMN unsigned_five_inch_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $groupPricingTableName ADD COLUMN unsigned_three_inch_price REAL NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $groupPricingTableName ADD COLUMN unsigned_five_inch_price REAL NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN unsigned_three_inch_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN unsigned_five_inch_count INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN unsigned_three_inch_price REAL NOT NULL DEFAULT 0',
    );
    await db.execute(
      'ALTER TABLE $activityRecordTableName ADD COLUMN unsigned_five_inch_price REAL NOT NULL DEFAULT 0',
    );
  }

  static Future<void> _migrateToV13(Database db) async {
    await db.execute(
      "ALTER TABLE $activityRecordTableName ADD COLUMN activity_name TEXT NOT NULL DEFAULT ''",
    );
    await db.execute(
      "ALTER TABLE $activityRecordTableName ADD COLUMN venue_name TEXT NOT NULL DEFAULT ''",
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $activityRecordMediaTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'memory',
        processing_mode TEXT NOT NULL DEFAULT 'none',
        is_reversed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_record_media_record_id
      ON $activityRecordMediaTableName(record_id, created_at DESC)
    ''');
  }

  static Future<void> _migrateToV14(Database db) async {
    await _ensureColumns(
      db,
      activityRecordMediaTableName,
      {
        'media_type': "TEXT NOT NULL DEFAULT 'memory'",
        'processing_mode': "TEXT NOT NULL DEFAULT 'none'",
      },
    );
  }

  static Future<void> _migrateToV15(Database db) async {
    await _ensureColumns(
      db,
      groupPricingTableName,
      {
        'custom_cheki_types_json': "TEXT NOT NULL DEFAULT '[]'",
      },
    );
    await _ensureColumns(
      db,
      activityRecordTableName,
      {
        'custom_cheki_counts_json': "TEXT NOT NULL DEFAULT '[]'",
      },
    );
  }

  static Future<void> _migrateToV16(Database db) async {
    await _ensureColumns(
      db,
      activityRecordMediaTableName,
      {
        'is_reversed': 'INTEGER NOT NULL DEFAULT 0',
      },
    );
  }

  static Future<void> _migrateToV17(Database db) async {
    await _ensureColumns(
      db,
      activityRecordTableName,
      {
        'uses_current_pricing': 'INTEGER',
      },
    );
  }

  static Future<void> _migrateToV18(Database db) async {
    await _ensureColumns(
      db,
      activityRecordMediaTableName,
      {
        'owner_person_id': 'INTEGER',
        'owner_person_name': "TEXT NOT NULL DEFAULT ''",
        'owner_group_name': "TEXT NOT NULL DEFAULT ''",
      },
    );
  }

  static Future<void> _migrateToV20(Database db) async {
    // The generic schema pass adds ticket_type / ticket_is_free columns and
    // creates the ticket catalog tables. Keeping this migration explicit makes
    // the version bump visible to future maintainers.
    await _createSchema(db);
  }

  static Future<void> _migrateToV21(Database db) async {
    // 批量拍切: face_samples table plus provenance columns on media.
    await _createFaceSamplesSchema(db);
    await _ensureColumns(db, activityRecordMediaTableName, {
      'captured_at': 'TEXT',
      'source_hash': "TEXT NOT NULL DEFAULT ''",
      'crop_quad_json': "TEXT NOT NULL DEFAULT ''",
    });
    await _createMediaSourceHashIndex(db);
  }

  static Future<void> _migrateToV23(Database db) async {
    // 周边手帐: preset/custom merch kinds and the purchase ledger. Old rows
    // and old backups are untouched; backup restore only writes those tables
    // when the manifest contains them.
    await _createMerchSchema(db);

    // 卡面简称: a per-member 1-4 character label for cards / avatars. Legacy
    // upgrade fixtures may not create the counters table at all; the
    // ensure-latest-schema pass below adds the column whenever it exists.
    if ((await _getColumnNames(db, tableName)).isNotEmpty) {
      await _ensureColumns(db, tableName, {
        'short_name': "TEXT NOT NULL DEFAULT ''",
      });
    }

    // Ticketing gained a few built-ins. Insert only the missing ones so a
    // deliberately deleted default does not come back on every app launch.
    // An empty catalog is left to TicketPricingService so a very old database
    // upgrading straight to v23 still gets the full default list.
    await _createTicketTypeCatalogSchema(db);
    final typeCount = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM ticket_types',
    );
    if (((typeCount.first['count'] as num?)?.toInt() ?? 0) > 0) {
      final now = DateTime.now().toIso8601String();
      for (final (name, sortOrder) in [
        ('早鸟票', 2),
        ('双人票', 8),
        ('通票', 9),
      ]) {
        await db.insert(
          'ticket_types',
          {
            'name': name,
            'default_price': 0,
            'is_free': 0,
            'sort_order': sortOrder,
            'updated_at': now,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
    }
  }

  static Future<void> _createTicketTypeCatalogSchema(
    DatabaseExecutor db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ticket_types(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        default_price REAL NOT NULL DEFAULT 0,
        is_free INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createMediaSourceHashIndex(DatabaseExecutor db) async {
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_record_media_source_hash
      ON $activityRecordMediaTableName(source_hash)
    ''');
  }

  static Future<void> _migrateToV19(Database db) async {
    // The idol database refresh can replace person rows and leave counters /
    // records pointing at stale person ids. Re-resolve every identity so the
    // home page does not show the same member as several cards.
    await _backfillIdentityAndMultiData(db);
  }

  /// Repairs counter / record person ids against the current idol database.
  ///
  /// Safe to call repeatedly: rows that already match are left untouched.
  /// Should run after the built-in idol seed has been initialized.
  static Future<void> reconcileCounterIdentities() async {
    final db = await database;
    await _backfillIdentityAndMultiData(db);
  }

  static Future<void> _ensureLatestSchema(DatabaseExecutor db) async {
    await _createSchema(db);

    await _ensureColumns(
      db,
      tableName,
      {
        'group_name': "TEXT NOT NULL DEFAULT ''",
        'person_id': 'INTEGER',
        'person_name': "TEXT NOT NULL DEFAULT ''",
        'short_name': "TEXT NOT NULL DEFAULT ''",
        'is_hidden': 'INTEGER NOT NULL DEFAULT 0',
        'three_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'five_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'unsigned_three_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'unsigned_five_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'group_cut_count': 'INTEGER NOT NULL DEFAULT 0',
        'three_inch_shukudai_count': 'INTEGER NOT NULL DEFAULT 0',
        'five_inch_shukudai_count': 'INTEGER NOT NULL DEFAULT 0',
      },
    );

    await _ensureColumns(
      db,
      groupPricingTableName,
      {
        'label': "TEXT NOT NULL DEFAULT ''",
        'enable_unsigned': 'INTEGER NOT NULL DEFAULT 0',
        'three_inch_price': 'REAL NOT NULL DEFAULT 0',
        'five_inch_price': 'REAL NOT NULL DEFAULT 0',
        'unsigned_three_inch_price': 'REAL NOT NULL DEFAULT 0',
        'unsigned_five_inch_price': 'REAL NOT NULL DEFAULT 0',
        'group_cut_price': 'REAL NOT NULL DEFAULT 0',
        'double_cut_price': 'REAL NOT NULL DEFAULT 0',
        'three_inch_shukudai_price': 'REAL NOT NULL DEFAULT 0',
        'five_inch_shukudai_price': 'REAL NOT NULL DEFAULT 0',
        'custom_cheki_types_json': "TEXT NOT NULL DEFAULT '[]'",
        'updated_at': "TEXT NOT NULL DEFAULT ''",
      },
    );

    await _ensureColumns(
      db,
      activityRecordTableName,
      {
        'source': "TEXT NOT NULL DEFAULT 'local'",
        'source_record_id': 'TEXT',
        // Preserve legacy backup metadata verbatim; ordinary model updates
        // omit these columns and leave their values untouched.
        'group_record_id': 'TEXT',
        'is_system_adjustment': 'INTEGER DEFAULT 0',
        'counter_id': 'INTEGER',
        'person_id': 'INTEGER',
        'person_name': "TEXT NOT NULL DEFAULT ''",
        'secondary_subject_name': "TEXT NOT NULL DEFAULT ''",
        'group_name': "TEXT NOT NULL DEFAULT ''",
        'activity_name': "TEXT NOT NULL DEFAULT ''",
        'venue_name': "TEXT NOT NULL DEFAULT ''",
        'session_label': "TEXT NOT NULL DEFAULT ''",
        'note': "TEXT NOT NULL DEFAULT ''",
        'pricing_label': "TEXT NOT NULL DEFAULT ''",
        'uses_current_pricing': 'INTEGER',
        'three_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'five_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'unsigned_three_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'unsigned_five_inch_count': 'INTEGER NOT NULL DEFAULT 0',
        'group_cut_count': 'INTEGER NOT NULL DEFAULT 0',
        'three_inch_shukudai_count': 'INTEGER NOT NULL DEFAULT 0',
        'five_inch_shukudai_count': 'INTEGER NOT NULL DEFAULT 0',
        'multi_cut_quantity': 'INTEGER NOT NULL DEFAULT 0',
        'double_cut_quantity': 'INTEGER NOT NULL DEFAULT 0',
        'ticket_quantity': 'INTEGER NOT NULL DEFAULT 0',
        'ticket_type': "TEXT NOT NULL DEFAULT ''",
        'ticket_is_free': 'INTEGER',
        'three_inch_price': 'REAL NOT NULL DEFAULT 0',
        'five_inch_price': 'REAL NOT NULL DEFAULT 0',
        'unsigned_three_inch_price': 'REAL NOT NULL DEFAULT 0',
        'unsigned_five_inch_price': 'REAL NOT NULL DEFAULT 0',
        'group_cut_price': 'REAL NOT NULL DEFAULT 0',
        'double_cut_unit_price': 'REAL NOT NULL DEFAULT 0',
        'three_inch_shukudai_price': 'REAL NOT NULL DEFAULT 0',
        'five_inch_shukudai_price': 'REAL NOT NULL DEFAULT 0',
        'ticket_unit_price': 'REAL NOT NULL DEFAULT 0',
        'total_amount': 'REAL NOT NULL DEFAULT 0',
        'multi_participants_json': "TEXT NOT NULL DEFAULT '[]'",
        'custom_cheki_counts_json': "TEXT NOT NULL DEFAULT '[]'",
      },
    );

    await db.execute('''
      CREATE TABLE IF NOT EXISTS $activityRecordMediaTableName(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        record_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        media_type TEXT NOT NULL DEFAULT 'memory',
        processing_mode TEXT NOT NULL DEFAULT 'none',
        is_reversed INTEGER NOT NULL DEFAULT 0,
        owner_person_id INTEGER,
        owner_person_name TEXT NOT NULL DEFAULT '',
        owner_group_name TEXT NOT NULL DEFAULT '',
        captured_at TEXT,
        source_hash TEXT NOT NULL DEFAULT '',
        crop_quad_json TEXT NOT NULL DEFAULT ''
      )
    ''');
    await _ensureColumns(
      db,
      activityRecordMediaTableName,
      {
        'media_type': "TEXT NOT NULL DEFAULT 'memory'",
        'processing_mode': "TEXT NOT NULL DEFAULT 'none'",
        'is_reversed': 'INTEGER NOT NULL DEFAULT 0',
        'owner_person_id': 'INTEGER',
        'owner_person_name': "TEXT NOT NULL DEFAULT ''",
        'owner_group_name': "TEXT NOT NULL DEFAULT ''",
        'captured_at': 'TEXT',
        'source_hash': "TEXT NOT NULL DEFAULT ''",
        'crop_quad_json': "TEXT NOT NULL DEFAULT ''",
      },
    );
    await _createMediaSourceHashIndex(db);
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_activity_record_media_record_id
      ON $activityRecordMediaTableName(record_id, created_at DESC)
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

  static Future<void> _ensureColumns(
    DatabaseExecutor db,
    String table,
    Map<String, String> columns,
  ) async {
    final existingColumns = await _getColumnNames(db, table);
    for (final entry in columns.entries) {
      if (existingColumns.contains(entry.key)) {
        continue;
      }
      await db.execute(
        'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}',
      );
    }
  }

  static Future<Set<String>> _getColumnNames(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows
        .map((row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
  }

  static Future<Map<String, Object?>> _filterValuesForTable(
    DatabaseExecutor db,
    String table,
    Map<String, Object?> values,
  ) async {
    final columns =
        _tableColumnsCache[table] ??= await _getColumnNames(db, table);
    return {
      for (final entry in values.entries)
        if (columns.contains(entry.key)) entry.key: entry.value,
    };
  }

  static Map<String, dynamic> _toDatabaseMap(CounterModel counter) {
    return {
      'name': counter.name,
      'group_name': counter.groupName,
      'person_id': counter.personId,
      'person_name': counter.personName,
      'short_name': counter.shortName,
      'count': counter.count,
      'color': counter.color,
      'is_hidden': counter.isHidden ? 1 : 0,
      'three_inch_count': counter.threeInchCount,
      'five_inch_count': counter.fiveInchCount,
      'unsigned_three_inch_count': counter.unsignedThreeInchCount,
      'unsigned_five_inch_count': counter.unsignedFiveInchCount,
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

  static Future<List<CounterModel>> _getCountersFrom(
    DatabaseExecutor db,
  ) async {
    final maps = await db.query(tableName);
    return maps.map(CounterModel.fromMap).toList();
  }

  static Future<ActivityRecordModel?> _getActivityRecordFrom(
    DatabaseExecutor db,
    int id,
  ) async {
    final maps = await db.query(
      activityRecordTableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) {
      return null;
    }
    return ActivityRecordModel.fromMap(maps.first);
  }

  static CounterModel _resetCounterCounts(CounterModel counter) {
    return counter.copyWith(
      threeInchCount: 0,
      fiveInchCount: 0,
      unsignedThreeInchCount: 0,
      unsignedFiveInchCount: 0,
      groupCutCount: 0,
      threeInchShukudaiCount: 0,
      fiveInchShukudaiCount: 0,
    );
  }

  static void _cacheCounter(
    List<CounterModel> counters,
    CounterModel counter,
  ) {
    final id = counter.id;
    if (id != null) {
      final index = counters.indexWhere((item) => item.id == id);
      if (index != -1) {
        counters[index] = counter;
        return;
      }
    }
    counters.add(counter);
  }

  static CounterModel? _firstCounterWhere(
    List<CounterModel> counters,
    bool Function(CounterModel counter) test,
  ) {
    for (final counter in counters) {
      if (test(counter)) {
        return counter;
      }
    }
    return null;
  }

  static CounterModel? resolveCounterForParticipant(
    List<CounterModel> counters,
    ActivityParticipant participant, {
    bool allowUniquePersonFallback = true,
  }) {
    final personId = participant.personId;
    if (personId != null) {
      final matched = _firstCounterWhere(
        counters,
        (counter) =>
            _groupsCanMatch(counter.groupName, participant.groupName) &&
            counter.personId == personId,
      );
      if (matched != null) {
        return matched;
      }
    }

    final normalizedPersonName = _normalizeLookupPart(participant.personName);
    if (normalizedPersonName.isNotEmpty) {
      final matched = _firstCounterWhere(
        counters,
        (counter) =>
            _groupsCanMatch(counter.groupName, participant.groupName) &&
            _identitiesCanMatch(counter.personId, participant.personId) &&
            _normalizeLookupPart(counter.personName) == normalizedPersonName,
      );
      if (matched != null) {
        return matched;
      }
    }

    final normalizedGroup = _normalizeLookupPart(participant.groupName);
    final normalizedMember = _normalizeLookupPart(participant.memberName);
    if (normalizedMember.isNotEmpty) {
      final named = _firstCounterWhere(
        counters,
        (counter) =>
            _identitiesCanMatch(counter.personId, participant.personId) &&
            _normalizeLookupPart(counter.groupName) == normalizedGroup &&
            _normalizeLookupPart(counter.name) == normalizedMember,
      );
      if (named != null) {
        return named;
      }
    }

    // 转团: the historical participant still says the old group, but the
    // person now has a single card under the new group. Falling back only when
    // that person has exactly one card keeps 兼任 (two cards) unambiguous while
    // letting deletions/replays hit the moved card. The historical group name
    // on the record itself is never rewritten for this case.
    if (allowUniquePersonFallback && personId != null) {
      final personCards = counters
          .where((counter) => counter.personId == personId)
          .toList(growable: false);
      if (personCards.length == 1) {
        return personCards.single;
      }
    }
    return null;
  }

  static bool _groupsCanMatch(String counterGroup, String candidateGroup) {
    final normalizedCounterGroup = _normalizeLookupPart(counterGroup);
    final normalizedCandidateGroup = _normalizeLookupPart(candidateGroup);
    return normalizedCounterGroup.isEmpty ||
        normalizedCandidateGroup.isEmpty ||
        normalizedCounterGroup == normalizedCandidateGroup;
  }

  static bool _identitiesCanMatch(
      int? counterPersonId, int? candidatePersonId) {
    return counterPersonId == null ||
        candidatePersonId == null ||
        counterPersonId == candidatePersonId;
  }

  static ActivityRecordModel _recordLinkedToCounter(
    ActivityRecordModel record,
    CounterModel counter,
  ) {
    final counterPersonName = counter.personName.trim();
    return record.copyWith(
      counterId: counter.id,
      personId: counter.personId ?? record.personId,
      personName:
          counterPersonName.isNotEmpty ? counterPersonName : record.personName,
    );
  }

  static Future<_PreparedActivityRecord> _prepareRecordForCounterImpact(
    DatabaseExecutor db,
    List<CounterModel> counters,
    ActivityRecordModel record,
  ) async {
    if (!record.isCounter) {
      return _PreparedActivityRecord(record: record);
    }

    final existingCounter = resolveCounterForActivityRecord(
      counters,
      record,
      allowUniquePersonFallback: false,
    );
    if (existingCounter != null) {
      return _PreparedActivityRecord(
        record: _recordLinkedToCounter(record, existingCounter),
      );
    }

    final baseCounter = CounterModel(
      name: record.subjectName,
      groupName: record.groupName,
      personId: record.personId,
      personName: record.personName,
      color: _defaultImportedCounterColor,
    );
    final values = await _filterValuesForTable(
      db,
      tableName,
      _toDatabaseMap(baseCounter),
    );
    final counterId = await db.insert(
      tableName,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final insertedCounter = baseCounter.copyWith(id: counterId);
    _cacheCounter(counters, insertedCounter);

    return _PreparedActivityRecord(
      record: _recordLinkedToCounter(record, insertedCounter),
      insertedNewCounter: true,
    );
  }

  static Future<CounterModel> _persistCounter(
    DatabaseExecutor db,
    List<CounterModel> counters,
    CounterModel counter,
  ) async {
    final values = await _filterValuesForTable(
      db,
      tableName,
      _toDatabaseMap(counter),
    );
    if (counter.id != null) {
      await db.update(
        tableName,
        values,
        where: 'id = ?',
        whereArgs: [counter.id],
      );
      _cacheCounter(counters, counter);
      return counter;
    }

    final counterId = await db.insert(
      tableName,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final insertedCounter = counter.copyWith(id: counterId);
    _cacheCounter(counters, insertedCounter);
    return insertedCounter;
  }

  static Future<bool> _applyRecordCounterImpact(
    DatabaseExecutor db,
    List<CounterModel> counters,
    ActivityRecordModel record, {
    required bool reverse,
  }) async {
    return _applyRecordsCounterImpact(
      db,
      counters,
      removed: reverse ? [record] : const [],
      added: reverse ? const [] : [record],
    );
  }

  static Future<bool> _applyRecordsCounterImpact(
    DatabaseExecutor db,
    List<CounterModel> counters, {
    List<ActivityRecordModel> removed = const [],
    List<ActivityRecordModel> added = const [],
  }) async {
    var insertedNewCounter = false;
    final deltas = <int, Map<CounterCountField, int>>{};
    for (final reverse in [true, false]) {
      for (final record in reverse ? removed : added) {
        final targets = <CounterModel>[];
        if (record.isCounter) {
          final existing = resolveCounterForActivityRecord(
            counters,
            record,
            allowUniquePersonFallback: reverse,
          );
          if (existing != null) {
            targets.add(existing);
          } else if (!reverse) {
            targets.add(await _persistCounter(
                db,
                counters,
                CounterModel(
                  name: record.subjectName,
                  groupName: record.groupName,
                  personId: record.personId,
                  personName: record.personName,
                  color: _defaultImportedCounterColor,
                )));
            insertedNewCounter = true;
          }
        } else if (record.isMulti && record.multiCountField != null) {
          for (final participant in record.effectiveParticipants) {
            var target = resolveCounterForParticipant(
              counters,
              participant,
              allowUniquePersonFallback: reverse,
            );
            if (target == null && !reverse) {
              target = await _persistCounter(
                  db,
                  counters,
                  CounterModel(
                    name: participant.memberName,
                    groupName: participant.groupName,
                    personId: participant.personId,
                    personName: participant.personName,
                    color: _defaultImportedCounterColor,
                  ));
              insertedNewCounter = true;
            }
            // Repeated aliases resolving to one member represent one slot.
            if (target != null && !targets.any((c) => c.id == target!.id)) {
              targets.add(target);
            }
          }
        }
        for (final target in targets) {
          final changes = deltas.putIfAbsent(target.id!, () => {});
          for (final field in CounterCountField.values) {
            final quantity = record.isMulti
                ? (record.multiCountField == field
                    ? record.effectiveMultiQuantity
                    : 0)
                : record.countForField(field);
            changes[field] =
                (changes[field] ?? 0) + quantity * (reverse ? -1 : 1);
          }
        }
      }
    }
    for (final entry in deltas.entries) {
      var counter = counters.firstWhere((c) => c.id == entry.key);
      for (final change in entry.value.entries) {
        final next = counter.countForField(change.key) + change.value;
        if (next < 0) {
          throw StateError(
              '${counter.name}的${change.key.label}不足，操作会使计数变为负数。请先处理相关减数修正记录，或一起删除关联记录。');
        }
        counter = counter.updateCount(change.key, next);
      }
      await _persistCounter(db, counters, counter);
    }
    return insertedNewCounter;
  }

  /// Latest linked counter record per card. Used only for the cross-group
  /// card manager: multi cuts have no counter_id, so this is a "最近活动"
  /// hint, not a full history query.
  static Future<Map<int, DateTime>> getLastCounterActivityDays({
    List<CounterModel>? counters,
  }) async {
    final db = await database;
    final result = <int, DateTime>{};
    void remember(int? id, String? raw) {
      final value = raw?.trim() ?? '';
      final day = value.isEmpty ? null : DateTime.tryParse(value);
      if (id == null || day == null) return;
      final previous = result[id];
      if (previous == null || day.isAfter(previous)) result[id] = day;
    }

    final linked = await db.rawQuery('''
      SELECT counter_id, MAX(occurred_at) AS last_at
      FROM $activityRecordTableName
      WHERE record_type = ? AND counter_id IS NOT NULL
      GROUP BY counter_id
      ''', [ActivityRecordType.counter.dbValue]);
    for (final row in linked) {
      remember((row['counter_id'] as num?)?.toInt(), row['last_at'] as String?);
    }

    // Old imports often have no counter_id. Match those rows by the same
    // person/group/name resolution used for display, so the card manager does
    // not say "还没有流水" for a card that visibly has history.
    final unlinked = await db.rawQuery('''
      SELECT person_id, person_name, group_name, subject_name,
             MAX(occurred_at) AS last_at
      FROM $activityRecordTableName
      WHERE record_type = ? AND counter_id IS NULL
      GROUP BY person_id, person_name, group_name, subject_name
      ''', [ActivityRecordType.counter.dbValue]);
    if (unlinked.isEmpty) return result;
    final allCounters = counters ?? await getCounters();
    for (final row in unlinked) {
      final personId = (row['person_id'] as num?)?.toInt();
      final personName =
          _normalizeLookupPart((row['person_name'] ?? '') as String);
      final group = _normalizeLookupPart((row['group_name'] ?? '') as String);
      final subject =
          _normalizeLookupPart((row['subject_name'] ?? '') as String);
      int? matchedId;
      for (final counter in allCounters) {
        if (personId != null && counter.personId != null) {
          if (counter.personId != personId ||
              _normalizeLookupPart(counter.groupName) != group) {
            continue;
          }
        } else if (_normalizeLookupPart(counter.groupName) != group) {
          continue;
        }
        final counterName = _normalizeLookupPart(counter.name);
        final counterPerson = _normalizeLookupPart(counter.personName);
        final nameMatches = counterName == subject ||
            (personName.isNotEmpty && counterPerson == personName);
        if (!nameMatches) continue;
        matchedId = counter.id;
        break;
      }
      remember(matchedId, row['last_at'] as String?);
    }
    return result;
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
    final values =
        await _filterValuesForTable(db, tableName, _toDatabaseMap(counter));
    return await db.insert(
      tableName,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Updates a counter's metadata (name, group, identity, color, hidden).
  ///
  /// Counts are derived from activity_records and are never taken from
  /// [counter]: callers usually hold a copy loaded earlier, and writing its
  /// counts back would silently drop anything recorded since (for example by
  /// a background MCP sync). Change counts through activity records instead.
  ///
  /// When the name / group / identity changes, records that resolved to this
  /// counter by name are re-linked so later deletes and replays still find it.
  static Future<void> updateCounter(int id, CounterModel counter) async {
    final db = await database;
    await db.transaction((txn) async {
      final counters = await _getCountersFrom(txn);
      final index = counters.indexWhere((item) => item.id == id);
      if (index == -1) {
        return;
      }
      final previous = counters[index];
      final updated = counter.copyWith(
        id: id,
        threeInchCount: previous.threeInchCount,
        fiveInchCount: previous.fiveInchCount,
        unsignedThreeInchCount: previous.unsignedThreeInchCount,
        unsignedFiveInchCount: previous.unsignedFiveInchCount,
        groupCutCount: previous.groupCutCount,
        threeInchShukudaiCount: previous.threeInchShukudaiCount,
        fiveInchShukudaiCount: previous.fiveInchShukudaiCount,
      );
      await _relinkRecordsToUpdatedCounter(txn, counters, updated);
      final values =
          await _filterValuesForTable(txn, tableName, _toDatabaseMap(updated));
      await txn.update(
        tableName,
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  static Future<void> _relinkRecordsToUpdatedCounter(
    DatabaseExecutor db,
    List<CounterModel> countersBefore,
    CounterModel updated,
  ) async {
    final id = updated.id!;
    final previous = countersBefore.firstWhere((item) => item.id == id);
    final identityChanged = previous.personId != updated.personId ||
        _normalizeLookupPart(previous.personName) !=
            _normalizeLookupPart(updated.personName) ||
        _normalizeLookupPart(previous.name) !=
            _normalizeLookupPart(updated.name) ||
        _normalizeLookupPart(previous.groupName) !=
            _normalizeLookupPart(updated.groupName);
    if (!identityChanged) {
      return;
    }
    final countersAfter = [
      for (final item in countersBefore) item.id == id ? updated : item,
    ];

    final maps = await db.query(
      activityRecordTableName,
      where: 'record_type <> ?',
      whereArgs: [ActivityRecordType.ticket.dbValue],
    );
    for (final map in maps) {
      final record = ActivityRecordModel.fromMap(map);
      final recordId = record.id;
      if (recordId == null) {
        continue;
      }
      if (record.isCounter) {
        if (resolveCounterForActivityRecord(countersBefore, record)?.id == id &&
            resolveCounterForActivityRecord(countersAfter, record)?.id != id) {
          await db.update(
            activityRecordTableName,
            {'counter_id': id},
            where: 'id = ?',
            whereArgs: [recordId],
          );
        }
        continue;
      }
      if (!record.isMulti) {
        continue;
      }
      var changed = false;
      final participants = record.effectiveParticipants.map((participant) {
        if (resolveCounterForParticipant(countersBefore, participant)?.id !=
                id ||
            resolveCounterForParticipant(countersAfter, participant)?.id ==
                id) {
          return participant;
        }
        changed = true;
        return ActivityParticipant(
          memberName: updated.name,
          groupName: updated.groupName,
          personId: updated.personId,
          personName: updated.personName,
        );
      }).toList(growable: false);
      if (!changed) {
        continue;
      }
      final relinked = record.copyWith(
        participants: participants,
        subjectName: participants.first.memberName,
        secondarySubjectName:
            participants.length > 1 ? participants[1].memberName : '',
      );
      await db.update(
        activityRecordTableName,
        await _filterValuesForTable(
          db,
          activityRecordTableName,
          _recordToDatabaseMap(relinked),
        ),
        where: 'id = ?',
        whereArgs: [recordId],
      );
    }
  }

  static Future<void> deleteCounter(int id) => deleteCounters([id]);

  static Future<void> deleteCounters(Iterable<int> ids) async {
    final scopedIds = ids.toSet().where((id) => id > 0).toList();
    if (scopedIds.isEmpty) return;
    final placeholders = List.filled(scopedIds.length, '?').join(', ');
    final pendingFileDeletes = <String>[];
    final db = await database;
    await db.transaction((txn) async {
      final counterMaps = await txn.query(
        tableName,
        where: 'id IN ($placeholders)',
        whereArgs: scopedIds,
      );
      if (counterMaps.isEmpty) {
        return;
      }

      final counters = await _getCountersFrom(txn);
      final selectedIds = counterMaps.map((map) => map['id'] as int).toSet();
      final recordMaps = await txn.query(
        activityRecordTableName,
        orderBy: 'occurred_at DESC, id DESC',
      );
      final relatedRecords =
          recordMaps.map(ActivityRecordModel.fromMap).where((record) {
        if (record.isCounter) {
          return selectedIds
              .contains(resolveCounterForActivityRecord(counters, record)?.id);
        }
        return record.isMulti &&
            record.effectiveParticipants.any((participant) =>
                selectedIds.contains(
                    resolveCounterForParticipant(counters, participant)?.id));
      }).toList(growable: false);
      final recordIds = relatedRecords
          .map((record) => record.id)
          .whereType<int>()
          .toList(growable: false);

      if (recordIds.isNotEmpty) {
        await _applyRecordsCounterImpact(txn, counters,
            removed: relatedRecords);
        await _forgetCounterSyncLog(txn, relatedRecords);

        await _deleteActivityRecordMediaRows(txn,
            pendingFileDeletes: pendingFileDeletes, recordIds: recordIds);
        final placeholders = List.filled(recordIds.length, '?').join(', ');
        await txn.delete(
          activityRecordTableName,
          where: 'id IN ($placeholders)',
          whereArgs: recordIds,
        );
      }

      await txn.delete(
        tableName,
        where: 'id IN ($placeholders)',
        whereArgs: scopedIds,
      );
    });
    await _deleteMediaFilesAfterCommit(pendingFileDeletes);
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
    final values = await _filterValuesForTable(
      db,
      groupPricingTableName,
      _pricingToDatabaseMap(pricing),
    );
    if (pricing.id != null) {
      await db.update(
        groupPricingTableName,
        values,
        where: 'id = ?',
        whereArgs: [pricing.id],
      );
      return pricing.id!;
    }

    return db.insert(
      groupPricingTableName,
      values,
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

  /// The home screen only needs multi records (for physical-count de-dup) and
  /// records carrying custom cheki counts. Loading 3k+ ticket/counter rows on
  /// every launch is unnecessary; this query keeps startup proportional to the
  /// support records instead of the whole history.
  static Future<List<ActivityRecordModel>> getHomeActivityRecords() async {
    final db = await database;
    final maps = await db.query(
      activityRecordTableName,
      where: '''
        record_type IN (?, ?) OR (
          custom_cheki_counts_json IS NOT NULL AND
          custom_cheki_counts_json NOT IN ('', '[]', 'null')
        )
      ''',
      whereArgs: [ActivityRecordType.multi.dbValue, 'duo'],
      orderBy: 'occurred_at DESC, id DESC',
    );
    return maps.map(ActivityRecordModel.fromMap).toList(growable: false);
  }

  static Future<int> getActivityRecordCount() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS record_count FROM $activityRecordTableName',
    );
    if (rows.isEmpty) {
      return 0;
    }
    return (rows.first['record_count'] as num?)?.toInt() ?? 0;
  }

  static Future<int> insertActivityRecord(ActivityRecordModel record) async {
    final db = await database;
    final values = await _filterValuesForTable(
      db,
      activityRecordTableName,
      _recordToDatabaseMap(record),
    );
    return db.insert(
      activityRecordTableName,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<int?> _findRecordIdBySource(
    DatabaseExecutor db,
    ActivityRecordModel record,
  ) async {
    final sourceRecordId = record.sourceRecordId?.trim();
    if (sourceRecordId == null || sourceRecordId.isEmpty) {
      return null;
    }
    final rows = await db.query(
      activityRecordTableName,
      columns: ['id'],
      where: 'source = ? AND source_record_id = ?',
      whereArgs: [record.source, sourceRecordId],
      limit: 1,
    );
    return rows.isEmpty ? null : (rows.first['id'] as num?)?.toInt();
  }

  static Future<void> _forgetCounterSyncLog(
    DatabaseExecutor db,
    Iterable<ActivityRecordModel> records,
  ) async {
    for (final record in records) {
      final sourceRecordId = record.sourceRecordId?.trim();
      if (sourceRecordId != null && sourceRecordId.isNotEmpty) {
        await db.delete(
          counterSyncTableName,
          where: 'source = ? AND source_record_id = ?',
          whereArgs: [record.source, sourceRecordId],
        );
      }
    }
  }

  static Future<int> insertActivityRecordWithCounterImpact(
    ActivityRecordModel record,
  ) async {
    final db = await database;
    var insertedNewCounter = false;

    final recordId = await db.transaction<int>((txn) async {
      // Remote actions (MCP sync, imports) carry a stable source id. Applying
      // the same one twice must be a no-op: the unique index would otherwise
      // REPLACE the row and the counter impact would be added a second time.
      final existingId = await _findRecordIdBySource(txn, record);
      if (existingId != null) {
        return existingId;
      }
      final counters = await _getCountersFrom(txn);
      final inserted = await _insertRecordWithImpactIn(txn, counters, record);
      insertedNewCounter = inserted.insertedNewCounter;
      return inserted.id;
    });

    if (insertedNewCounter) {
      await autoAssignCounterThemeColors();
    }
    return recordId;
  }

  static Future<void> updateActivityRecord(
    int id,
    ActivityRecordModel record,
  ) async {
    final db = await database;
    final values = await _filterValuesForTable(
      db,
      activityRecordTableName,
      _recordToDatabaseMap(record),
    );
    await db.update(
      activityRecordTableName,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> updateActivityRecordWithCounterImpact(
    int id,
    ActivityRecordModel record,
  ) async {
    final db = await database;
    var insertedNewCounter = false;

    await db.transaction((txn) async {
      final existingRecord = await _getActivityRecordFrom(txn, id);
      if (existingRecord == null) {
        throw StateError('Activity record $id not found');
      }

      final counters = await _getCountersFrom(txn);
      insertedNewCounter = await _updateRecordWithImpactIn(
          txn, counters, existingRecord, record.copyWith(id: id));
    });

    if (insertedNewCounter) {
      await autoAssignCounterThemeColors();
    }
  }

  /// Inserts [record] and adds its counts to the member counters, inside
  /// the caller's transaction.
  static Future<({int id, bool insertedNewCounter})> _insertRecordWithImpactIn(
    Transaction txn,
    List<CounterModel> counters,
    ActivityRecordModel record,
  ) async {
    final prepared =
        await _prepareRecordForCounterImpact(txn, counters, record);
    final values = await _filterValuesForTable(
      txn,
      activityRecordTableName,
      _recordToDatabaseMap(prepared.record),
    );
    final insertedId = await txn.insert(
      activityRecordTableName,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final createdByImpact = await _applyRecordCounterImpact(
      txn,
      counters,
      prepared.record.copyWith(id: insertedId),
      reverse: false,
    );
    return (
      id: insertedId,
      insertedNewCounter: prepared.insertedNewCounter || createdByImpact,
    );
  }

  /// Replaces [existing] with [updated] (same id) and moves the difference
  /// of their counts onto the member counters, inside the caller's
  /// transaction. Returns whether a counter card had to be created.
  static Future<bool> _updateRecordWithImpactIn(
    Transaction txn,
    List<CounterModel> counters,
    ActivityRecordModel existing,
    ActivityRecordModel updated,
  ) async {
    final id = existing.id!;
    final prepared = await _prepareRecordForCounterImpact(
        txn, counters, updated.copyWith(id: id));
    final values = await _filterValuesForTable(
      txn,
      activityRecordTableName,
      _recordToDatabaseMap(prepared.record.copyWith(id: id)),
    );
    await txn.update(
      activityRecordTableName,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
    final createdByImpact = await _applyRecordsCounterImpact(
      txn,
      counters,
      removed: [existing],
      added: [prepared.record.copyWith(id: id)],
    );
    return prepared.insertedNewCounter || createdByImpact;
  }

  static Future<void> deleteActivityRecord(int id) async {
    final pendingFileDeletes = <String>[];
    final db = await database;
    await db.transaction((txn) async {
      await _deleteActivityRecordMediaRows(txn,
          pendingFileDeletes: pendingFileDeletes, recordIds: [id]);
      await txn.delete(
        activityRecordTableName,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
    await _deleteMediaFilesAfterCommit(pendingFileDeletes);
  }

  static Future<void> deleteActivityRecordWithCounterImpact(int id) async {
    await deleteActivityRecordsWithCounterImpact([id]);
  }

  static Future<int> deleteActivityRecordsWithCounterImpact(
    Iterable<int> ids,
  ) async {
    final scopedIds = ids.toSet().where((id) => id > 0).toList(growable: false);
    if (scopedIds.isEmpty) {
      return 0;
    }

    final pendingFileDeletes = <String>[];
    final db = await database;
    final deletedCount = await db.transaction<int>((txn) async {
      final placeholders = List.filled(scopedIds.length, '?').join(', ');
      final maps = await txn.query(
        activityRecordTableName,
        where: 'id IN ($placeholders)',
        whereArgs: scopedIds,
        orderBy: 'occurred_at DESC, id DESC',
      );
      if (maps.isEmpty) {
        return 0;
      }

      final counters = await _getCountersFrom(txn);
      final records = maps.map(ActivityRecordModel.fromMap).toList();
      await _applyRecordsCounterImpact(txn, counters, removed: records);
      // Forget that imported rows were applied, otherwise re-importing the
      // same history file restores the row but never re-adds its count.
      await _forgetCounterSyncLog(txn, records);

      await _deleteActivityRecordMediaRows(txn,
          pendingFileDeletes: pendingFileDeletes, recordIds: scopedIds);
      await txn.delete(
        activityRecordTableName,
        where: 'id IN ($placeholders)',
        whereArgs: scopedIds,
      );
      return records.length;
    });
    await _deleteMediaFilesAfterCommit(pendingFileDeletes);
    return deletedCount;
  }

  static Future<int> recalculateCountersFromActivityRecords() async {
    final db = await database;
    var insertedNewCounter = false;

    final replayedCount = await db.transaction<int>((txn) async {
      final counters = await _getCountersFrom(txn);
      for (var index = 0; index < counters.length; index += 1) {
        final resetCounter = _resetCounterCounts(counters[index]);
        counters[index] = resetCounter;
        if (resetCounter.id == null) {
          continue;
        }
        final values = await _filterValuesForTable(
          txn,
          tableName,
          _toDatabaseMap(resetCounter),
        );
        await txn.update(
          tableName,
          values,
          where: 'id = ?',
          whereArgs: [resetCounter.id],
        );
      }

      final maps = await txn.query(
        activityRecordTableName,
        orderBy: 'occurred_at ASC, id ASC',
      );
      final preparedRecords = <ActivityRecordModel>[];
      for (final map in maps) {
        final record = ActivityRecordModel.fromMap(map);
        final prepared = await _prepareRecordForCounterImpact(
          txn,
          counters,
          record,
        );
        insertedNewCounter = insertedNewCounter || prepared.insertedNewCounter;

        if (record.id != null &&
            (prepared.record.counterId != record.counterId ||
                prepared.record.personId != record.personId ||
                prepared.record.personName != record.personName)) {
          final values = await _filterValuesForTable(
            txn,
            activityRecordTableName,
            _recordToDatabaseMap(prepared.record),
          );
          await txn.update(
            activityRecordTableName,
            values,
            where: 'id = ?',
            whereArgs: [record.id],
          );
        }

        preparedRecords.add(prepared.record);
      }
      final createdByImpact = await _applyRecordsCounterImpact(
        txn,
        counters,
        added: preparedRecords,
      );
      insertedNewCounter = insertedNewCounter || createdByImpact;
      return maps.length;
    });

    if (insertedNewCounter) {
      await autoAssignCounterThemeColors();
    }
    return replayedCount;
  }

  static Future<void> clearAppData() async {
    final pendingFileDeletes = <String>[];
    final db = await database;
    await db.transaction((txn) async {
      final merchPhotos = await txn.query(
        merchPurchaseTableName,
        columns: ['photo_path'],
      );
      for (final row in merchPhotos) {
        final path = (row['photo_path'] ?? '').toString().trim();
        if (path.isNotEmpty) pendingFileDeletes.add(path);
      }
      await _deleteActivityRecordMediaRows(txn,
          pendingFileDeletes: pendingFileDeletes);
      await txn.delete(activityRecordMediaTableName);
      await txn.delete(merchPurchaseTableName);
      await txn.delete(merchKindTableName);
      // Member face samples point at the media / counters being wiped; "我"
      // is not part of the ledger and survives a restore.
      await txn.delete(faceSamplesTableName, where: 'is_self = 0');
      await txn.delete(faceEnrollmentActionsTableName);
      await txn.delete(counterSyncTableName);
      await txn.delete(activityRecordTableName);
      await txn.delete(groupPricingTableName);
      await txn.delete('ticket_price_presets');
      await txn.delete('ticket_types');
      await txn.delete(tableName);
    });
    await _deleteMediaFilesAfterCommit(pendingFileDeletes);
  }

  static Future<List<ActivityRecordMediaModel>> getActivityRecordMedia({
    int? recordId,
    Iterable<int>? recordIds,
  }) async {
    final db = await database;
    final scopedRecordIds =
        recordIds?.toSet().toList(growable: false) ?? <int>[];

    String? where;
    List<Object?>? whereArgs;
    if (recordId != null) {
      where = 'record_id = ?';
      whereArgs = [recordId];
    } else if (scopedRecordIds.isNotEmpty) {
      final placeholders = List.filled(scopedRecordIds.length, '?').join(', ');
      where = 'record_id IN ($placeholders)';
      whereArgs = scopedRecordIds;
    }

    final maps = await db.query(
      activityRecordMediaTableName,
      where: where,
      whereArgs: whereArgs,
      orderBy:
          "CASE WHEN media_type = 'scan' THEN 0 ELSE 1 END ASC, created_at DESC, id DESC",
    );
    return maps.map(ActivityRecordMediaModel.fromMap).toList();
  }

  static Future<ActivityRecordMediaModel> saveActivityRecordMediaFile({
    required int recordId,
    required File imageFile,
    ActivityRecordMediaType mediaType = ActivityRecordMediaType.memory,
    ActivityRecordMediaProcessingMode processingMode =
        ActivityRecordMediaProcessingMode.none,
    ActivityRecordMediaOwnerScope? owner,
    DateTime? capturedAt,
  }) async {
    final originalExtension = extension(imageFile.path).trim();
    final fileExtension =
        originalExtension.isEmpty ? '.jpg' : originalExtension;
    return _saveActivityRecordMediaBytes(
      recordId: recordId,
      bytes: await imageFile.readAsBytes(),
      fileExtension: fileExtension,
      mediaType: mediaType,
      processingMode: processingMode,
      owner: owner,
      capturedAt: capturedAt,
    );
  }

  static Future<ActivityRecordMediaModel> saveActivityRecordMediaBytes({
    required int recordId,
    required List<int> bytes,
    String fileExtension = '.jpg',
    ActivityRecordMediaType mediaType = ActivityRecordMediaType.memory,
    ActivityRecordMediaProcessingMode processingMode =
        ActivityRecordMediaProcessingMode.none,
    ActivityRecordMediaOwnerScope? owner,
    DateTime? capturedAt,
  }) async {
    return _saveActivityRecordMediaBytes(
      recordId: recordId,
      bytes: bytes,
      fileExtension: fileExtension,
      mediaType: mediaType,
      processingMode: processingMode,
      owner: owner,
      capturedAt: capturedAt,
    );
  }

  static Future<ActivityRecordMediaModel> _saveActivityRecordMediaBytes({
    required int recordId,
    required List<int> bytes,
    required String fileExtension,
    required ActivityRecordMediaType mediaType,
    required ActivityRecordMediaProcessingMode processingMode,
    ActivityRecordMediaOwnerScope? owner,
    required DateTime? capturedAt,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final mediaDirectory = Directory(
      join(directory.path, 'activity_record_media'),
    );
    if (!await mediaDirectory.exists()) {
      await mediaDirectory.create(recursive: true);
    }

    final normalizedExtension = fileExtension.trim().isEmpty
        ? '.jpg'
        : (fileExtension.startsWith('.') ? fileExtension : '.$fileExtension');
    final fileName =
        '${DateTime.now().microsecondsSinceEpoch}_$recordId$normalizedExtension';
    final savedPath = join(mediaDirectory.path, fileName);
    await File(savedPath).writeAsBytes(bytes, flush: true);

    final media = ActivityRecordMediaModel(
      recordId: recordId,
      path: savedPath,
      createdAt: DateTime.now(),
      mediaType: mediaType,
      processingMode: processingMode,
      ownerPersonId: owner?.personId,
      ownerPersonName: owner?.personName ?? '',
      ownerGroupName: owner?.groupName ?? '',
      capturedAt: capturedAt,
    );
    final db = await database;
    final values = media.toMap()..remove('id');
    final id = await db.insert(
      activityRecordMediaTableName,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await AlbumPhotoFiles.prepare(
      savedPath,
      rectifyCut: media.isScan && !media.processingMode.isProcessed,
      isScan: media.isScan,
    );
    final saved = media.copyWith(id: id);
    if (media.isScan) unawaited(_recoverNewScans(db, [saved]));
    return saved;
  }

  static Future<void> _recoverNewScans(
      Database db, List<ActivityRecordMediaModel> media) async {
    if (!Platform.isAndroid || media.isEmpty) return;
    try {
      final recordIds = {
        for (final m in media)
          if (m.capturedAt == null) m.recordId
      };
      final records = <ActivityRecordModel>[];
      for (final id in recordIds) {
        final record = await _getActivityRecordFrom(db, id);
        if (record != null) records.add(record);
      }
      AlbumCameraRecovery.schedule(media, records);
    } catch (error) {
      // The files are already committed. Opening the album schedules them again.
      debugPrint('切册稍后检查新切图的原拍：$error');
    }
  }

  /// Records whose occurred_at lies in [from, to).
  static Future<List<ActivityRecordModel>> getActivityRecordsBetween(
    DateTime from,
    DateTime to,
  ) async {
    final db = await database;
    final maps = await db.query(
      activityRecordTableName,
      where: 'occurred_at >= ? AND occurred_at < ?',
      whereArgs: [from.toIso8601String(), to.toIso8601String()],
      orderBy: 'occurred_at ASC, id ASC',
    );
    return maps.map(ActivityRecordModel.fromMap).toList();
  }

  /// Every distinct record timestamp (for "which days have records").
  static Future<List<DateTime>> getActivityRecordTimes() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT occurred_at FROM $activityRecordTableName',
    );
    return rows
        .map((row) => DateTime.tryParse('${row['occurred_at'] ?? ''}'))
        .whereType<DateTime>()
        .toList();
  }

  /// How many media rows already came from each of [hashes].
  static Future<Map<String, int>> countMediaBySourceHash(
    Iterable<String> hashes,
  ) async {
    final list = hashes.where((h) => h.isNotEmpty).toSet().toList();
    if (list.isEmpty) return const {};
    final db = await database;
    final placeholders = List.filled(list.length, '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT source_hash, COUNT(*) AS n FROM $activityRecordMediaTableName '
      'WHERE source_hash IN ($placeholders) GROUP BY source_hash',
      list,
    );
    return {
      for (final row in rows)
        '${row['source_hash']}': (row['n'] as num?)?.toInt() ?? 0,
    };
  }

  /// Saves one 批量拍切 batch atomically: the supplementary ledger records
  /// (with their counter impact, exactly like
  /// [insertActivityRecordWithCounterImpact]) and every photo. A photo is
  /// attached to an existing record ([BatchMediaInput.recordId]) or to one
  /// of [newRecords] ([BatchMediaInput.newRecordIndex]). Files written for
  /// a rolled-back batch are removed again.
  static Future<BatchSaveResult> saveBatchImport({
    required List<ActivityRecordModel> newRecords,
    required List<BatchMediaInput> media,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final mediaDirectory =
        Directory(join(directory.path, 'activity_record_media'));
    if (!await mediaDirectory.exists()) {
      await mediaDirectory.create(recursive: true);
    }
    final writtenFiles = <String>[];
    final savedMedia = <ActivityRecordMediaModel>[];
    final db = await database;
    var insertedNewCounter = false;
    late final BatchSaveResult result;
    try {
      result = await db.transaction<BatchSaveResult>((txn) async {
        final counters = await _getCountersFrom(txn);
        final recordIds = <int>[];
        for (final record in newRecords) {
          final prepared =
              await _prepareRecordForCounterImpact(txn, counters, record);
          insertedNewCounter =
              insertedNewCounter || prepared.insertedNewCounter;
          final values = await _filterValuesForTable(
            txn,
            activityRecordTableName,
            _recordToDatabaseMap(prepared.record),
          );
          final id = await txn.insert(activityRecordTableName, values);
          final created = await _applyRecordCounterImpact(
            txn,
            counters,
            prepared.record.copyWith(id: id),
            reverse: false,
          );
          insertedNewCounter = insertedNewCounter || created;
          recordIds.add(id);
        }

        final mediaIds = <int>[];
        final now = DateTime.now();
        for (var i = 0; i < media.length; i++) {
          final item = media[i];
          final recordId = item.recordId ??
              (item.newRecordIndex == null
                  ? null
                  : recordIds[item.newRecordIndex!]);
          if (recordId == null) {
            throw StateError('第 ${i + 1} 张照片没有可挂的流水');
          }
          final ext = item.fileExtension.startsWith('.')
              ? item.fileExtension
              : '.${item.fileExtension}';
          final path = join(
            mediaDirectory.path,
            '${now.microsecondsSinceEpoch + i}_$recordId$ext',
          );
          await File(path).writeAsBytes(item.bytes, flush: true);
          writtenFiles.add(path);
          final model = ActivityRecordMediaModel(
            recordId: recordId,
            path: path,
            createdAt: now,
            mediaType: ActivityRecordMediaType.scan,
            processingMode: item.processingMode,
            ownerPersonId: item.owner?.personId,
            ownerPersonName: item.owner?.personName ?? '',
            ownerGroupName: item.owner?.groupName ?? '',
            capturedAt: item.capturedAt,
            sourceHash: item.sourceHash,
            cropQuadJson: item.cropQuadJson,
          );
          mediaIds.add(await txn.insert(
            activityRecordMediaTableName,
            model.toMap()..remove('id'),
          ));
          savedMedia.add(model.copyWith(id: mediaIds.last));
        }
        return BatchSaveResult(recordIds: recordIds, mediaIds: mediaIds);
      });
    } catch (_) {
      await _deleteMediaFilesAfterCommit(writtenFiles);
      rethrow;
    }
    if (insertedNewCounter) {
      await autoAssignCounterThemeColors();
    }
    for (var i = 0; i < writtenFiles.length; i++) {
      await AlbumPhotoFiles.prepare(
        writtenFiles[i],
        rectifyCut: !media[i].processingMode.isProcessed,
        isScan: true,
      );
    }
    unawaited(_recoverNewScans(db, savedMedia));
    return result;
  }

  static Future<void> updateActivityRecordMediaReversed(
    int id, {
    required bool isReversed,
  }) async {
    final db = await database;
    await db.update(
      activityRecordMediaTableName,
      {'is_reversed': isReversed ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Swaps the picture of an archived photo in place: same row (id, record,
  /// owner, position in the 切册), new bytes. Samples learned from the old
  /// picture go; the old file and its album renditions are removed after
  /// the commit. Returns false when the photo no longer exists.
  static Future<bool> replaceActivityRecordMedia(
    int id, {
    required List<int> bytes,
    required String fileExtension,
    required String sourceHash,
  }) async {
    final db = await database;
    final rows = await db.query(activityRecordMediaTableName,
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return false;
    final old = ActivityRecordMediaModel.fromMap(rows.single);
    final directory = File(old.path).parent;
    if (!await directory.exists()) await directory.create(recursive: true);
    final ext = fileExtension.startsWith('.') ? fileExtension : '.$fileExtension';
    final path = join(directory.path,
        '${DateTime.now().microsecondsSinceEpoch}_${old.recordId}$ext');
    await File(path).writeAsBytes(bytes, flush: true);
    try {
      await db.transaction((txn) async {
        await txn.update(
          activityRecordMediaTableName,
          {
            'path': path,
            'source_hash': sourceHash,
            'processing_mode': ActivityRecordMediaProcessingMode.none.dbValue,
            'crop_quad_json': '',
            'is_reversed': 0,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        await txn.delete(
          faceSamplesTableName,
          where: "source = 'attached' AND media_id = ?",
          whereArgs: [id],
        );
      });
    } catch (_) {
      await _deleteMediaFilesAfterCommit([path]);
      rethrow;
    }
    await _deleteMediaFilesAfterCommit([old.path]);
    await AlbumPhotoFiles.prepare(path, rectifyCut: true, isScan: true);
    return true;
  }

  /// Moves one archived photo onto another record, all in one transaction:
  ///
  /// * the photo row points at the target, with [owner] as its owner label
  ///   (null clears it: on a member's own record the record names the
  ///   owner) and, when [clearCapturedAt], without its capture time, so the
  ///   切册 files it under the target's day;
  /// * with a [countField], one count of that field moves along: the source
  ///   record loses one, the target gains one, and the member counters
  ///   follow exactly as an edit of each record would move them;
  /// * with [forgetFaces], the face samples learned automatically from this
  ///   photo (everything but "我" and hand-picked faces) are removed;
  /// * with [removeEmptySource], a source record left with no count, no
  ///   photo and no note is deleted.
  ///
  /// The target is [targetRecordId], or [newTarget] inserted with its own
  /// counts (already including the moved one) when that is null. Returns
  /// null when the photo no longer exists; throws [MediaMoveException] when
  /// the move would break the ledger.
  static Future<MediaMoveOutcome?> moveActivityRecordMedia(
    int mediaId, {
    int? targetRecordId,
    ActivityRecordModel? newTarget,
    CounterCountField? countField,
    ActivityRecordMediaOwnerScope? owner,
    bool clearCapturedAt = false,
    bool forgetFaces = false,
    bool removeEmptySource = false,
  }) async {
    if ((targetRecordId == null) == (newTarget == null)) {
      throw ArgumentError('Give exactly one of targetRecordId / newTarget');
    }
    final db = await database;
    var insertedNewCounter = false;
    final outcome = await db.transaction<MediaMoveOutcome?>((txn) async {
      final rows = await txn.query(activityRecordMediaTableName,
          where: 'id = ?', whereArgs: [mediaId], limit: 1);
      if (rows.isEmpty) return null;
      final media = ActivityRecordMediaModel.fromMap(rows.single);
      final source = await _getActivityRecordFrom(txn, media.recordId);
      if (source == null) {
        throw MediaMoveException('照片所在的流水 #${media.recordId} 已不存在');
      }
      final counters = await _getCountersFrom(txn);
      ActivityRecordModel? sourceAfter;
      if (countField != null) {
        if (!source.isCounter) {
          throw MediaMoveException(
              '原流水 #${source.id} 是${source.isMulti ? '多人切' : '门票'}，张数不能跟着挪');
        }
        if (source.countForField(countField) < 1) {
          throw MediaMoveException(
              '原流水 #${source.id} 的${countField.label}已经是 0，没有可挪的张数');
        }
        sourceAfter = recordWithCountDelta(source, countField, -1);
        insertedNewCounter = await _updateRecordWithImpactIn(
                txn, counters, source, sourceAfter) ||
            insertedNewCounter;
      }

      ActivityRecordModel target;
      var created = false;
      if (targetRecordId != null) {
        if (targetRecordId == source.id) {
          throw MediaMoveException('照片已经在流水 #$targetRecordId 上');
        }
        final existing = await _getActivityRecordFrom(txn, targetRecordId);
        if (existing == null) {
          throw MediaMoveException('目标流水 #$targetRecordId 已不存在');
        }
        if (existing.type == ActivityRecordType.ticket) {
          throw MediaMoveException('目标流水 #$targetRecordId 是门票，切奇照片只能挂到切奇流水');
        }
        target = existing;
        if (countField != null) {
          if (!existing.isCounter) {
            throw MediaMoveException(
                '目标流水 #$targetRecordId 是多人切，张数不能跟着挪');
          }
          target = recordWithCountDelta(existing, countField, 1);
          insertedNewCounter = await _updateRecordWithImpactIn(
                  txn, counters, existing, target) ||
              insertedNewCounter;
        }
      } else {
        final inserted =
            await _insertRecordWithImpactIn(txn, counters, newTarget!);
        insertedNewCounter = insertedNewCounter || inserted.insertedNewCounter;
        target = (await _getActivityRecordFrom(txn, inserted.id))!;
        created = true;
      }

      await txn.update(
        activityRecordMediaTableName,
        {
          'record_id': target.id,
          'owner_person_id': owner?.personId,
          'owner_person_name': owner?.personName ?? '',
          'owner_group_name': owner?.groupName ?? '',
          if (clearCapturedAt) 'captured_at': null,
        },
        where: 'id = ?',
        whereArgs: [mediaId],
      );
      final facesRemoved = forgetFaces
          ? await txn.delete(
              faceSamplesTableName,
              where: "media_id = ? AND is_self = 0 AND source != 'manual'",
              whereArgs: [mediaId],
            )
          : 0;
      var sourceRemoved = false;
      final left = sourceAfter ?? source;
      if (removeEmptySource &&
          left.isCounter &&
          left.counterCountTotal == 0 &&
          left.note.trim().isEmpty) {
        final others = await txn.query(activityRecordMediaTableName,
            columns: ['id'],
            where: 'record_id = ?',
            whereArgs: [source.id],
            limit: 1);
        if (others.isEmpty) {
          await _forgetCounterSyncLog(txn, [source]);
          await txn.delete(activityRecordTableName,
              where: 'id = ?', whereArgs: [source.id]);
          sourceRemoved = true;
        }
      }
      return MediaMoveOutcome(
        mediaId: mediaId,
        source: left,
        target: target,
        createdTarget: created,
        facesRemoved: facesRemoved,
        sourceRemoved: sourceRemoved,
      );
    });
    if (insertedNewCounter) {
      await autoAssignCounterThemeColors();
    }
    return outcome;
  }

  /// [record] with one count field moved by [delta], its total amount
  /// moved by that field's unit price (never below zero).
  static ActivityRecordModel recordWithCountDelta(
    ActivityRecordModel record,
    CounterCountField field,
    int delta,
  ) {
    final map = record.toMap();
    final column = countColumnFor(field);
    final count = record.countForField(field) + delta;
    final total = record.totalAmount + delta * record.priceForField(field);
    return ActivityRecordModel.fromMap({
      ...map,
      column: count < 0 ? 0 : count,
      'total_amount': total < 0 ? 0.0 : total,
    });
  }

  /// Ledger column of a count field, e.g. three_inch_count.
  static String countColumnFor(CounterCountField field) => field.key
      .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

  static Future<void> deleteActivityRecordMedia(int id) async {
    final pendingFileDeletes = <String>[];
    final db = await database;
    await db.transaction((txn) async {
      await _deleteActivityRecordMediaRows(txn,
          pendingFileDeletes: pendingFileDeletes, mediaIds: [id]);
    });
    await _deleteMediaFilesAfterCommit(pendingFileDeletes);
  }

  static Future<void> _deleteActivityRecordMediaRows(
    DatabaseExecutor db, {
    required List<String> pendingFileDeletes,
    Iterable<int>? recordIds,
    Iterable<int>? mediaIds,
  }) async {
    final scopedRecordIds =
        recordIds?.toSet().toList(growable: false) ?? <int>[];
    final scopedMediaIds = mediaIds?.toSet().toList(growable: false) ?? <int>[];

    String? where;
    List<Object?>? whereArgs;
    if (scopedMediaIds.isNotEmpty) {
      final placeholders = List.filled(scopedMediaIds.length, '?').join(', ');
      where = 'id IN ($placeholders)';
      whereArgs = scopedMediaIds;
    } else if (scopedRecordIds.isNotEmpty) {
      final placeholders = List.filled(scopedRecordIds.length, '?').join(', ');
      where = 'record_id IN ($placeholders)';
      whereArgs = scopedRecordIds;
    }

    final mediaRows = await db.query(
      activityRecordMediaTableName,
      where: where,
      whereArgs: whereArgs,
    );
    pendingFileDeletes.addAll(mediaRows
        .map((row) => (row['path'] ?? '') as String)
        .where((path) => path.isNotEmpty));

    await db.delete(
      activityRecordMediaTableName,
      where: where,
      whereArgs: whereArgs,
    );

    // A sample learned automatically from an attached photo goes with it.
    final deletedIds = [
      for (final row in mediaRows)
        if (row['id'] is int) row['id'] as int,
    ];
    if (deletedIds.isNotEmpty) {
      final placeholders = List.filled(deletedIds.length, '?').join(', ');
      await db.delete(
        faceSamplesTableName,
        where: "source = 'attached' AND media_id IN ($placeholders)",
        whereArgs: deletedIds,
      );
    }
  }

  // A rolled-back database transaction must never lose its photos.
  static Future<void> _deleteMediaFilesAfterCommit(
      Iterable<String> paths) async {
    for (final path in paths.toSet()) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
        await AlbumPhotoFiles.deleteFor(path);
      } on FileSystemException {
        // Keep an orphan file if cleanup fails; the committed deletion is valid.
      }
    }
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
    // Building the idol identity / theme lookups scans the whole member table,
    // so do not pay for it on every launch when there is nothing to sync.
    final pendingRows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS pending_count
      FROM $activityRecordTableName
      WHERE source = ? AND record_type = ? AND source_record_id IS NOT NULL
        AND source_record_id NOT IN (
          SELECT source_record_id
          FROM $counterSyncTableName
          WHERE source = ?
        )
      ''',
      [source, ActivityRecordType.counter.dbValue, source],
    );
    final pendingCount =
        (pendingRows.first['pending_count'] as num?)?.toInt() ?? 0;
    if (pendingCount == 0) {
      return 0;
    }
    final themeLookup = await _buildCounterThemeLookup();
    final identityLookup = await _buildIdolIdentityLookup();

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
      final countersByIdentityKey = <String, CounterModel>{};
      for (final row in counterMaps) {
        final counter = CounterModel.fromMap(row);
        final key = _normalizeCounterKey(counter.name, counter.groupName);
        if (key.isEmpty) {
          continue;
        }
        countersByKey.putIfAbsent(key, () => counter);
        final personId = counter.personId;
        if (personId != null) {
          countersByIdentityKey[_normalizeCounterIdentityKey(
            counter.name,
            counter.groupName,
            personId,
          )] = counter;
        }
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

        final resolvedIdentity = _resolveIdentity(
          name: counterName,
          groupName: record.groupName.trim(),
          personId: record.personId,
          personName: record.personName,
          lookup: identityLookup,
        );
        final existingByName = countersByKey[key];
        final resolvedPersonId = resolvedIdentity?.personId ?? record.personId;
        final existingCounter = resolvedPersonId == null
            ? existingByName
            : countersByIdentityKey[_normalizeCounterIdentityKey(
                  counterName,
                  record.groupName,
                  resolvedPersonId,
                )] ??
                (existingByName == null || existingByName.personId == null
                    ? existingByName
                    : null);
        final resolvedThemeColor = _resolveCounterThemeColor(
          name: counterName,
          groupName: record.groupName.trim(),
          lookup: themeLookup,
        );
        final updatedCounter = (existingCounter ??
                CounterModel(
                  name: counterName,
                  groupName: record.groupName.trim(),
                  personId: resolvedIdentity?.personId,
                  personName: resolvedIdentity?.personName ?? record.personName,
                  color: resolvedThemeColor ?? _defaultImportedCounterColor,
                ))
            .copyWith(
          personId: resolvedIdentity?.personId ?? existingCounter?.personId,
          personName: resolvedIdentity?.personName ??
              existingCounter?.personName ??
              record.personName,
          color: _shouldApplyAutoThemeColor(existingCounter?.color)
              ? (resolvedThemeColor ??
                  existingCounter?.color ??
                  _defaultImportedCounterColor)
              : existingCounter?.color,
          threeInchCount:
              (existingCounter?.threeInchCount ?? 0) + record.threeInchCount,
          fiveInchCount:
              (existingCounter?.fiveInchCount ?? 0) + record.fiveInchCount,
          unsignedThreeInchCount:
              (existingCounter?.unsignedThreeInchCount ?? 0) +
                  record.unsignedThreeInchCount,
          unsignedFiveInchCount: (existingCounter?.unsignedFiveInchCount ?? 0) +
              record.unsignedFiveInchCount,
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
          final values = await _filterValuesForTable(
            txn,
            tableName,
            _toDatabaseMap(updatedCounter),
          );
          await txn.update(
            tableName,
            values,
            where: 'id = ?',
            whereArgs: [existingCounter!.id],
          );
          persistedCounter = updatedCounter.copyWith(id: existingCounter.id);
        } else {
          final values = await _filterValuesForTable(
            txn,
            tableName,
            _toDatabaseMap(updatedCounter),
          );
          final insertedId = await txn.insert(
            tableName,
            values,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          persistedCounter = updatedCounter.copyWith(id: insertedId);
        }

        if (existingByName == null ||
            existingByName.id == persistedCounter.id) {
          countersByKey[key] = persistedCounter;
        }
        if (persistedCounter.personId != null) {
          countersByIdentityKey[_normalizeCounterIdentityKey(
            persistedCounter.name,
            persistedCounter.groupName,
            persistedCounter.personId!,
          )] = persistedCounter;
        }
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

    final candidates = overwriteExisting
        ? counters
        : counters
            .where((counter) => _shouldApplyAutoThemeColor(counter.color))
            .toList(growable: false);
    if (candidates.isEmpty) {
      return 0;
    }

    final themeLookup = await _buildCounterThemeLookup();
    if (themeLookup.byGroupAndMember.isEmpty &&
        themeLookup.byUniqueMember.isEmpty) {
      return 0;
    }

    var updatedCount = 0;
    await db.transaction((txn) async {
      for (final counter in candidates) {
        if (counter.id == null) {
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

        // Only the colour: [counter] was read before the (slow) theme lookup,
        // so its counts may already be stale and must not be written back.
        await txn.update(
          tableName,
          {'color': resolvedThemeColor},
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
      member.resolvedPersonName,
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

  static Future<bool> _hasStalePersonReferences(Database db) async {
    final knownPersonIds = await IdolDatabaseService.getPersonIds();

    final counterRows = await db.query(tableName, columns: ['person_id']);
    for (final row in counterRows) {
      final personId = (row['person_id'] as num?)?.toInt();
      if (personId != null && !knownPersonIds.contains(personId)) {
        return true;
      }
    }

    final recordRows = await db.query(
      activityRecordTableName,
      columns: ['record_type', 'person_id', 'multi_participants_json'],
    );
    for (final row in recordRows) {
      final personId = (row['person_id'] as num?)?.toInt();
      if (personId != null && !knownPersonIds.contains(personId)) {
        return true;
      }
      if (row['record_type'] != ActivityRecordType.multi.dbValue) {
        continue;
      }
      final rawParticipants =
          (row['multi_participants_json'] as String?)?.trim() ?? '';
      if (rawParticipants.isEmpty || rawParticipants == '[]') {
        continue;
      }
      try {
        final decoded = jsonDecode(rawParticipants);
        if (decoded is! List) {
          continue;
        }
        for (final item in decoded) {
          if (item is! Map) {
            continue;
          }
          final rawPersonId = item['personId'] ?? item['person_id'];
          final participantPersonId = rawPersonId is num
              ? rawPersonId.toInt()
              : int.tryParse('$rawPersonId');
          if (participantPersonId != null &&
              !knownPersonIds.contains(participantPersonId)) {
            return true;
          }
        }
      } on FormatException {
        // Ignore malformed participant json; identity repair does not need it.
      }
    }

    return false;
  }

  static Future<void> _backfillIdentityAndMultiData(Database db) async {
    // Building the idol lookup is the expensive part; skip it entirely on a
    // fresh install where there is nothing to repair.
    final hasData = await db.rawQuery(
      '''
      SELECT 1 FROM $tableName
      UNION ALL
      SELECT 1 FROM $activityRecordTableName
      LIMIT 1
      ''',
    );
    if (hasData.isEmpty) {
      return;
    }

    // The expensive part is building the full member alias lookup (thousands
    // of idol rows). If every stored person id still exists, only duplicate
    // counter rows need merging.
    final hasStaleReferences = await _hasStalePersonReferences(db);
    if (!hasStaleReferences) {
      await db.transaction((txn) async {
        await _mergeDuplicateCounters(txn);
      });
      return;
    }

    final identityLookup = await _buildIdolIdentityLookup();

    await db.transaction((txn) async {
      final counterMaps = await txn.query(tableName);
      for (final row in counterMaps) {
        final counter = CounterModel.fromMap(row);
        if (counter.id == null) {
          continue;
        }

        final resolvedIdentity = _resolveIdentity(
          name: counter.name,
          groupName: counter.groupName,
          personId: counter.personId,
          personName: counter.personName,
          lookup: identityLookup,
        );
        if (resolvedIdentity == null) {
          continue;
        }

        final shouldUpdate = counter.personId != resolvedIdentity.personId ||
            counter.personName.trim() != resolvedIdentity.personName.trim();
        if (!shouldUpdate) {
          continue;
        }

        await txn.update(
          tableName,
          await _filterValuesForTable(
            txn,
            tableName,
            _toDatabaseMap(
              counter.copyWith(
                personId: resolvedIdentity.personId,
                personName: resolvedIdentity.personName,
              ),
            ),
          ),
          where: 'id = ?',
          whereArgs: [counter.id],
        );
      }

      final recordMaps = await txn.query(activityRecordTableName);
      for (final row in recordMaps) {
        final record = ActivityRecordModel.fromMap(row);
        if (record.id == null) {
          continue;
        }

        var updatedRecord = record;
        var dirty = false;

        if (record.isCounter) {
          final resolvedIdentity = _resolveIdentity(
            name: record.subjectName,
            groupName: record.groupName,
            personId: record.personId,
            personName: record.personName,
            lookup: identityLookup,
          );
          if (resolvedIdentity != null &&
              (record.personId != resolvedIdentity.personId ||
                  record.personName.trim() !=
                      resolvedIdentity.personName.trim())) {
            updatedRecord = updatedRecord.copyWith(
              personId: resolvedIdentity.personId,
              personName: resolvedIdentity.personName,
            );
            dirty = true;
          }
        } else if (record.isMulti) {
          final participants = record.effectiveParticipants.map((participant) {
            final resolvedIdentity = _resolveIdentity(
              name: participant.memberName,
              groupName: participant.groupName,
              personId: participant.personId,
              personName: participant.personName,
              lookup: identityLookup,
            );
            return ActivityParticipant(
              memberName: participant.memberName,
              groupName: participant.groupName,
              personId: resolvedIdentity?.personId ?? participant.personId,
              personName:
                  resolvedIdentity?.personName ?? participant.personName,
            );
          }).toList(growable: false);

          final canonicalPrimary =
              participants.isNotEmpty ? participants.first : null;
          if (record.type != ActivityRecordType.multi ||
              record.participants.isEmpty ||
              record.multiCutQuantity == 0 ||
              record.personId != canonicalPrimary?.personId ||
              record.personName.trim() !=
                  (canonicalPrimary?.personName.trim() ?? '')) {
            updatedRecord = updatedRecord.copyWith(
              type: ActivityRecordType.multi,
              participants: participants,
              multiCutQuantity: record.effectiveMultiQuantity,
              personId: canonicalPrimary?.personId,
              personName: canonicalPrimary?.personName ?? record.personName,
            );
            dirty = true;
          }
        }

        if (!dirty) {
          continue;
        }

        await txn.update(
          activityRecordTableName,
          await _filterValuesForTable(
            txn,
            activityRecordTableName,
            _recordToDatabaseMap(updatedRecord),
          ),
          where: 'id = ?',
          whereArgs: [record.id],
        );
      }

      await _mergeDuplicateCounters(txn);
    });
  }

  static Future<void> _mergeDuplicateCounters(DatabaseExecutor db) async {
    // After identity repair two counter rows can describe the same member in
    // the same group (for example one row kept the old person id and another
    // was created after the refresh). Keeping both makes the edit sheet list
    // the same group twice while quick count only sees one of them.
    final rows = await db.query(tableName, orderBy: 'id ASC');
    final groups = <String, List<CounterModel>>{};
    for (final row in rows) {
      final counter = CounterModel.fromMap(row);
      final counterKey = _normalizeCounterKey(counter.name, counter.groupName);
      if (counterKey.isEmpty) {
        continue;
      }
      final key = counter.personId == null
          ? counterKey
          : 'person:${counter.personId}|$counterKey';
      groups.putIfAbsent(key, () => <CounterModel>[]).add(counter);
    }

    for (final group in groups.values) {
      if (group.length <= 1) {
        continue;
      }
      group.sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
      final survivor = group.first;
      if (survivor.id == null) {
        continue;
      }
      var merged = survivor;
      for (final duplicate in group.skip(1)) {
        merged = merged.copyWith(
          isHidden: merged.isHidden && duplicate.isHidden,
          threeInchCount: merged.threeInchCount + duplicate.threeInchCount,
          fiveInchCount: merged.fiveInchCount + duplicate.fiveInchCount,
          unsignedThreeInchCount:
              merged.unsignedThreeInchCount + duplicate.unsignedThreeInchCount,
          unsignedFiveInchCount:
              merged.unsignedFiveInchCount + duplicate.unsignedFiveInchCount,
          groupCutCount: merged.groupCutCount + duplicate.groupCutCount,
          threeInchShukudaiCount:
              merged.threeInchShukudaiCount + duplicate.threeInchShukudaiCount,
          fiveInchShukudaiCount:
              merged.fiveInchShukudaiCount + duplicate.fiveInchShukudaiCount,
        );
        final duplicateId = duplicate.id;
        if (duplicateId == null) {
          continue;
        }
        await db.update(
          activityRecordTableName,
          {'counter_id': survivor.id},
          where: 'counter_id = ?',
          whereArgs: [duplicateId],
        );
        await db.delete(
          tableName,
          where: 'id = ?',
          whereArgs: [duplicateId],
        );
      }
      final survivorId = survivor.id;
      if (survivorId == null) {
        continue;
      }
      await db.update(
        tableName,
        await _filterValuesForTable(db, tableName, _toDatabaseMap(merged)),
        where: 'id = ?',
        whereArgs: [survivorId],
      );
    }
  }

  static Future<_IdolIdentityLookup> _buildIdolIdentityLookup() async {
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
    final members = await IdolDatabaseService.getMembers();

    final byGroupAndMember = <String, IdolMember>{};
    final membersByName = <String, List<IdolMember>>{};
    final personNamesById = <int, String>{};

    for (final member in members) {
      final personId = member.personId;
      if (personId != null) {
        personNamesById.putIfAbsent(personId, () => member.resolvedPersonName);
      }

      for (final candidateName in _buildMemberNameAliases(member)) {
        final normalizedMember = _normalizeLookupPart(candidateName);
        if (normalizedMember.isEmpty) {
          continue;
        }

        final normalizedGroup = _normalizeLookupPart(member.groupName);
        if (normalizedGroup.isNotEmpty) {
          byGroupAndMember.putIfAbsent(
            '$normalizedGroup|$normalizedMember',
            () => member,
          );
        }
        membersByName
            .putIfAbsent(normalizedMember, () => <IdolMember>[])
            .add(member);
      }
    }

    final byUniqueMember = <String, IdolMember>{};
    for (final entry in membersByName.entries) {
      final personIds =
          entry.value.map((member) => member.personId).whereType<int>().toSet();
      if (personIds.length == 1) {
        byUniqueMember[entry.key] = entry.value.first;
      }
    }

    return _IdolIdentityLookup(
      byGroupAndMember: byGroupAndMember,
      byUniqueMember: byUniqueMember,
      personNamesById: personNamesById,
    );
  }

  static IdolMember? _matchIdentityMember(
    _IdolIdentityLookup lookup, {
    required String groupName,
    required List<String> normalizedNames,
  }) {
    final normalizedGroup = _normalizeLookupPart(groupName);
    if (normalizedGroup.isNotEmpty) {
      // When a group is known, only accept a member from that group. Falling
      // back to a globally unique name would merge same-name idols from
      // different groups after an identity id becomes stale.
      for (final normalizedName in normalizedNames) {
        if (normalizedName.isEmpty) {
          continue;
        }
        final matched =
            lookup.byGroupAndMember['$normalizedGroup|$normalizedName'];
        if (matched != null) {
          return matched;
        }
      }
      return null;
    }

    for (final normalizedName in normalizedNames) {
      if (normalizedName.isEmpty) {
        continue;
      }
      final matched = lookup.byUniqueMember[normalizedName];
      if (matched != null) {
        return matched;
      }
    }
    return null;
  }

  static _ResolvedIdentity? _resolveIdentity({
    required String name,
    required String groupName,
    required int? personId,
    required String personName,
    required _IdolIdentityLookup lookup,
  }) {
    final trimmedPersonName = personName.trim();
    final normalizedPersonName = _normalizeLookupPart(trimmedPersonName);
    final normalizedCounterName = _normalizeLookupPart(name);

    // Only trust an existing person id while it still points at a person in
    // the current idol database. After an idol database refresh the old id may
    // be gone while the counter keeps it; trusting it splits one member into
    // several home cards and breaks multi-record participant matching.
    if (personId != null) {
      final canonicalName = lookup.personNamesById[personId];
      if (canonicalName != null) {
        // A live person id is authoritative. The same real person can use a
        // different stage name in each group, and a same-name member of another
        // person must not steal the card during a full identity scan.
        // Missing ids (after an idol refresh) fall through to name matching.
        return _ResolvedIdentity(
          personId: personId,
          personName:
              trimmedPersonName.isNotEmpty ? trimmedPersonName : canonicalName,
        );
      }
    }

    final matchedMember = _matchIdentityMember(
      lookup,
      groupName: groupName,
      normalizedNames: [normalizedPersonName, normalizedCounterName],
    );
    if (matchedMember != null) {
      final matchedPersonName = matchedMember.personName.trim();
      // A member without a verified person id and without an explicit person
      // name must not invent one: filling personName would make the home page
      // group same-name idols from different groups into one card.
      if (matchedMember.personId != null || matchedPersonName.isNotEmpty) {
        return _ResolvedIdentity(
          personId: matchedMember.personId,
          personName: matchedPersonName.isNotEmpty
              ? matchedPersonName
              : matchedMember.resolvedPersonName,
        );
      }
    }

    if (personId != null || trimmedPersonName.isNotEmpty) {
      return _ResolvedIdentity(
        personId: personId,
        personName: trimmedPersonName,
      );
    }
    return null;
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

  static String _normalizeCounterIdentityKey(
    String name,
    String groupName,
    int personId,
  ) {
    return '${_normalizeCounterKey(name, groupName)}|person:$personId';
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

class _IdolIdentityLookup {
  final Map<String, IdolMember> byGroupAndMember;
  final Map<String, IdolMember> byUniqueMember;
  final Map<int, String> personNamesById;

  const _IdolIdentityLookup({
    required this.byGroupAndMember,
    required this.byUniqueMember,
    required this.personNamesById,
  });
}

class _ResolvedIdentity {
  final int? personId;
  final String personName;

  const _ResolvedIdentity({
    required this.personId,
    required this.personName,
  });
}

/// One photo of [DatabaseService.saveBatchImport].
class BatchMediaInput {
  final List<int> bytes;
  final String fileExtension;
  final ActivityRecordMediaProcessingMode processingMode;
  final int? recordId;
  final int? newRecordIndex;
  final ActivityRecordMediaOwnerScope? owner;
  final DateTime? capturedAt;
  final String sourceHash;
  final String cropQuadJson;

  const BatchMediaInput({
    required this.bytes,
    this.fileExtension = '.jpg',
    this.processingMode = ActivityRecordMediaProcessingMode.manualAssist,
    this.recordId,
    this.newRecordIndex,
    this.owner,
    this.capturedAt,
    this.sourceHash = '',
    this.cropQuadJson = '',
  }) : assert(recordId != null || newRecordIndex != null);
}

class BatchSaveResult {
  /// Ids of the inserted supplementary records, in input order.
  final List<int> recordIds;

  /// Ids of the inserted media rows, in input order.
  final List<int> mediaIds;

  const BatchSaveResult({required this.recordIds, required this.mediaIds});
}

/// Why a photo move was refused; the message is shown to the user as is.
class MediaMoveException implements Exception {
  final String message;
  const MediaMoveException(this.message);
  @override
  String toString() => message;
}

/// What [DatabaseService.moveActivityRecordMedia] did. [source] and
/// [target] are the records as they are after the move.
class MediaMoveOutcome {
  final int mediaId;
  final ActivityRecordModel source;
  final ActivityRecordModel target;
  final bool createdTarget;
  final int facesRemoved;
  final bool sourceRemoved;

  const MediaMoveOutcome({
    required this.mediaId,
    required this.source,
    required this.target,
    required this.createdTarget,
    required this.facesRemoved,
    this.sourceRemoved = false,
  });
}

class _PreparedActivityRecord {
  final ActivityRecordModel record;
  final bool insertedNewCounter;

  const _PreparedActivityRecord({
    required this.record,
    this.insertedNewCounter = false,
  });
}
