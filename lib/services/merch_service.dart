import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/merch_purchase_model.dart';
import 'database_service.dart';

class MerchService {
  static const String kindsTable = DatabaseService.merchKindTableName;
  static const String purchasesTable = DatabaseService.merchPurchaseTableName;
  static const String photoDirectoryName = 'merch_photos';

  /// Common 周边 for the Chinese underground-idol scene. Labels are kept short
  /// because they double as quick-add chips.
  static const List<String> presetKinds = [
    '生写真',
    '签名',
    '吧唧',
    '亚克力立牌',
    '挂件',
    '应援棒',
    '毛巾',
    'T恤/应援服',
    '专辑/CD',
    '海报',
    '明信片',
    '盲盒',
    '其他',
  ];

  static Future<List<MerchKindModel>> getKinds() async {
    final db = await DatabaseService.database;
    await _ensurePresets(db);
    final rows = await db.query(
      kindsTable,
      orderBy: 'is_preset DESC, sort_order ASC, name COLLATE NOCASE ASC',
    );
    return rows.map(MerchKindModel.fromMap).toList(growable: false);
  }

  static Future<void> _ensurePresets(DatabaseExecutor db) async {
    final now = DateTime.now().toIso8601String();
    for (var index = 0; index < presetKinds.length; index++) {
      await db.insert(
        kindsTable,
        {
          'name': presetKinds[index],
          'default_price': 0,
          'is_preset': 1,
          'sort_order': index,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  static Future<int> addCustomKind(String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('周边种类名称不能为空');
    }
    final db = await DatabaseService.database;
    await _ensurePresets(db);
    final existing = await db.query(
      kindsTable,
      columns: ['id', 'is_preset'],
      where: 'name COLLATE NOCASE = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final isPreset =
          ((existing.first['is_preset'] as num?)?.toInt() ?? 0) == 1;
      if (isPreset) {
        throw StateError('「$normalized」已经是预置种类');
      }
      return (existing.first['id'] as num).toInt();
    }
    final sortOrder = await _nextSortOrder(db);
    return db.insert(kindsTable, {
      'name': normalized,
      'default_price': 0,
      'is_preset': 0,
      'sort_order': sortOrder,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<int> _nextSortOrder(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM $kindsTable',
    );
    return ((rows.first['max_order'] as num?)?.toInt() ?? -1) + 1;
  }

  static Future<void> upsertKind(MerchKindModel kind) async {
    final normalized = kind.name.trim();
    if (normalized.isEmpty) return;
    final db = await DatabaseService.database;
    final values = {
      'name': normalized,
      'default_price': kind.defaultPrice < 0 ? 0 : kind.defaultPrice,
      'is_preset': kind.isPreset ? 1 : 0,
      'sort_order': kind.sortOrder,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (kind.id != null) {
      await db.update(
        kindsTable,
        values,
        where: 'id = ?',
        whereArgs: [kind.id],
      );
      return;
    }
    await db.insert(
      kindsTable,
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> deleteKind(int id) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      kindsTable,
      columns: ['is_preset'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isNotEmpty &&
        ((rows.first['is_preset'] as num?)?.toInt() ?? 0) == 1) {
      throw StateError('预置种类不能删除');
    }
    await db.delete(kindsTable, where: 'id = ?', whereArgs: [id]);
  }

  /// Purchases per kind label, used to warn before deleting a custom kind.
  static Future<Map<String, int>> getKindUsageCounts() async {
    final db = await DatabaseService.database;
    final rows = await db.rawQuery('''
      SELECT kind AS kind, COALESCE(SUM(quantity), 0) AS quantity
      FROM $purchasesTable
      GROUP BY kind
    ''');
    return {
      for (final row in rows)
        (row['kind'] ?? '').toString():
            ((row['quantity'] as num?) ?? 0).toInt(),
    };
  }

  static Future<List<MerchPurchaseModel>> getPurchases({
    DateTime? from,
    DateTime? to,
    String? kind,
  }) async {
    final db = await DatabaseService.database;
    final where = <String>[];
    final args = <Object?>[];
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
    final normalizedKind = kind?.trim() ?? '';
    if (normalizedKind.isNotEmpty) {
      where.add('kind = ?');
      args.add(normalizedKind);
    }
    final rows = await db.query(
      purchasesTable,
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'occurred_at DESC, id DESC',
    );
    return rows.map(MerchPurchaseModel.fromMap).toList(growable: false);
  }

  static Future<MerchStats> getStats({
    DateTime? from,
    DateTime? to,
  }) async {
    final purchases = await getPurchases(from: from, to: to);
    return MerchStats.fromPurchases(purchases);
  }

  /// Explicit date-range entry point for the chart/statistics page. The range
  /// includes whole days for [from] and [to].
  static Future<MerchStats> getStatsForRange({
    required DateTime from,
    required DateTime to,
  }) {
    return getStats(from: from, to: to);
  }

  static Future<int> savePurchase(MerchPurchaseModel purchase) async {
    final db = await DatabaseService.database;
    final normalized = purchase.copyWith(
      kind: purchase.kind.trim(),
      memberName: purchase.memberName.trim(),
      groupName: purchase.groupName.trim(),
      eventName: purchase.eventName.trim(),
      venueName: purchase.venueName.trim(),
      sessionLabel: purchase.sessionLabel.trim(),
      note: purchase.note.trim(),
      quantity: purchase.quantity > 0 ? purchase.quantity : 1,
      unitPrice: purchase.unitPrice < 0 ? 0 : purchase.unitPrice,
      totalAmount: purchase.resolvedTotalAmount,
      updatedAt: DateTime.now(),
    );
    await _ensureKindExists(db, normalized.kind);
    final values = normalized.toMap()..remove('id');
    if (normalized.id != null) {
      await db.update(
        purchasesTable,
        values,
        where: 'id = ?',
        whereArgs: [normalized.id],
      );
      await _learnKindPrice(db, normalized);
      return normalized.id!;
    }
    final id = await db.insert(purchasesTable, values);
    await _learnKindPrice(db, normalized);
    return id;
  }

  /// A kind's first paid purchase becomes its quick-add default, mirroring the
  /// ticket type price memory. Explicit user prices (default_price > 0) stay.
  static Future<void> _learnKindPrice(
    DatabaseExecutor db,
    MerchPurchaseModel purchase,
  ) async {
    final kind = purchase.kind.trim();
    if (kind.isEmpty || purchase.unitPrice <= 0) return;
    final rows = await db.query(
      kindsTable,
      columns: ['id', 'default_price'],
      where: 'name COLLATE NOCASE = ?',
      whereArgs: [kind],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final defaultPrice = (rows.first['default_price'] as num?)?.toDouble() ?? 0;
    if (defaultPrice > 0) return;
    await db.update(
      kindsTable,
      {
        'default_price': purchase.unitPrice,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [rows.first['id']],
    );
  }

  static Future<void> _ensureKindExists(
    DatabaseExecutor db,
    String name,
  ) async {
    final normalized = name.trim();
    if (normalized.isEmpty) return;
    final rows = await db.query(
      kindsTable,
      columns: ['id'],
      where: 'name COLLATE NOCASE = ?',
      whereArgs: [normalized],
      limit: 1,
    );
    if (rows.isNotEmpty) return;
    final sortOrder = await _nextSortOrder(db);
    await db.insert(
      kindsTable,
      {
        'name': normalized,
        'default_price': 0,
        'is_preset': 0,
        'sort_order': sortOrder,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> deletePurchase(int id) async {
    final db = await DatabaseService.database;
    final rows = await db.query(
      purchasesTable,
      columns: ['photo_path'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final photoPath =
        rows.isEmpty ? '' : (rows.first['photo_path'] ?? '').toString().trim();
    await db.delete(purchasesTable, where: 'id = ?', whereArgs: [id]);
    await deletePhoto(photoPath);
  }

  static Future<String> savePhoto(File source) async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, photoDirectoryName));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final extension = p.extension(source.path).toLowerCase();
    final targetName =
        '${DateTime.now().microsecondsSinceEpoch}${extension.isEmpty ? '.jpg' : extension}';
    final target = File(p.join(directory.path, targetName));
    await source.copy(target.path);
    return target.path;
  }

  static Future<void> deletePhoto(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) return;
    try {
      final file = File(normalized);
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Losing an orphan photo is better than failing the record action.
    }
  }
}
