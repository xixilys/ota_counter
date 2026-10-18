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

  /// Document bytes for in-memory backups (small tests / legacy paths).
  final Map<String, List<int>> documentFiles;

  /// Zip entries kept compressed in memory, used by file based imports so a
  /// 200 MB photo backup is not decompressed in one go.
  final Map<String, ArchiveFile> documentEntries;

  /// Source paths for export; archive relative path -> absolute file path.
  /// Keeping paths instead of bytes avoids loading the whole photo library.
  final Map<String, String> documentPaths;

  /// Open file stream backing [documentEntries] for file based imports.
  /// It must stay open until the documents have been restored.
  final InputFileStream? documentSource;

  const FullBackupBundle({
    required this.formatVersion,
    required this.exportedAt,
    required this.mainDatabase,
    required this.idolDatabase,
    required this.imageDatabase,
    required this.documentFiles,
    this.documentEntries = const {},
    this.documentPaths = const {},
    this.documentSource,
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
    Map<String, ArchiveFile> documentEntries = const {},
    InputFileStream? documentSource,
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

    _validateDocumentPathRows(
      _readTableDump(manifest['main_database']),
      table: DatabaseService.activityRecordMediaTableName,
      pathColumn: 'path',
    );
    _validateDocumentPathRows(
      _readTableDump(manifest['image_database']),
      table: ImageService.tableName,
      pathColumn: 'path',
    );

    return FullBackupBundle(
      formatVersion: formatVersion,
      exportedAt: (manifest['exported_at'] ?? '') as String,
      mainDatabase: _readTableDump(manifest['main_database']),
      idolDatabase: _readTableDump(manifest['idol_database']),
      imageDatabase: _readTableDump(manifest['image_database']),
      documentFiles: documentFiles,
      documentEntries: documentEntries,
      documentSource: documentSource,
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

  static void _validateDocumentPathRows(
    Map<String, List<Map<String, Object?>>> tables, {
    required String table,
    required String pathColumn,
  }) {
    final rows = tables[table] ?? const [];
    for (final row in rows) {
      final rawPath = (row[pathColumn] ?? '').toString().trim();
      if (rawPath.isEmpty) {
        continue;
      }
      ExportImportService.normalizeBackupRelativePath(rawPath);
    }
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

    // Stream each photo from disk instead of keeping the whole library in
    // memory. Photos are already compressed, so storing them is both faster
    // and much lighter than deflating ~200 MB of JPEG data.
    for (final entry in backup.documentPaths.entries) {
      final sourceFile = File(entry.value);
      if (!await sourceFile.exists()) {
        continue;
      }
      final length = await sourceFile.length();
      archive.addFile(
        ArchiveFile.file(
          _archiveDocumentPath(entry.key),
          length,
          FileContentStream(InputFileStream(sourceFile.path)),
        )..compression = CompressionType.none,
      );
    }

    final tempDir = await getTemporaryDirectory();
    final fileName = 'ota_counter_backup_${_timestampForFileName()}.zip';
    final tempFile = File(p.join(tempDir.path, fileName));
    final output = OutputFileStream(tempFile.path);
    try {
      ZipEncoder().encodeStream(archive, output, autoClose: true);
    } finally {
      await output.close();
    }

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
      withData: false,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final file = result.files.first;
    final path = file.path;
    if (path != null && path.isNotEmpty) {
      return parseImportPayloadFile(
        fileName: file.name,
        path: path,
      );
    }

    final rawBytes = file.bytes ?? const <int>[];
    return parseImportPayload(
      fileName: file.name,
      rawBytes: rawBytes,
    );
  }

  static Future<ImportPayload> parseImportPayloadFile({
    required String fileName,
    required String path,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('导入文件不存在');
    }

    final headerHandle = await file.open();
    List<int> header;
    try {
      header = await headerHandle.read(4);
    } finally {
      await headerHandle.close();
    }

    if (_looksLikeZip(header)) {
      final fullBackup = await _parseFullBackupFile(path);
      return ImportPayload(
        kind: ImportPayloadKind.fullBackup,
        fileName: fileName,
        rawJson: '',
        fullBackup: fullBackup,
      );
    }

    return parseImportPayload(
      fileName: fileName,
      rawBytes: await file.readAsBytes(),
    );
  }

  /// Releases the lazily opened backup file when the user cancels an import.
  static Future<void> disposeImportPayload(ImportPayload payload) async {
    await payload.fullBackup?.documentSource?.close();
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
    try {
      await DatabaseService.clearAppData();
      await _clearImageLibrary();
      await _clearIdolDatabase();
      await _clearManagedImportDirectories(documentsDirectory.path);
      if (backup.documentEntries.isNotEmpty) {
        await _restoreDocumentEntries(
          backup.documentEntries,
          documentsDirectory.path,
        );
      } else {
        await _restoreDocumentFiles(
          backup.documentFiles,
          documentsDirectory.path,
        );
      }
    } finally {
      await backup.documentSource?.close();
    }
    await _restoreMainDatabase(
      backup.mainDatabase,
      documentsDirectory.path,
    );
    await _restoreIdolDatabase(backup.idolDatabase);
    await _restoreImageDatabase(
      backup.imageDatabase,
      documentsDirectory.path,
    );
    // The restored idol database may use different person ids than the
    // restored counters / records. Repair before the home page reads them.
    await DatabaseService.reconcileCounterIdentities();
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

    final documentPaths = <String, String>{
      ...activityRecordMedia.documentPaths,
      ...images.documentPaths,
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
      documentFiles: const {},
      documentPaths: documentPaths,
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
    final documentPaths = <String, String>{};

    for (final row in rows) {
      final nextRow = Map<String, Object?>.from(row);
      final rawPath = (row[pathColumn] ?? '').toString().trim();
      if (rawPath.isNotEmpty) {
        final relativePath = pathMapper.relativePathFor(rawPath);
        if (relativePath != null) {
          nextRow[pathColumn] = relativePath;
          if (!documentPaths.containsKey(relativePath) &&
              await File(rawPath).exists()) {
            documentPaths[relativePath] = rawPath;
          }
        }
      }
      normalizedRows.add(nextRow);
    }

    return _NormalizedDocumentRows(
      rows: normalizedRows,
      documentPaths: documentPaths,
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
    if (columns.isEmpty || rows.isEmpty) {
      return;
    }

    final batch = db.batch();
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
      batch.insert(table, filtered);
    }
    await batch.commit(noResult: true);
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
        nextRow[pathColumn] = _resolveDocumentRestorePath(
          documentsPath: documentsPath,
          relativePath: relativePath,
        );
      }
      return nextRow;
    }).toList(growable: false);
  }

  static Future<void> _restoreDocumentEntries(
    Map<String, ArchiveFile> documentEntries,
    String documentsPath,
  ) async {
    for (final entry in documentEntries.entries) {
      final targetPath = _resolveDocumentRestorePath(
        documentsPath: documentsPath,
        relativePath: entry.key,
      );
      final targetFile = File(targetPath);
      await targetFile.parent.create(recursive: true);
      final output = OutputFileStream(targetPath);
      try {
        entry.value.writeContent(output);
      } finally {
        await output.close();
        // Drop the zip view so the compressed read buffer can be released.
        entry.value.clear();
      }
      // writeContent is synchronous; yield so the restore spinner can paint.
      await Future<void>.delayed(Duration.zero);
    }
  }

  static Future<void> _restoreDocumentFiles(
    Map<String, List<int>> documentFiles,
    String documentsPath,
  ) async {
    for (final entry in documentFiles.entries) {
      final targetPath = _resolveDocumentRestorePath(
        documentsPath: documentsPath,
        relativePath: entry.key,
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

  static Future<FullBackupBundle> _parseFullBackupFile(String path) async {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final manifestFile = archive.findFile(_manifestArchivePath);
      if (manifestFile == null) {
        throw const FormatException('未找到完整备份清单');
      }

      final manifestJson = utf8.decode(_archiveFileBytes(manifestFile));
      final decoded = jsonDecode(manifestJson);
      if (decoded is! Map) {
        throw const FormatException('完整备份清单格式错误');
      }

      // Keep zip views instead of decompressing every photo up front. The
      // input stream stays open in the bundle and is closed after restore.
      final documentEntries = <String, ArchiveFile>{};
      for (final file in archive.files) {
        if (!file.isFile || !file.name.startsWith('$_documentsArchiveRoot/')) {
          continue;
        }
        final relativePath = normalizeBackupRelativePath(
          file.name.substring(_documentsArchiveRoot.length + 1),
        );
        documentEntries[relativePath] = file;
      }

      return FullBackupBundle.fromManifest(
        manifest: decoded.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
        documentFiles: const {},
        documentEntries: documentEntries,
        documentSource: input,
      );
    } catch (_) {
      await input.close();
      rethrow;
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
      final relativePath = normalizeBackupRelativePath(
        file.name.substring(_documentsArchiveRoot.length + 1),
      );
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
      normalizeBackupRelativePath(relativePath),
    );
  }

  static String normalizeBackupRelativePath(String rawPath) {
    final trimmedPath = rawPath.trim();
    if (trimmedPath.isEmpty) {
      throw const FormatException('备份中的文件路径不能为空');
    }

    final normalizedPath = p.posix.normalize(trimmedPath);
    if (normalizedPath.isEmpty || normalizedPath == '.') {
      throw const FormatException('备份中的文件路径不能为空');
    }
    if (p.posix.isAbsolute(normalizedPath)) {
      throw const FormatException('备份中的文件路径不能是绝对路径');
    }

    for (final segment in p.posix.split(normalizedPath)) {
      if (segment == '..') {
        throw const FormatException('备份中的文件路径不能包含父级目录');
      }
    }

    return p.posix.joinAll(p.posix.split(normalizedPath));
  }

  static String _resolveDocumentRestorePath({
    required String documentsPath,
    required String relativePath,
  }) {
    final normalizedDocumentsPath = p.normalize(documentsPath);
    final normalizedRelativePath = normalizeBackupRelativePath(relativePath);
    final targetPath = p.normalize(
      p.join(
        normalizedDocumentsPath,
        p.joinAll(p.posix.split(normalizedRelativePath)),
      ),
    );

    if (targetPath != normalizedDocumentsPath &&
        !p.isWithin(normalizedDocumentsPath, targetPath)) {
      throw const FormatException('备份中的文件路径超出应用文档目录');
    }

    return targetPath;
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
  final Map<String, String> documentPaths;

  const _NormalizedDocumentRows({
    required this.rows,
    required this.documentPaths,
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
