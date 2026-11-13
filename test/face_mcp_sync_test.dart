import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_mcp_sync_service.dart';
import 'package:ota_counter/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/isolated_test_databases.dart';

/// The local face MCP reads Content-Length.  A chunked Dart POST used to
/// arrive as an empty body, so these tests keep the real HTTP path and assert
/// the server saw the full JSON-RPC payload.
void main() {
  late HttpServer server;
  late Directory tempDir;
  final received = <Map<String, dynamic>>[];

  setUpAll(() async {
    await useIsolatedTestDatabases();
    tempDir = await Directory.systemTemp.createTemp('ota_face_mcp_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      received.add(decoded);
      final tool = ((decoded['params'] as Map?)?['name'] ?? '') as String;
      final payload = tool == 'import_face_samples'
          ? {'ok': true, 'samples': 2, 'members': 2}
          : {'ok': true, 'added': ['photo.jpg'], 'count': 1};
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'jsonrpc': '2.0',
          'id': decoded['id'],
          'result': {
            'content': [
              {'type': 'text', 'text': jsonEncode(payload)},
            ],
            'isError': false,
          },
        }));
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // temp directory; nothing to do
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.saveFaceMcpUrl(
      'http://${server.address.address}:${server.port}',
    );
    await SettingsService.saveFaceMcpToken('test-token');
    received.clear();
    final db = await DatabaseService.database;
    await db.delete(DatabaseService.faceSamplesTableName);
    await db.delete(DatabaseService.activityRecordMediaTableName);
  });

  test('syncSamples posts the full import payload', () async {
    final db = await DatabaseService.database;
    for (final (index, name) in [(0, '盈盈'), (1, '小雪')]) {
      final embedding = Float32List.fromList(
        List<double>.generate(128, (i) => i == index ? 1.0 : 0.0),
      );
      await db.insert(DatabaseService.faceSamplesTableName, {
        'person_id': index + 1,
        'person_name': name,
        'counter_id': index + 10,
        'is_self': 0,
        'media_id': index,
        'face_box_json': '{}',
        'embedding': FaceSampleModel.encodeEmbedding(embedding),
        'model_id': FaceSampleModel.currentModelId,
        'quality': 0.9,
        'source': FaceSampleSource.confirmed.dbValue,
        'created_at': DateTime.utc(2026, 11, 8).toIso8601String(),
      });
    }

    final result = await FaceMcpSyncService.syncSamples();
    expect(result.ok, isTrue);
    expect(result.sent, 2);
    expect(result.members, 2);

    final request = received.single;
    expect(request['method'], 'tools/call');
    final params = request['params'] as Map<String, dynamic>;
    expect(params['name'], 'import_face_samples');
    final payload = (params['arguments'] as Map)['payload'] as Map;
    expect(payload['model_id'], FaceSampleModel.currentModelId);
    expect(payload['samples'], hasLength(2));
  });

  test('syncPhotos uploads scan media as base64', () async {
    final file = File('${tempDir.path}/cheki.jpg');
    await file.writeAsBytes(
      img.encodeJpg(img.Image(width: 8, height: 8)),
    );
    final db = await DatabaseService.database;
    await db.insert(DatabaseService.activityRecordMediaTableName, {
      'record_id': 1,
      'path': file.path,
      'created_at': DateTime.utc(2026, 11, 8).toIso8601String(),
      'media_type': 'scan',
      'processing_mode': 'none',
      'is_reversed': 0,
      'owner_person_name': '',
      'owner_group_name': '',
      'source_hash': '',
      'crop_quad_json': '',
    });

    var progress = 0;
    final result = await FaceMcpSyncService.syncPhotos(
      onProgress: (done, total) => progress = done,
    );
    expect(result.ok, isTrue);
    expect(result.sent, 1);
    expect(progress, 1);

    final request = received.single;
    final params = request['params'] as Map<String, dynamic>;
    expect(params['name'], 'add_photos');
    final photo = ((params['arguments'] as Map)['photos'] as List).single as Map;
    expect(photo['name'], startsWith('cheki_'));
    expect(base64Decode(photo['image_base64'] as String), isNotEmpty);
  });
}
