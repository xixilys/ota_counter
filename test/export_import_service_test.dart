import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';

void main() {
  List<int> buildFullBackupZip({
    required Map<String, Object?> manifest,
    Map<String, List<int>> documentFiles = const {},
  }) {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string('manifest.json', jsonEncode(manifest)),
      );

    for (final entry in documentFiles.entries) {
      archive.addFile(
        ArchiveFile(
          'documents/${entry.key}',
          entry.value.length,
          entry.value,
        ),
      );
    }

    return ZipEncoder().encode(archive);
  }

  Map<String, Object?> buildManifest({
    List<Map<String, Object?>> activityRecordMedia = const [],
    List<Map<String, Object?>> images = const [],
  }) {
    return {
      'type': FullBackupBundle.backupType,
      'format_version': FullBackupBundle.currentFormatVersion,
      'exported_at': '2026-03-18T10:00:00.000',
      'main_database': {
        DatabaseService.tableName: [
          {
            'id': 1,
            'name': 'Alice',
            'group_name': 'Team A',
            'color': '#ffffff',
            'is_hidden': 0,
            'three_inch_count': 1,
            'five_inch_count': 0,
            'unsigned_three_inch_count': 0,
            'unsigned_five_inch_count': 0,
            'group_cut_count': 0,
            'three_inch_shukudai_count': 0,
            'five_inch_shukudai_count': 0,
            'name_pinyin': 'alice',
            'person_id': null,
            'person_name': '',
          },
        ],
        DatabaseService.activityRecordMediaTableName: activityRecordMedia,
      },
      'idol_database': {
        'idol_people': const [],
        'idol_groups': const [],
        'idol_members': const [],
        'idol_meta': const [],
      },
      'image_database': {
        'images': images,
      },
    };
  }

  test('legacy counter export remains importable', () {
    final counter = CounterModel(
      id: 1,
      name: '测试成员',
      groupName: '测试团',
      color: '#123456',
      threeInchCount: 2,
      fiveInchCount: 1,
    );

    final payload = ExportImportService.parseImportPayload(
      fileName: 'counters.txt',
      rawBytes: utf8.encode(
        jsonEncode([counter.toMap()]),
      ),
    );

    expect(payload.isLegacyCounters, isTrue);
    expect(payload.counters, hasLength(1));
    expect(payload.counters.single.name, '测试成员');
    expect(payload.counters.single.groupName, '测试团');
  });

  test('ota bundle export remains importable', () {
    final payload = ExportImportService.parseImportPayload(
      fileName: 'ota_bundle.json',
      rawBytes: utf8.encode(
        jsonEncode({
          'records': const [],
          'groups': const [],
          'idols': const [],
        }),
      ),
    );

    expect(payload.isOtaBundle, isTrue);
    expect(payload.rawJson, contains('"records"'));
  });

  test('full backup zip can be parsed', () {
    final payload = ExportImportService.parseImportPayload(
      fileName: 'backup.zip',
      rawBytes: buildFullBackupZip(
        manifest: buildManifest(),
        documentFiles: {
          'activity_record_media/example.jpg': [1, 2, 3],
        },
      ),
    );

    expect(payload.isFullBackup, isTrue);
    expect(payload.fullBackup, isNotNull);
    expect(
      payload
          .fullBackup?.mainDatabase[DatabaseService.tableName]?.single['name'],
      'Alice',
    );
    expect(
      payload.fullBackup?.documentFiles['activity_record_media/example.jpg'],
      [1, 2, 3],
    );
  });

  test('full backup zip can be parsed from a file without loading bytes',
      () async {
    final zipBytes = buildFullBackupZip(
      manifest: buildManifest(),
      documentFiles: {
        'activity_record_media/example.jpg': [1, 2, 3, 4],
      },
    );
    final tempDir = await Directory.systemTemp.createTemp('ota_backup_test');
    final backupFile = File('${tempDir.path}/backup.zip');
    await backupFile.writeAsBytes(zipBytes, flush: true);
    ImportPayload? payload;

    try {
      payload = await ExportImportService.parseImportPayloadFile(
        fileName: 'backup.zip',
        path: backupFile.path,
      );

      expect(payload.isFullBackup, isTrue);
      expect(
        payload.fullBackup?.documentEntries.keys,
        contains('activity_record_media/example.jpg'),
      );
      expect(payload.fullBackup?.documentFiles, isEmpty);
      expect(payload.fullBackup?.documentSource, isNotNull);
    } finally {
      await payload?.fullBackup?.documentSource?.close();
      await backupFile.delete();
      await tempDir.delete(recursive: true);
    }
  });

  test('file backed archive entries survive a streaming zip round trip',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('ota_zip_stream');
    final source = File('${tempDir.path}/photo.bin');
    final bytes = List<int>.generate(64 * 1024, (index) => index % 251);
    await source.writeAsBytes(bytes, flush: true);

    try {
      final archive = Archive()
        ..addFile(
          ArchiveFile.file(
            'documents/photo.bin',
            bytes.length,
            FileContentStream(InputFileStream(source.path)),
          )..compression = CompressionType.none,
        );
      final zipFile = File('${tempDir.path}/out.zip');
      final output = OutputFileStream(zipFile.path);
      try {
        ZipEncoder().encodeStream(archive, output, autoClose: true);
      } finally {
        await output.close();
      }

      final decoded = ZipDecoder().decodeBytes(
        await zipFile.readAsBytes(),
      );
      expect(
        decoded.findFile('documents/photo.bin')!.readBytes(),
        bytes,
      );
    } finally {
      await tempDir.delete(recursive: true);
    }
  });

  test('full backup rejects parent traversal zip entry', () {
    expect(
      () => ExportImportService.parseImportPayload(
        fileName: 'backup.zip',
        rawBytes: buildFullBackupZip(
          manifest: buildManifest(),
          documentFiles: {
            '../outside.txt': [1, 2, 3],
          },
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('父级目录'),
        ),
      ),
    );
  });

  test('full backup rejects absolute zip entry path', () {
    expect(
      () => ExportImportService.parseImportPayload(
        fileName: 'backup.zip',
        rawBytes: buildFullBackupZip(
          manifest: buildManifest(),
          documentFiles: {
            '/absolute.txt': [1, 2, 3],
          },
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('绝对路径'),
        ),
      ),
    );
  });

  test('full backup rejects parent traversal in manifest document path', () {
    expect(
      () => ExportImportService.parseImportPayload(
        fileName: 'backup.zip',
        rawBytes: buildFullBackupZip(
          manifest: buildManifest(
            activityRecordMedia: [
              {
                'id': 1,
                'activity_record_id': 1,
                'path': '../outside.txt',
                'type': 'image',
              },
            ],
          ),
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('父级目录'),
        ),
      ),
    );
  });

  test('full backup accepts normalized nested document path', () {
    final payload = ExportImportService.parseImportPayload(
      fileName: 'backup.zip',
      rawBytes: buildFullBackupZip(
        manifest: buildManifest(
          activityRecordMedia: [
            {
              'id': 1,
              'activity_record_id': 1,
              'path': 'activity_record_media/session/photo.jpg',
              'type': 'image',
            },
          ],
        ),
        documentFiles: {
          'activity_record_media/session/photo.jpg': [7, 8, 9],
        },
      ),
    );

    expect(payload.isFullBackup, isTrue);
    expect(
      payload.fullBackup?.documentFiles.keys,
      contains('activity_record_media/session/photo.jpg'),
    );
    expect(
      payload
          .fullBackup
          ?.mainDatabase[DatabaseService.activityRecordMediaTableName]
          ?.single['path'],
      'activity_record_media/session/photo.jpg',
    );
  });
}
