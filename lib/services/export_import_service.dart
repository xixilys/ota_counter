import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../models/counter_model.dart';
import 'database_service.dart';
import 'idol_database_service.dart';
import 'image_service.dart';

enum ImportPayloadKind {
  legacyCounters,
  otaBundle,
  fullBackup,
}

class FullBackupBundle {
  static const String backupType = 'ota_counter_full_backup';
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String exportedAt;
  final Map<String, List<Map<String, Object?>>> mainDatabase;
  final Map<String, List<Map<String, Object?>>> idolDatabase;
  final Map<String, List<Map<String, Object?>>> imageDatabase;
  final Map<String, List<int>> documentFiles;

  const FullBackupBundle({
    required this.formatVersion,
    required this.exportedAt,
    required this.mainDatabase,
    required this.idolDatabase,
    required this.imageDatabase,
    required this.documentFiles,
  });

  Map<String, Object?> toManifest() {
    return {
      'type': backupType,
      'format_version': formatVersion,
      'exported_at': exportedAt,
      'main_database': mainDatabase,
      'idol_database': idolDatabase,
      'image_database': imageDatabase,
    };
  }

  factory FullBackupBundle.fromManifest({
    required Map<String, Object?> manifest,
    required Map<String, List<int>> documentFiles,
  }) {
    final type = (manifest['type'] ?? '') as String;
    if (type != backupType) {
      throw const FormatException('不是 OTA Counter 完整备份文件');
    }

    final formatVersion =
        ((manifest['format_version'] ?? 0) as num?)?.toInt() ?? 0;
    if (formatVersion <= 0) {
      throw const FormatException('备份文件格式版本无效');
    }

    return FullBackupBundle(
      formatVersion: formatVersion,
      exportedAt: (manifest['exported_at'] ?? '') as String,
      mainDatabase: _readTableDump(manifest['main_database']),
      idolDatabase: _readTableDump(manifest['idol_database']),
      imageDatabase: _readTableDump(manifest['image_database']),
      documentFiles: documentFiles,
    );
  }

  static Map<String, List<Map<String, Object?>>> _readTableDump(
    Object? value,
  ) {
    if (value is! Map) {
      return const {};
    }

    final result = <String, List<Map<String, Object?>>>{};
    value.forEach((key, tableRows) {
      if (key == null) {
        return;
      }
      result[key.toString()] = _readRowList(tableRows);
    });
    return result;
  }

  static List<Map<String, Object?>> _readRowList(Object? value) {
    if (value is! List) {
      return const [];
    }

    return value.whereType<Map>().map((row) {
      return row.map(
        (key, cellValue) => MapEntry(key.toString(), cellValue),
      );
    }).toList(growable: false);
  }
}

class ImportPayload {
  final ImportPayloadKind kind;
  final String fileName;
  final String rawJson;
  final List<CounterModel> counters;
  final FullBackupBundle? fullBackup;

  const ImportPayload({
    required this.kind,
    required this.fileName,
    required this.rawJson,
    this.counters = const [],
    this.fullBackup,
  });

  bool get isLegacyCounters => kind == ImportPayloadKind.legacyCounters;
  bool get isOtaBundle => kind == ImportPayloadKind.otaBundle;
  bool get isFullBackup => kind == ImportPayloadKind.fullBackup;
}

class ExportImportService {
  static const String _manifestArchivePath = 'manifest.json';
  static const String _documentsArchiveRoot = 'documents';

  static Future<void> exportData() async {
    final backup = await _buildFullBackupBundle();
    final archive = Archive();
    final manifestBytes = utf8.encode(jsonEncode(backup.toManifest()));
    archive.addFile(
      ArchiveFile(
        _manifestArchivePath,
        manifestBytes.length,
        manifestBytes,
      ),
    );

    for (final entry in backup.documentFiles.entries) {
      archive.addFile(
        ArchiveFile(
          _archiveDocumentPath(entry.key),
          entry.value.length,
          entry.value,
        ),
      );
    }

    final zipBytes = ZipEncoder().encode(archive);

    final tempDir = await getTemporaryDirectory();
    final fileName = 'ota_counter_backup_${_timestampForFileName()}.zip';
    final tempFile = File(p.join(tempDir.path, fileName));
    await tempFile.writeAsBytes(zipBytes, flush: true);

    await Share.shareXFiles(
      [XFile(tempFile.path)],
      subject: 'OTA Counter 完整备份',
    );
  }

