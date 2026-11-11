import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';
import 'package:ota_counter/services/settings_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final databases = await useIsolatedTestDatabases();
    final documents = Directory('${databases.path}/documents')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );
  });

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
    List<Map<String, Object?>> activityRecords = const [],
    List<Map<String, Object?>> activityRecordMedia = const [],
    List<Map<String, Object?>> images = const [],
    bool hiddenCounter = false,
    Map<String, Object?>? appSettings,
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
            'count': 1,
            'is_hidden': hiddenCounter ? 1 : 0,
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
        DatabaseService.activityRecordTableName: activityRecords,
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
      if (appSettings != null) 'app_settings': appSettings,
    };
  }

  Future<void> restore(Map<String, Object?> manifest) async {
    final payload = ExportImportService.parseImportPayload(
      fileName: 'backup.zip',
      rawBytes: buildFullBackupZip(manifest: manifest),
    );
    await ExportImportService.restoreFullBackup(payload.fullBackup!);
  }

  group('full backup preserves legacy activity metadata', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() async => DatabaseService.clearAppData());

    test('restore, ordinary edits and zip re-export preserve raw metadata',
        () async {
      // Synthetic shape of the failing backup: two linked split group cuts
      // and thirteen opening-balance rows. No private backup content is used.
      final rows = List.generate(
          16,
          (index) => <String, Object?>{
                ...ActivityRecordModel(
                  id: index + 1,
                  type: ActivityRecordType.counter,
                  counterId: 1,
                  subjectName: 'Alice',
                  groupName: 'Team A',
                  occurredAt: DateTime(2026, 3, 18),
                  threeInchCount: index >= 2 ? 1 : 0,
                  groupCutCount: index < 2 ? 1 : 0,
                  totalAmount: 0,
                ).toMap(),
                'group_record_id': index < 2 ? 'legacy-group-001' : null,
                'is_system_adjustment': index >= 2 && index < 15 ? 1 : 0,
              });
      await restore(buildManifest(activityRecords: rows));

      final records = await DatabaseService.getActivityRecords();
      expect(records, hasLength(rows.length));
      // Exercise both ordinary update paths, including the member-detail edit.
      for (final record in records) {
        await DatabaseService.updateActivityRecord(
          record.id!,
          record.copyWith(note: 'edited note'),
        );
        await DatabaseService.updateActivityRecordWithCounterImpact(
          record.id!,
          record.copyWith(note: 'edited note', venueName: 'edited venue'),
        );
      }

      final exported = await ExportImportService.buildFullBackupBundle();
      final payload = ExportImportService.parseImportPayload(
        fileName: 'roundtrip.zip',
        rawBytes: buildFullBackupZip(manifest: exported.toManifest()),
      );
      final actual = payload
          .fullBackup!.mainDatabase[DatabaseService.activityRecordTableName]!;
      expect(actual, hasLength(rows.length));
      final byId = {for (final row in actual) row['id']: row};
      for (final expected in rows) {
        final row = byId[expected['id']]!;
        expect(
            row, containsPair('group_record_id', expected['group_record_id']));
        expect(
            row,
            containsPair(
                'is_system_adjustment', expected['is_system_adjustment']));
        expect(row['note'], 'edited note');
        expect(row['venue_name'], 'edited venue');
        expect(row['three_inch_count'], expected['three_inch_count']);
        expect(row['group_cut_count'], expected['group_cut_count']);
      }
      expect(actual.where((r) => r['group_record_id'] != null), hasLength(2));
      expect(
          actual.where((r) => r['is_system_adjustment'] == 1), hasLength(13));

      await ExportImportService.restoreFullBackup(payload.fullBackup!);
      final restored = await ExportImportService.buildFullBackupBundle();
      final restoredRows =
          restored.mainDatabase[DatabaseService.activityRecordTableName]!;
      expect({for (final row in restoredRows) row['id']: row}, byId);
    });

    test('missing metadata and explicit nulls remain compatible', () async {
      final ordinary = ActivityRecordModel(
        id: 1,
        type: ActivityRecordType.counter,
        counterId: 1,
        subjectName: 'Alice',
        groupName: 'Team A',
        occurredAt: DateTime(2026, 3, 18),
        threeInchCount: 1,
        totalAmount: 0,
      );
      await restore(buildManifest(activityRecords: [
        ordinary.toMap(),
        {
          ...ordinary.copyWith(id: 2).toMap(),
          'group_record_id': null,
          'is_system_adjustment': null,
        },
      ]));
      final insertedId = await DatabaseService.insertActivityRecord(ordinary);
      final records = await DatabaseService.getActivityRecords();
      expect(records, hasLength(3));
      expect(records.every((r) => r.threeInchCount == 1), isTrue);
      final exported = await ExportImportService.buildFullBackupBundle();
      final byId = {
        for (final row
            in exported.mainDatabase[DatabaseService.activityRecordTableName]!)
          row['id']: row
      };
      expect(byId[1], containsPair('group_record_id', null));
      expect(byId[1], containsPair('is_system_adjustment', 0));
      expect(byId[2], containsPair('is_system_adjustment', null));
      expect(byId[insertedId], containsPair('group_record_id', null));
      expect(byId[insertedId], containsPair('is_system_adjustment', 0));
    });
  });

  group('full backup restores the home hidden-member scope', () {
    tearDown(() async => DatabaseService.clearAppData());

    test('older backup with hidden members shows them after restore', () async {
      SharedPreferences.setMockInitialValues({});
      await restore(buildManifest(hiddenCounter: true));
      expect(await SettingsService.getShowHiddenCounters(), isTrue);
      final counter = (await DatabaseService.getCounters()).single;
      expect(counter.isHidden, isTrue);
      expect(counter.count, 1);
    });

    test('older backup without hidden members leaves the switch alone',
        () async {
      SharedPreferences.setMockInitialValues({});
      await restore(buildManifest());
      expect(await SettingsService.getShowHiddenCounters(), isFalse);
    });

    test('backed-up switch wins over the hidden-member fallback', () async {
      SharedPreferences.setMockInitialValues({'show_hidden_counters': true});
      await restore(buildManifest(
        hiddenCounter: true,
        appSettings: {FullBackupBundle.showHiddenCountersSetting: false},
      ));
      expect(await SettingsService.getShowHiddenCounters(), isFalse);
    });

    test('manifest round-trips the app settings', () {
      final bundle = FullBackupBundle.fromManifest(
        manifest: buildManifest(
          appSettings: {FullBackupBundle.showHiddenCountersSetting: true},
        ),
        documentFiles: const {},
      );
      expect(
        bundle.toManifest()['app_settings'],
        {FullBackupBundle.showHiddenCountersSetting: true},
      );
    });
  });

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
