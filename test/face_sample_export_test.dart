import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_sample_export_service.dart';

import 'support/isolated_test_databases.dart';

/// 导出的人脸样本：结构、条数、每条 128 维，且不含照片字节。
void main() {
  late Directory exportDir;

  setUpAll(() async {
    await useIsolatedTestDatabases();
    exportDir = await Directory.systemTemp.createTemp('ota_face_export_');
  });

  tearDownAll(() async {
    try {
      await exportDir.delete(recursive: true);
    } on FileSystemException {
      // 临时目录，删不掉也不影响其它测试。
    }
  });

  test('exports 128-dim embeddings with member identity', () async {
    final db = await DatabaseService.database;
    await db.delete(DatabaseService.faceSamplesTableName);

    final first = Float32List.fromList(
      List<double>.generate(128, (i) => (i == 0 ? 1.0 : 0.0)),
    );
    final second = Float32List.fromList(
      List<double>.generate(128, (i) => (i == 1 ? 1.0 : 0.0)),
    );

    for (final row in [
      {
        'person_id': 7,
        'person_name': '盈盈',
        'counter_id': 25,
        'is_self': 0,
        'media_id': 11,
        'face_box_json': '{"x":1,"y":2,"width":3,"height":4,"score":0.9}',
        'embedding': FaceSampleModel.encodeEmbedding(first),
        'model_id': FaceSampleModel.currentModelId,
        'quality': 0.91,
        'source': FaceSampleSource.confirmed.dbValue,
        'created_at': DateTime.utc(2026, 11, 8).toIso8601String(),
      },
      {
        'person_id': 9,
        'person_name': '小雪',
        'counter_id': 26,
        'is_self': 0,
        'media_id': 12,
        'face_box_json': '{}',
        'embedding': FaceSampleModel.encodeEmbedding(second),
        'model_id': FaceSampleModel.currentModelId,
        'quality': 0.88,
        'source': FaceSampleSource.manual.dbValue,
        'created_at': DateTime.utc(2026, 11, 9).toIso8601String(),
      },
    ]) {
      await db.insert(DatabaseService.faceSamplesTableName, row);
    }

    final result = await FaceSampleExportService.exportToJson(
      directory: exportDir,
    );

    expect(result.count, 2);
    expect(result.skipped, 0);
    expect(File(result.path).existsSync(), isTrue);

    final json =
        jsonDecode(File(result.path).readAsStringSync()) as Map<String, dynamic>;
    expect(json['model_id'], FaceSampleModel.currentModelId);
    expect(json['exported_at'], isA<String>());

    final samples = (json['samples'] as List).cast<Map<String, dynamic>>();
    expect(samples, hasLength(2));
    expect(samples.map((s) => s['name']), containsAll(['盈盈', '小雪']));
    for (final sample in samples) {
      final embedding = (sample['embedding'] as List).cast<num>();
      expect(embedding, hasLength(128));
      expect(sample['model_id'], FaceSampleModel.currentModelId);
      expect(sample['is_self'], isFalse);
      expect(sample['member_id'], isNotNull);
    }
    // 不含照片：只有向量和身份字段。
    expect(File(result.path).lengthSync(), lessThan(200 * 1024));
  });
}
