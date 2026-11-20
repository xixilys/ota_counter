// ignore_for_file: avoid_relative_lib_imports
// End-to-end: MCP delete_cheki_photo / replace_cheki_photo / edit_record →
// app pull → 切册 or ledger changed → applied / failed receipt.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/services/cheki_photo_sync_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/sync_service.dart';

import '../mcp_server/lib/http_transport.dart';
import '../mcp_server/lib/mcp_protocol.dart';
import '../mcp_server/lib/store.dart';

import 'support/isolated_test_databases.dart';

Uint8List _jpeg(int shade) {
  final picture = image.Image(width: 54, height: 86);
  image.fill(picture, color: image.ColorRgb8(shade, 40, 60));
  return Uint8List.fromList(image.encodeJpg(picture));
}

FaceAnalysis _face(List<double> embedding) => FaceAnalysis(
      face: const FaceDetection(
          x: 0, y: 0, width: 100, height: 100, landmarks: [], score: 0.9),
      embedding: Float32List.fromList(embedding),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final analyzer = FaceSampleService.analyzer;
  final orient = ChekiPhotoSyncService.orient;
  var detected = <FaceAnalysis>[];
  late Directory dataDir;
  late Directory documents;
  late SyncStore store;
  late SyncHttpServer server;
  late SyncSettings settings;
  late McpProtocol protocol;

  setUpAll(() async {
    final databases = await useIsolatedTestDatabases();
    documents = Directory('${databases.path}/documents')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => documents.path);
  });

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'top.huangxuanqi.otacounter',
      version: '1.7.13',
      buildNumber: '42',
      buildSignature: '',
    );
    await DatabaseService.clearAppData();
    await FaceSampleService.clearAll();
    detected = [];
    FaceSampleService.analyzer = (_) async => detected;
    ChekiPhotoSyncService.orient = (bytes) async => bytes;
    dataDir = await Directory.systemTemp.createTemp('ota_cheki_edit_app');
    store = SyncStore(dataDir.path);
    protocol = McpProtocol(store);
    server = SyncHttpServer(
        store: store, token: 'test-token', host: '127.0.0.1', port: 0);
    await server.start();
    settings = SyncSettings(
      baseUrl: 'http://127.0.0.1:${server.actualPort}',
      token: 'test-token',
      deviceId: 'test-device',
      autoSync: false,
      lastSyncAt: '',
    );
  });

  tearDown(() async {
    FaceSampleService.analyzer = analyzer;
    ChekiPhotoSyncService.orient = orient;
    await server.close();
    await DatabaseService.clearAppData();
    if (await dataDir.exists()) await dataDir.delete(recursive: true);
  });

  Future<Map<String, dynamic>> tool(
      String name, Map<String, dynamic> arguments) async {
    final response = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }) as Map;
    final result = response['result'] as Map;
    expect(result['isError'], isNot(true),
        reason: (result['content'] as List).first.toString());
    return Map<String, dynamic>.from(result['structuredContent'] as Map);
  }

  Future<Map<String, dynamic>> editStatus(String actionId) async {
    final list = await tool('list_cheki_edits', {});
    return Map<String, dynamic>.from((list['edits'] as List)
        .cast<Map>()
        .singleWhere((item) => item['id'] == actionId));
  }

  Future<CounterModel> counterNamed(String name) async =>
      (await DatabaseService.getCounters()).singleWhere((c) => c.name == name);

  Future<CounterModel> addCounter(String name) async {
    await DatabaseService.insertCounter(
        CounterModel(name: name, groupName: 'ReCream', color: '#FF7A9E'));
    return counterNamed(name);
  }

  Future<int> addRecord(CounterModel counter, {int threeInch = 2}) =>
      DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: counter,
          occurredAt: DateTime(2026, 11, 19),
          deltas: {CounterCountField.threeInch: threeInch},
          pricing: GroupPricingModel.unconfigured(counter.groupName),
          activityName: '生诞祭',
        ),
      );

  /// Attaches three photos through MCP and returns their media ids in 切册
  /// order, as the snapshot lists them.
  Future<List<int>> attachThree(int recordId) async {
    await SyncService.pushSnapshot(settings);
    final queued = await tool('attach_cheki_photos', {
      'record_id': recordId,
      'images': [
        for (final shade in [10, 20, 30]) base64Encode(_jpeg(shade))
      ],
    });
    expect((await SyncService.syncNow(settings)).failures, isEmpty);
    final attached = await tool('list_cheki_photos', {});
    final receipt = (attached['attachments'] as List)
        .cast<Map>()
        .singleWhere((a) => a['id'] == queued['action_id']);
    expect((receipt['media_ids'] as List), hasLength(3),
        reason: '回执带新照片编号');
    final listed = await tool('list_record_photos', {'record_id': recordId});
    final photos = (listed['photos'] as List).cast<Map>();
    expect([for (final p in photos) p['position']], [1, 2, 3]);
    expect((receipt['media_ids'] as List).toSet(),
        {for (final p in photos) p['media_id']});
    final sentHashes = {
      for (final shade in [10, 20, 30]) sha1.convert(_jpeg(shade)).toString()
    };
    expect({for (final p in photos) p['sha1']}, sentHashes,
        reason: 'sha1 就是当时发送的图片字节的 SHA-1');
    return [for (final p in photos) p['media_id'] as int];
  }

  test('delete_cheki_photo removes exactly that photo and its file', () async {
    final counter = await addCounter('兔兔Miottie');
    final recordId = await addRecord(counter);
    final ids = await attachThree(recordId);
    final victim = (await DatabaseService.getActivityRecordMedia())
        .singleWhere((m) => m.id == ids[1]);

    final queued = await tool('delete_cheki_photo', {'media_id': ids[1]});
    final result = await SyncService.syncNow(settings);
    expect(result.failures, isEmpty);

    final left = await DatabaseService.getActivityRecordMedia();
    expect([for (final m in left) m.id], [ids[0], ids[2]]);
    expect(await File(victim.path).exists(), isFalse);
    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'applied');
    expect((status['result'] as Map)['deleted'], isTrue);
    final relisted = await tool('list_record_photos', {'record_id': recordId});
    expect([for (final p in relisted['photos'] as List) (p as Map)['position']],
        [1, 2]);
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 2,
        reason: '删图不改计数');
  });

  test('a photo changed on the phone after the snapshot is not deleted',
      () async {
    final counter = await addCounter('兔兔Miottie');
    final recordId = await addRecord(counter);
    final ids = await attachThree(recordId);
    final queued = await tool('delete_cheki_photo', {'media_id': ids[0]});
    // Replaced on the phone before the action arrives.
    await DatabaseService.replaceActivityRecordMedia(ids[0],
        bytes: _jpeg(99), fileExtension: 'jpg', sourceHash: 'phone-side');

    final result = await SyncService.syncNow(settings);
    expect(result.failures, hasLength(1));
    expect(await DatabaseService.getActivityRecordMedia(), hasLength(3));
    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'failed');
    expect(status['failure'], contains('已被换过'));
  });

  test('replace_cheki_photo swaps the image in place and relearns the face',
      () async {
    final counter = await addCounter('兔兔Miottie');
    final recordId = await addRecord(counter);
    detected = [_face(const [1, 0, 0])];
    final ids = await attachThree(recordId);
    Future<List<FaceSampleModel>> attached() async =>
        (await FaceSampleService.getSamples(isSelf: false))
            .where((s) => s.source == FaceSampleSource.attached)
            .toList();
    expect(await attached(), hasLength(3));
    final before = (await DatabaseService.getActivityRecordMedia())
        .singleWhere((m) => m.id == ids[1]);

    detected = [_face(const [0, 1, 0])];
    final fresh = _jpeg(200);
    final queued = await tool('replace_cheki_photo',
        {'media_id': ids[1], 'image_base64': base64Encode(fresh)});
    final result = await SyncService.syncNow(settings);
    expect(result.failures, isEmpty);

    final media = await DatabaseService.getActivityRecordMedia();
    expect([for (final m in media) m.id], ids, reason: '顺序不变');
    final after = media.singleWhere((m) => m.id == ids[1]);
    expect(after.recordId, recordId);
    expect(after.ownerPersonName, before.ownerPersonName);
    expect(after.sourceHash, sha1.convert(fresh).toString());
    expect(await File(after.path).readAsBytes(), fresh);
    expect(await File(before.path).exists(), isFalse);

    final samples = await attached();
    expect(samples, hasLength(3));
    final forReplaced = samples.where((s) => s.mediaId == ids[1]).toList();
    expect(forReplaced, hasLength(1));
    expect(forReplaced.single.embedding[1], closeTo(1, 1e-6),
        reason: '旧图学到的人脸撤掉，从新图重学');

    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'applied');
    expect((status['result'] as Map)['replaced'], isTrue);
    expect(await store.faceImages.directory.list().where((e) => e is File && !e.path.endsWith('.json')).length, 0,
        reason: '回执后删除服务端暂存图');
  });

  test('edit_record changes counts with the counter, notes and activity',
      () async {
    final counter = await addCounter('兔兔Miottie');
    final recordId = await addRecord(counter);
    await SyncService.pushSnapshot(settings);

    final queued = await tool('edit_record', {
      'record_id': recordId,
      'three_inch': 3,
      'unsigned_five_inch': 1,
      'note': '补签',
      'venue_name': 'Livehouse',
    });
    expect(queued['before'], {
      'three_inch_count': 2,
      'unsigned_five_inch_count': 0,
      'note': '',
      'venue_name': '',
    });
    final pulled = await SyncService.pullActions(settings);
    final result = await SyncService.applyActions(settings, pulled);
    expect(result.failures, isEmpty);

    final record = (await DatabaseService.getActivityRecords())
        .singleWhere((r) => r.id == recordId);
    expect(record.threeInchCount, 3);
    expect(record.unsignedFiveInchCount, 1);
    expect(record.note, '补签');
    expect(record.venueName, 'Livehouse');
    expect(record.activityName, '生诞祭');
    final updated = await counterNamed('兔兔Miottie');
    expect(updated.threeInchCount, 3, reason: '改张数同步调整成员累计');
    expect(updated.unsignedFiveInchCount, 1);

    // A lost receipt replays the same action: nothing changes twice.
    final again = await SyncService.applyActions(settings, pulled);
    expect(again.failures, isEmpty);
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 3);

    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'applied');
    expect((status['result'] as Map)['before'],
        containsPair('three_inch_count', 2));
  });

  test('edit_record does not overwrite a value changed on the phone',
      () async {
    final counter = await addCounter('兔兔Miottie');
    final recordId = await addRecord(counter);
    await SyncService.pushSnapshot(settings);
    final queued =
        await tool('edit_record', {'record_id': recordId, 'three_inch': 4});
    // Edited by hand on the phone after the snapshot.
    final current = (await DatabaseService.getActivityRecords())
        .singleWhere((r) => r.id == recordId);
    await DatabaseService.updateActivityRecordWithCounterImpact(
        recordId,
        ActivityRecordModel.fromMap(
            {...current.toMap(), 'three_inch_count': 5}));

    final result = await SyncService.syncNow(settings);
    expect(result.failures, hasLength(1));
    final record = (await DatabaseService.getActivityRecords())
        .singleWhere((r) => r.id == recordId);
    expect(record.threeInchCount, 5);
    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'failed');
    expect(status['failure'], allOf(contains('已改过'), contains('5')));
  });

  test('the snapshot lists photos in 切册 order with their record', () async {
    final counter = await addCounter('兔兔Miottie');
    final recordId = await addRecord(counter);
    final snapshot = await SyncService.buildSnapshot(settings);
    expect(snapshot['photos'], isEmpty);
    await attachThree(recordId);
    final photos =
        ((await SyncService.buildSnapshot(settings))['photos'] as List)
            .cast<Map>();
    expect(photos.every((p) => p['record_id'] == recordId), isTrue);
    expect([for (final p in photos) p['position']], [1, 2, 3]);
  });
}
