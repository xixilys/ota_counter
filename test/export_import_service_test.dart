import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';

void main() {
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
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
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
            },
            'idol_database': {
              'idol_people': const [],
              'idol_groups': const [],
              'idol_members': const [],
              'idol_meta': const [],
            },
            'image_database': {
              'images': const [],
            },
          }),
        ),
      )
      ..addFile(
        ArchiveFile(
          'documents/activity_record_media/example.jpg',
          3,
          [1, 2, 3],
        ),
      );

    final payload = ExportImportService.parseImportPayload(
      fileName: 'backup.zip',
      rawBytes: ZipEncoder().encode(archive),
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
}