  static Future<ImportPayload?> pickImportPayload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'json', 'zip'],
      dialogTitle: '选择要导入的文件',
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final file = result.files.first;
    final path = file.path;
    final rawBytes = file.bytes ??
        (path != null ? await File(path).readAsBytes() : const <int>[]);

    return parseImportPayload(
      fileName: file.name,
      rawBytes: rawBytes,
    );
  }

  static ImportPayload parseImportPayload({
    required String fileName,
    required List<int> rawBytes,
  }) {
    if (rawBytes.isEmpty) {
      throw const FormatException('导入文件为空');
    }

    if (_looksLikeZip(rawBytes)) {
      final fullBackup = _parseFullBackup(rawBytes);
      return ImportPayload(
        kind: ImportPayloadKind.fullBackup,
        fileName: fileName,
        rawJson: '',
        fullBackup: fullBackup,
      );
    }

    final rawJson = utf8.decode(rawBytes, allowMalformed: true);
    final sanitized = rawJson.replaceFirst('\ufeff', '').trim();
    if (sanitized.isEmpty) {
      throw const FormatException('导入文件为空');
    }

    final decoded = jsonDecode(sanitized);
    final counters = _tryParseLegacyCounters(decoded);
    if (counters != null) {
      return ImportPayload(
        kind: ImportPayloadKind.legacyCounters,
        fileName: fileName,
        rawJson: sanitized,
        counters: counters,
      );
    }

    if (_looksLikeOtaBundle(decoded) || _looksLikeOtaRecordList(decoded)) {
      return ImportPayload(
        kind: ImportPayloadKind.otaBundle,
        fileName: fileName,
        rawJson: sanitized,
      );
    }

    throw const FormatException(
      '文件格式错误：当前仅支持完整备份、旧版计数器备份或 OTA 历史导出文件',
    );
  }

  static Future<void> restoreFullBackup(FullBackupBundle backup) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    await DatabaseService.clearAppData();
    await _clearImageLibrary();
    await _clearIdolDatabase();
    await _clearManagedImportDirectories(documentsDirectory.path);
    await _restoreDocumentFiles(backup.documentFiles, documentsDirectory.path);
    await _restoreMainDatabase(
      backup.mainDatabase,
      documentsDirectory.path,
    );
    await _restoreIdolDatabase(backup.idolDatabase);
    await _restoreImageDatabase(
      backup.imageDatabase,
      documentsDirectory.path,
    );
  }

  static Future<FullBackupBundle> _buildFullBackupBundle() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final pathMapper = _DocumentPathMapper(documentsDirectory.path);

    final mainDb = await DatabaseService.database;
    final rawActivityRecordMedia = await _readTableRows(
      mainDb,
      DatabaseService.activityRecordMediaTableName,
    );
    final activityRecordMedia = await _normalizeRowsWithDocumentPaths(
      rows: rawActivityRecordMedia,
      pathColumn: 'path',
      pathMapper: pathMapper,
    );

    final imageDb = await ImageService.database;
    final rawImages = await _readTableRows(
      imageDb,
      ImageService.tableName,
    );
    final images = await _normalizeRowsWithDocumentPaths(
      rows: rawImages,
      pathColumn: 'path',
      pathMapper: pathMapper,
    );

    final idolDb = await IdolDatabaseService.database;

    final documentFiles = <String, List<int>>{
      ...activityRecordMedia.documentFiles,
      ...images.documentFiles,
    };

    return FullBackupBundle(
      formatVersion: FullBackupBundle.currentFormatVersion,
      exportedAt: DateTime.now().toIso8601String(),
      mainDatabase: {
        DatabaseService.tableName: await _readTableRows(
          mainDb,
          DatabaseService.tableName,
        ),
        DatabaseService.groupPricingTableName: await _readTableRows(
          mainDb,
          DatabaseService.groupPricingTableName,
        ),
        DatabaseService.activityRecordTableName: await _readTableRows(
          mainDb,
          DatabaseService.activityRecordTableName,
        ),
        DatabaseService.activityRecordMediaTableName: activityRecordMedia.rows,
        DatabaseService.counterSyncTableName: await _readTableRows(
          mainDb,
          DatabaseService.counterSyncTableName,
        ),
      },
      idolDatabase: {
        'idol_people': await _readTableRows(idolDb, 'idol_people'),
        'idol_groups': await _readTableRows(idolDb, 'idol_groups'),
        'idol_members': await _readTableRows(idolDb, 'idol_members'),
        'idol_meta': await _readTableRows(idolDb, 'idol_meta'),
      },
      imageDatabase: {
        ImageService.tableName: images.rows,
      },
      documentFiles: documentFiles,
    );
  }

  static Future<List<Map<String, Object?>>> _readTableRows(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.query(table);
    return rows
        .map((row) => row.map((key, value) => MapEntry(key, value)))
        .toList(growable: false);
  }

  static Future<_NormalizedDocumentRows> _normalizeRowsWithDocumentPaths({
    required List<Map<String, Object?>> rows,
    required String pathColumn,
    required _DocumentPathMapper pathMapper,
  }) async {
    final normalizedRows = <Map<String, Object?>>[];
    final documentFiles = <String, List<int>>{};

    for (final row in rows) {
      final nextRow = Map<String, Object?>.from(row);
      final rawPath = (row[pathColumn] ?? '').toString().trim();
      if (rawPath.isNotEmpty) {
        final relativePath = pathMapper.relativePathFor(rawPath);
        if (relativePath != null) {
          nextRow[pathColumn] = relativePath;
          if (!documentFiles.containsKey(relativePath)) {
            final sourceFile = File(rawPath);
            if (await sourceFile.exists()) {
              documentFiles[relativePath] = await sourceFile.readAsBytes();
            }
          }
        }
      }
      normalizedRows.add(nextRow);
    }

    return _NormalizedDocumentRows(
      rows: normalizedRows,
      documentFiles: documentFiles,
    );
  }

  static Future<void> _restoreMainDatabase(
    Map<String, List<Map<String, Object?>>> tables,
    String documentsPath,
  ) async {
    final db = await DatabaseService.database;
    await db.transaction((txn) async {
      await _insertRows(
        txn,
        table: DatabaseService.tableName,
        rows: tables[DatabaseService.tableName] ?? const [],
      );
      await _insertRows(
        txn,
        table: DatabaseService.groupPricingTableName,
        rows: tables[DatabaseService.groupPricingTableName] ?? const [],
      );
      await _insertRows(
        txn,
        table: DatabaseService.activityRecordTableName,
        rows: tables[DatabaseService.activityRecordTableName] ?? const [],
      );
      await _insertRows(
        txn,
        table: DatabaseService.activityRecordMediaTableName,
        rows: _rowsWithAbsoluteDocumentPaths(
          tables[DatabaseService.activityRecordMediaTableName] ?? const [],
          documentsPath: documentsPath,
          pathColumn: 'path',
        ),
      );
      await _insertRows(
        txn,
        table: DatabaseService.counterSyncTableName,
        rows: tables[DatabaseService.counterSyncTableName] ?? const [],
      );
    });
  }

  static Future<void> _restoreIdolDatabase(
    Map<String, List<Map<String, Object?>>> tables,
  ) async {
    final db = await IdolDatabaseService.database;
    await db.transaction((txn) async {
      await _insertRows(
        txn,
        table: 'idol_people',
        rows: tables['idol_people'] ?? const [],
      );
      await _insertRows(
        txn,
        table: 'idol_groups',
        rows: tables['idol_groups'] ?? const [],
      );
      await _insertRows(
        txn,
        table: 'idol_members',
        rows: tables['idol_members'] ?? const [],
      );
      await _insertRows(
        txn,
        table: 'idol_meta',
        rows: tables['idol_meta'] ?? const [],
      );
    });
  }

  static Future<void> _restoreImageDatabase(
    Map<String, List<Map<String, Object?>>> tables,
    String documentsPath,
  ) async {
    final db = await ImageService.database;
    await db.transaction((txn) async {
      await _insertRows(
        txn,
        table: ImageService.tableName,
        rows: _rowsWithAbsoluteDocumentPaths(
          tables[ImageService.tableName] ?? const [],
          documentsPath: documentsPath,
          pathColumn: 'path',
        ),
      );
    });
  }

  static Future<void> _insertRows(
    DatabaseExecutor db, {
    required String table,
    required List<Map<String, Object?>> rows,
  }) async {
    final columns = await _tableColumns(db, table);
    if (columns.isEmpty) {
      return;
    }

    for (final row in rows) {
      final filtered = <String, Object?>{};
      row.forEach((key, value) {
        if (columns.contains(key)) {
          filtered[key] = value;
        }
      });
      if (filtered['id'] == null) {
        filtered.remove('id');
      }
      await db.insert(table, filtered);
    }
  }

  static Future<Set<String>> _tableColumns(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows
        .map((row) => (row['name'] ?? '') as String)
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  static List<Map<String, Object?>> _rowsWithAbsoluteDocumentPaths(
    List<Map<String, Object?>> rows, {
    required String documentsPath,
    required String pathColumn,
  }) {
    return rows.map((row) {
      final nextRow = Map<String, Object?>.from(row);
      final relativePath = (row[pathColumn] ?? '').toString().trim();
      if (relativePath.isNotEmpty) {
        nextRow[pathColumn] = p.join(
          documentsPath,
          p.joinAll(p.posix.split(relativePath)),
        );
      }
      return nextRow;
    }).toList(growable: false);
  }

  static Future<void> _restoreDocumentFiles(
    Map<String, List<int>> documentFiles,
    String documentsPath,
  ) async {
    for (final entry in documentFiles.entries) {
      final targetPath = p.join(
        documentsPath,
        p.joinAll(p.posix.split(entry.key)),
      );
      final targetFile = File(targetPath);
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsBytes(entry.value, flush: true);
    }
  }

  static Future<void> _clearImageLibrary() async {
    final db = await ImageService.database;
    final rows = await db.query(ImageService.tableName, columns: ['path']);
    for (final row in rows) {
      final path = (row['path'] ?? '').toString();
      if (path.isEmpty) {
        continue;
      }
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await db.delete(ImageService.tableName);
  }

  static Future<void> _clearIdolDatabase() async {
    final db = await IdolDatabaseService.database;
    await db.transaction((txn) async {
      await txn.delete('idol_members');
      await txn.delete('idol_groups');
      await txn.delete('idol_people');
      await txn.delete('idol_meta');
    });
  }

  static Future<void> _clearManagedImportDirectories(
      String documentsPath) async {
    final directories = [
      Directory(p.join(documentsPath, 'activity_record_media')),
      Directory(p.join(documentsPath, 'imported_files')),
    ];

    for (final directory in directories) {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  static FullBackupBundle _parseFullBackup(List<int> rawBytes) {
    final archive = ZipDecoder().decodeBytes(rawBytes, verify: true);
    final manifestFile = archive.findFile(_manifestArchivePath);
    if (manifestFile == null) {
      throw const FormatException('未找到完整备份清单');
    }

    final manifestJson = utf8.decode(_archiveFileBytes(manifestFile));
    final decoded = jsonDecode(manifestJson);
    if (decoded is! Map) {
      throw const FormatException('完整备份清单格式错误');
    }

    final documentFiles = <String, List<int>>{};
    for (final file in archive.files) {
      if (!file.isFile || !file.name.startsWith('$_documentsArchiveRoot/')) {
        continue;
      }
      final relativePath = p.posix.normalize(
        file.name.substring(_documentsArchiveRoot.length + 1),
      );
      if (relativePath.isEmpty || relativePath == '.') {
        continue;
      }
      documentFiles[relativePath] = _archiveFileBytes(file);
    }

    return FullBackupBundle.fromManifest(
      manifest: decoded.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      documentFiles: documentFiles,
    );
  }

  static List<int> _archiveFileBytes(ArchiveFile file) {
    final content = file.readBytes();
    if (content == null) {
      throw const FormatException('备份文件内容无法读取');
    }
    return List<int>.from(content);
  }

  static String _archiveDocumentPath(String relativePath) {
    return p.posix.join(
      _documentsArchiveRoot,
      p.posix.joinAll(p.posix.split(relativePath)),
    );
  }

  static bool _looksLikeZip(List<int> bytes) {
    if (bytes.length < 4) {
      return false;
    }
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4b &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
        (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);
  }

  static String _timestampForFileName() {
    final now = DateTime.now();

    String twoDigits(int value) => value.toString().padLeft(2, '0');

    return '${now.year}'
        '${twoDigits(now.month)}'
        '${twoDigits(now.day)}_'
        '${twoDigits(now.hour)}'
        '${twoDigits(now.minute)}'
        '${twoDigits(now.second)}';
  }

  static List<CounterModel>? _tryParseLegacyCounters(Object? decoded) {
    if (decoded is! List) {
      return null;
    }
    if (decoded.isEmpty) {
      return <CounterModel>[];
    }

    final counters = <CounterModel>[];
    for (final item in decoded) {
      if (item is! Map) {
        return null;
      }

      final mapped = item.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (_looksLikeOtaRecordMap(mapped)) {
        return null;
      }

      final counter = CounterModel.fromMap(mapped);
      if (counter.name.trim().isEmpty) {
        return null;
      }
      counters.add(counter);
    }
    return counters;
  }

  static bool _looksLikeOtaBundle(Object? decoded) {
    if (decoded is! Map) {
      return false;
    }

    return decoded.containsKey('records') ||
        decoded.containsKey('groups') ||
        decoded.containsKey('idols');
  }

  static bool _looksLikeOtaRecordList(Object? decoded) {
    if (decoded is! List || decoded.isEmpty) {
      return false;
    }

    return decoded.whereType<Map>().any((item) => _looksLikeOtaRecordMap(item));
  }

  static bool _looksLikeOtaRecordMap(Map<dynamic, dynamic> map) {
    final keys = map.keys.map((key) => key.toString()).toSet();
    return keys.contains('cutType') ||
        keys.contains('qty') ||
        keys.contains('ts') ||
        keys.contains('idol') ||
        keys.contains('finalAmount');
  }
}

class _NormalizedDocumentRows {
  final List<Map<String, Object?>> rows;
  final Map<String, List<int>> documentFiles;

  const _NormalizedDocumentRows({
    required this.rows,
    required this.documentFiles,
  });
}

class _DocumentPathMapper {
  final String documentsPath;
  final Map<String, String> _mappedPaths = {};
  final Set<String> _usedRelativePaths = {};

  _DocumentPathMapper(this.documentsPath);

  String? relativePathFor(String sourcePath) {
    final normalizedSourcePath = p.normalize(sourcePath.trim());
    if (normalizedSourcePath.isEmpty) {
      return null;
    }

    final existing = _mappedPaths[normalizedSourcePath];
    if (existing != null) {
      return existing;
    }

    late final String candidate;
    if (p.isWithin(documentsPath, normalizedSourcePath)) {
      candidate = p.relative(normalizedSourcePath, from: documentsPath);
    } else {
      candidate = p.join('imported_files', p.basename(normalizedSourcePath));
    }

    final normalizedCandidate = p.posix.joinAll(p.split(candidate));
    final uniquePath = _uniqueRelativePath(normalizedCandidate);
    _mappedPaths[normalizedSourcePath] = uniquePath;
    return uniquePath;
  }

  String _uniqueRelativePath(String candidate) {
    if (_usedRelativePaths.add(candidate)) {
      return candidate;
    }

    final dirname = p.posix.dirname(candidate);
    final basename = p.posix.basenameWithoutExtension(candidate);
    final extension = p.posix.extension(candidate);
    var suffix = 2;
    while (true) {
      final nextCandidate = dirname == '.'
          ? '${basename}_$suffix$extension'
          : p.posix.join(dirname, '${basename}_$suffix$extension');
      if (_usedRelativePaths.add(nextCandidate)) {
        return nextCandidate;
      }
      suffix += 1;
    }
  }
}
