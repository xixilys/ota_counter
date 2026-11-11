import 'package:sqflite/sqflite.dart';

import '../models/activity_record_model.dart';
import '../models/ticket_type_model.dart';
import 'database_service.dart';

class TicketPricingService {
  static const String ticketTypesTable = 'ticket_types';
  static const String presetsTable = 'ticket_price_presets';

  static const List<(String, double, bool)> _defaults = [
    ('免费票', 0, true),
    ('预售票', 0, false),
    ('现场票', 0, false),
    ('学生票', 0, false),
    ('女性票', 0, false),
    ('特典票', 0, false),
    ('VIP票', 0, false),
  ];

  static Future<List<TicketTypeModel>> getTicketTypes() async {
    final db = await DatabaseService.database;
    await _ensureDefaults(db);
    final rows = await db.query(
      ticketTypesTable,
      orderBy: 'sort_order ASC, name COLLATE NOCASE ASC',
    );
    return rows.map(TicketTypeModel.fromMap).toList(growable: false);
  }

  static Future<void> _ensureDefaults(DatabaseExecutor db) async {
    final count = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM $ticketTypesTable',
    );
    final value = (count.first['count'] as num?)?.toInt() ?? 0;
    if (value > 0) return;
    final now = DateTime.now();
    for (var index = 0; index < _defaults.length; index++) {
      final item = _defaults[index];
      await db.insert(
        ticketTypesTable,
        {
          'name': item.$1,
          'default_price': item.$2,
          'is_free': item.$3 ? 1 : 0,
          'sort_order': index,
          'updated_at': now.toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  static Future<int> upsertTicketType(TicketTypeModel type) async {
    final db = await DatabaseService.database;
    final values = {
      'name': type.name.trim(),
      'default_price': type.defaultPrice,
      'is_free': type.isFree ? 1 : 0,
      'sort_order': type.sortOrder,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (type.id != null) {
      await db.update(
        ticketTypesTable,
        values,
        where: 'id = ?',
        whereArgs: [type.id],
      );
      return type.id!;
    }

    final existing = await db.query(
      ticketTypesTable,
      columns: ['id'],
      where: 'name COLLATE NOCASE = ?',
      whereArgs: [type.name.trim()],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final id = (existing.first['id'] as num).toInt();
      await db.update(
        ticketTypesTable,
        values,
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    }
    return db.insert(ticketTypesTable, values);
  }

  static Future<void> deleteTicketType(int id) async {
    final db = await DatabaseService.database;
    await db.delete(ticketTypesTable, where: 'id = ?', whereArgs: [id]);
  }

  static String scopeKey({
    String eventName = '',
    String venueName = '',
    String groupName = '',
  }) {
    final event = _normalize(eventName);
    final venue = _normalize(venueName);
    if (event.isNotEmpty) {
      return 'event:$event|$venue';
    }
    final group = _normalize(groupName);
    return group.isEmpty ? 'global' : 'group:$group';
  }

  /// Rebuilds per-event price memory from already-saved ticket records.
  /// Useful after importing old data or changing ticket types.
  static Future<int> rebuildFromHistory({int limit = 2000}) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      DatabaseService.activityRecordTableName,
      where: "record_type = 'ticket' AND TRIM(COALESCE(ticket_type, '')) != ''",
      orderBy: 'occurred_at DESC',
      limit: limit,
    );
    var imported = 0;
    for (final row in rows) {
      try {
        final record = ActivityRecordModel.fromMap(row);
        await _rememberRecordUnsafe(record);
        imported++;
      } catch (_) {
        // Skip one malformed historical row instead of aborting the import.
      }
    }
    return imported;
  }

  static Future<TicketPriceSuggestion> suggestPrice({
    String eventName = '',
    String venueName = '',
    String groupName = '',
    String ticketType = '',
    double fallback = 0,
  }) async {
    final db = await DatabaseService.database;
    final normalizedType = ticketType.trim();
    if (normalizedType.isNotEmpty) {
      final presetRows = await db.query(
        presetsTable,
        where: 'scope_key = ? AND ticket_type = ?',
        whereArgs: [
          scopeKey(
            eventName: eventName,
            venueName: venueName,
            groupName: groupName,
          ),
          normalizedType,
        ],
        orderBy: 'updated_at DESC',
        limit: 1,
      );
      if (presetRows.isNotEmpty) {
        final preset = TicketPricePreset.fromMap(presetRows.first);
        return TicketPriceSuggestion(
          unitPrice: preset.isFree ? 0 : preset.unitPrice,
          isFree: preset.isFree,
          source: '该场次上次价格',
        );
      }
    }

    final typeRows = await db.query(
      ticketTypesTable,
      where: 'name COLLATE NOCASE = ?',
      whereArgs: [normalizedType],
      limit: 1,
    );
    if (typeRows.isNotEmpty) {
      final type = TicketTypeModel.fromMap(typeRows.first);
      return TicketPriceSuggestion(
        unitPrice: type.isFree ? 0 : type.defaultPrice,
        isFree: type.isFree,
        source: type.defaultPrice > 0 ? '票种默认价' : '票种默认价（待完善）',
      );
    }

    return TicketPriceSuggestion(
      unitPrice: fallback,
      isFree: false,
      source: '自由输入',
    );
  }

  static Future<void> rememberRecord(ActivityRecordModel record) async {
    try {
      await _rememberRecordUnsafe(record);
    } catch (_) {
      // Price memory is a convenience; a failed preset must never make the
      // already-saved ticket record look like it failed.
    }
  }

  static Future<void> _rememberRecordUnsafe(ActivityRecordModel record) async {
    if (!record.isTicket || record.ticketType.trim().isEmpty) {
      return;
    }
    final db = await DatabaseService.database;
    final typeName = record.ticketType.trim();
    final scope = scopeKey(
      eventName: record.activityName.trim().isEmpty
          ? record.subjectName
          : record.activityName,
      venueName: record.venueName,
      groupName: record.groupName,
    );
    final now = DateTime.now();
    await db.insert(
      presetsTable,
      {
        'scope_key': scope,
        'event_name': record.activityName.trim().isEmpty
            ? record.subjectName
            : record.activityName,
        'venue_name': record.venueName,
        'group_name': record.groupName,
        'ticket_type': typeName,
        'unit_price': record.resolvedTicketIsFree ? 0 : record.ticketUnitPrice,
        'is_free': record.resolvedTicketIsFree ? 1 : 0,
        'updated_at': now.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Learn a useful global default the first time a previously-empty type is
    // used, while leaving explicit user-edited prices alone.
    final typeRows = await db.query(
      ticketTypesTable,
      where: 'name COLLATE NOCASE = ?',
      whereArgs: [typeName],
      limit: 1,
    );
    if (typeRows.isNotEmpty) {
      final type = TicketTypeModel.fromMap(typeRows.first);
      if (type.defaultPrice == 0 &&
          !type.isFree &&
          !record.resolvedTicketIsFree &&
          record.ticketUnitPrice > 0) {
        await db.update(
          ticketTypesTable,
          {
            'default_price': record.ticketUnitPrice,
            'updated_at': now.toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [type.id],
        );
      }
    }
  }

  static Future<List<TicketPricePreset>> getPresets() async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      presetsTable,
      orderBy: 'updated_at DESC, event_name COLLATE NOCASE ASC',
      limit: 200,
    );
    return rows.map(TicketPricePreset.fromMap).toList(growable: false);
  }

  static Future<TicketStats> getStats({
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await DatabaseService.database;
    final where = <String>['record_type = ?'];
    final args = <Object?>[ActivityRecordType.ticket.dbValue];
    if (from != null) {
      where.add('occurred_at >= ?');
      args.add(DateTime(from.year, from.month, from.day).toIso8601String());
    }
    if (to != null) {
      final end =
          DateTime(to.year, to.month, to.day).add(const Duration(days: 1));
      where.add('occurred_at < ?');
      args.add(end.toIso8601String());
    }
    final whereSql = where.join(' AND ');
    final rows = await db.rawQuery(
      '''
      SELECT
        COUNT(*) AS record_count,
        COALESCE(SUM(ticket_quantity), 0) AS ticket_count,
        COALESCE(SUM(total_amount), 0) AS amount,
        COALESCE(SUM(CASE WHEN ticket_is_free = 1 OR
          (ticket_is_free IS NULL AND ticket_unit_price <= 0 AND total_amount <= 0)
          THEN ticket_quantity ELSE 0 END), 0) AS free_ticket_count,
        COALESCE(SUM(CASE WHEN ticket_is_free = 0 OR
          (ticket_is_free IS NULL AND (ticket_unit_price > 0 OR total_amount > 0))
          THEN ticket_quantity ELSE 0 END), 0) AS paid_ticket_count
      FROM ${DatabaseService.activityRecordTableName}
      WHERE $whereSql
      ''',
      args,
    );
    final summary = rows.first;
    final typeRows = await db.rawQuery(
      '''
      SELECT COALESCE(NULLIF(TRIM(ticket_type), ''), '未分类') AS type,
             COALESCE(SUM(ticket_quantity), 0) AS quantity,
             COALESCE(SUM(total_amount), 0) AS amount
      FROM ${DatabaseService.activityRecordTableName}
      WHERE $whereSql
      GROUP BY type
      ORDER BY quantity DESC, type ASC
      ''',
      args,
    );
    final countByType = <String, int>{};
    final amountByType = <String, double>{};
    for (final row in typeRows) {
      final type = (row['type'] ?? '未分类').toString();
      countByType[type] = ((row['quantity'] as num?) ?? 0).toInt();
      amountByType[type] = ((row['amount'] as num?) ?? 0).toDouble();
    }
    return TicketStats(
      recordCount: ((summary['record_count'] as num?) ?? 0).toInt(),
      ticketCount: ((summary['ticket_count'] as num?) ?? 0).toInt(),
      freeTicketCount: ((summary['free_ticket_count'] as num?) ?? 0).toInt(),
      paidTicketCount: ((summary['paid_ticket_count'] as num?) ?? 0).toInt(),
      amount: ((summary['amount'] as num?) ?? 0).toDouble(),
      countByType: countByType,
      amountByType: amountByType,
    );
  }

  static String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'), '');
  }
}
