// ignore_for_file: avoid_relative_lib_imports
// End-to-end: MCP attach_cheki_photos / record_cheki images → app pull →
// photo archived on the record (切册) → applied / failed receipt.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
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

String _jpegBase64(int shade) {
  final picture = image.Image(width: 54, height: 86);
  image.fill(picture, color: image.ColorRgb8(shade, 40, 60));
  return base64Encode(image.encodeJpg(picture));
}

FaceAnalysis _face(List<double> embedding) => FaceAnalysis(
      face: const FaceDetection(
          x: 0, y: 0, width: 100, height: 100, landmarks: [], score: 0.9),
      embedding: Float32List.fromList(embedding),
    );

/// A face whose cosine similarity to [_self] is [similarity].
FaceAnalysis _nearSelf(double similarity) => _face(
    [0, math.sqrt(1 - similarity * similarity), similarity]);

const _self = [0.0, 0.0, 1.0];
const _member = [1.0, 0.0, 0.0];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final analyzer = FaceSampleService.analyzer;
  final orient = ChekiPhotoSyncService.orient;
  // Faces "seen" on the next attached photo.
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
      version: '1.7.11',
      buildNumber: '40',
      buildSignature: '',
    );
    await DatabaseService.clearAppData();
    await FaceSampleService.clearAll();
    detected = [];
    FaceSampleService.analyzer = (_) async => detected;
    ChekiPhotoSyncService.orient = (bytes) async => bytes;
    dataDir = await Directory.systemTemp.createTemp('ota_cheki_photo_app');
    store = SyncStore(dataDir.path);
    protocol = McpProtocol(store);
    server = SyncHttpServer(
      store: store,
      token: 'test-token',
      host: '127.0.0.1',
      port: 0,
    );
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

  Future<Map<String, dynamic>> callTool(
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

  Future<Map<String, dynamic>> photoStatus(String actionId) async {
    final list = await callTool('list_cheki_photos', {});
    return Map<String, dynamic>.from((list['attachments'] as List)
        .cast<Map>()
        .singleWhere((item) => item['id'] == actionId));
  }

  Future<int> stagedImages() async {
    final directory = store.faceImages.directory;
    if (!await directory.exists()) return 0;
    return directory
        .list()
        .where((entry) => entry is File && !entry.path.endsWith('.json'))
        .length;
  }

  Future<int> addRecord(CounterModel counter, DateTime day,
      {String activityName = ''}) {
    return DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: day,
        deltas: const {CounterCountField.threeInch: 1},
        pricing: GroupPricingModel.unconfigured(counter.groupName),
        activityName: activityName,
      ),
    );
  }

  Future<CounterModel> addCounter(String name, String group) async {
    final id = await DatabaseService.insertCounter(
      CounterModel(name: name, groupName: group, color: '#FF7A9E'),
    );
    return (await DatabaseService.getCounters()).singleWhere((c) => c.id == id);
  }

  test('record_cheki with images counts and puts the photo in the album',
      () async {
    await addCounter('兔兔Miottie', 'ReCream');
    await SyncService.pushSnapshot(settings);
    final queued = await callTool('record_cheki', {
      'name': '兔兔Miottie',
      'three_inch': 1,
      'occurred_at': '2026-11-19',
      'images': [
        {'image_base64': _jpegBase64(200)}
      ],
    });
    expect(await stagedImages(), 1);

    final result = await SyncService.syncNow(settings);
    expect(result.failures, isEmpty);
    expect(result.applied, 2);

    final record = (await DatabaseService.getActivityRecords()).single;
    expect(record.sourceRecordId, queued['action_id']);
    final media = await DatabaseService.getActivityRecordMedia();
    expect(media, hasLength(1));
    expect(media.single.recordId, record.id);
    expect(media.single.mediaType, ActivityRecordMediaType.scan);
    expect(await File(media.single.path).exists(), isTrue);

    final status = await photoStatus(queued['photo_action_id'] as String);
    expect(status['status'], 'applied');
    expect(status['attached_record_id'], record.id);
    expect(status['photos_saved'], 1);
    expect(await stagedImages(), 0, reason: '应用后删除服务端暂存图');
  });

  test('attach_cheki_photos picks the same-day record of the named activity',
      () async {
    final counter = await addCounter('小羽', '起源');
    await addRecord(counter, DateTime(2026, 11, 18), activityName: '周三公演');
    final wanted =
        await addRecord(counter, DateTime(2026, 11, 19), activityName: '周四公演');
    await addRecord(counter, DateTime(2026, 11, 19, 22), activityName: '特典会');
    await SyncService.pushSnapshot(settings);

    final queued = await callTool('attach_cheki_photos', {
      'name': '小羽',
      'occurred_at': '2026-11-19',
      'activity_name': '周四',
      'images': [_jpegBase64(90), _jpegBase64(91)],
    });
    final result = await SyncService.syncNow(settings);
    expect(result.failures, isEmpty);

    final media = await DatabaseService.getActivityRecordMedia();
    expect(media.map((m) => m.recordId).toSet(), {wanted});
    expect(media, hasLength(2));
    final status = await photoStatus(queued['action_id'] as String);
    expect(status['status'], 'applied');
    expect(status['attached_record_id'], wanted);
    // Counting is untouched: three records of 1 each.
    final counters = await DatabaseService.getCounters();
    expect(counters.single.threeInchCount, 3);
  });

  test('a retried photo action does not attach the same photo twice', () async {
    final counter = await addCounter('晕酱Mizuyu', '某团');
    final recordId = await addRecord(counter, DateTime(2026, 11, 19));
    await SyncService.pushSnapshot(settings);
    await callTool('attach_cheki_photos', {
      'record_id': recordId,
      'images': [_jpegBase64(30)],
    });
    final pulled = await SyncService.pullActions(settings);
    // Simulate a lost receipt: the staged bytes are still on the server when
    // the same pulled action is applied again.
    final staged = {
      for (final file
          in store.faceImages.directory.listSync().whereType<File>())
        file.path: file.readAsBytesSync(),
    };
    final first = await SyncService.applyActions(settings, pulled);
    expect(first.failures, isEmpty);
    staged.forEach((path, bytes) => File(path).writeAsBytesSync(bytes));
    final again = await SyncService.applyActions(settings, pulled);
    expect(again.failures, isEmpty);
    expect(await DatabaseService.getActivityRecordMedia(), hasLength(1));
  });

  test('no record that day fails with a Chinese reason and cleans up',
      () async {
    await addCounter('卡绒Karon', '某团');
    await SyncService.pushSnapshot(settings);
    final queued = await callTool('attach_cheki_photos', {
      'name': '卡绒Karon',
      'occurred_at': '2026-11-19',
      'images': [_jpegBase64(10)],
    });
    final result = await SyncService.syncNow(settings);
    expect(
        result.failures.single.message, contains('找不到「卡绒Karon」在 2026-11-19'));
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
    final status = await photoStatus(queued['action_id'] as String);
    expect(status['status'], 'failed');
    expect(status['failure'], contains('照片未挂'));
    expect(await stagedImages(), 0);
  });

  test('an expired staged image fails with a Chinese reason', () async {
    final counter = await addCounter('小柠Hinako', '某团');
    await addRecord(counter, DateTime(2026, 11, 19));
    await SyncService.pushSnapshot(settings);
    final queued = await callTool('attach_cheki_photos', {
      'name': '小柠Hinako',
      'occurred_at': '2026-11-19',
      'images': [_jpegBase64(60)],
    });
    final pending = await callTool('list_pending_actions', {});
    final action = (pending['actions'] as List)
        .cast<Map>()
        .singleWhere((a) => a['id'] == queued['action_id']);
    final imageId =
        ((action['payload'] as Map)['images'] as List).first['imageId'];
    await store.faceImages.delete(imageId as String);

    final result = await SyncService.syncNow(settings);
    expect(result.failures.single.message, contains('已过期'));
    expect(
        (await photoStatus(queued['action_id'] as String))['status'], 'failed');
  });

  test('a photo waits while its record_cheki cannot be applied yet', () async {
    // No card for this member and no allow_create: the count stays pending.
    await addCounter('起源Chika', '起源');
    await SyncService.pushSnapshot(settings);
    final queued = await callTool('record_cheki', {
      'name': '起源Chika',
      'three_inch': 1,
      'occurred_at': '2026-11-19',
      'images': [_jpegBase64(120)],
    });
    // The card is deleted locally before the app syncs.
    final counters = await DatabaseService.getCounters();
    await DatabaseService.deleteCounter(counters.single.id!);

    final result = await SyncService.syncNow(settings);
    expect(result.failures, hasLength(2));
    expect(result.failures.last.message, contains('还没记上'));
    expect((await photoStatus(queued['photo_action_id'] as String))['status'],
        'pending');
    expect(await stagedImages(), 1, reason: '可重试时保留暂存图');
  });

  test('a ticket record id fails without attaching', () async {
    final ticketId = await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: '周四公演',
        occurredAt: DateTime(2026, 11, 19),
        quantity: 1,
        unitPrice: 80,
      ),
    );
    await DatabaseService.insertCounter(
        CounterModel(name: '某人', groupName: '某团', color: '#FF7A9E'));
    final result = await SyncService.applyActions(settings, [
      {
        'id': 'act_ticket_photo',
        'kind': SyncService.chekiPhotoActionKind,
        'payload': {
          'record_id': ticketId,
          'images': [
            {'imageId': 'unused'}
          ],
        },
      },
    ]);
    expect(result.failures.single.message, contains('门票'));
    expect(await DatabaseService.getActivityRecordMedia(), isEmpty);
  });

  group('face samples from attached photos', () {
    Future<void> enrollSelf() => FaceSampleService.addSamples([
          FaceSampleService.sampleFromAnalysis(_face(_self),
              source: FaceSampleSource.self),
        ]);

    Future<List<FaceSampleModel>> attachedSamples() async =>
        (await FaceSampleService.getSamples(isSelf: false))
            .where((s) => s.source == FaceSampleSource.attached)
            .toList();

    Future<Map<String, dynamic>> attachOne(String name) async {
      await SyncService.pushSnapshot(settings);
      final queued = await callTool('attach_cheki_photos', {
        'name': name,
        'occurred_at': '2026-11-19',
        'images': [_jpegBase64(77)],
      });
      final result = await SyncService.syncNow(settings);
      expect(result.failures, isEmpty);
      return photoStatus(queued['action_id'] as String);
    }

    test('the one face left after dropping "我" becomes an attached sample',
        () async {
      await enrollSelf();
      final counter = await addCounter('兔兔Miottie', 'ReCream');
      await addRecord(counter, DateTime(2026, 11, 19));
      // "我" at 0.30 (> 0.25) is dropped; the member's face is kept.
      detected = [_nearSelf(0.30), _face(_member)];

      final status = await attachOne('兔兔Miottie');
      expect(status['status'], 'applied');
      expect(status['face_samples_added'], 1);

      final sample = (await attachedSamples()).single;
      expect(sample.counterId, counter.id);
      expect(sample.isSelf, isFalse);
      expect(sample.embedding, _member);
      final media = (await DatabaseService.getActivityRecordMedia()).single;
      expect(sample.mediaId, media.id);
      expect(await FaceSampleService.countAttached(), 1);
    });

    test('a face at or below 0.25 to "我" counts, so two faces are skipped',
        () async {
      await enrollSelf();
      final counter = await addCounter('小羽', '起源');
      await addRecord(counter, DateTime(2026, 11, 19));
      detected = [_nearSelf(0.25), _face(_member)];

      final status = await attachOne('小羽');
      expect(status['status'], 'applied', reason: '照片照样挂上');
      expect(status['photos_saved'], 1);
      expect(status['face_samples_added'], 0);
      expect(status['face_skipped_not_single'], 1);
      expect(await attachedSamples(), isEmpty);
    });

    test('a photo with no face, or only "我", teaches nothing', () async {
      await enrollSelf();
      final counter = await addCounter('小柠Hinako', '某团');
      await addRecord(counter, DateTime(2026, 11, 19));
      detected = [_nearSelf(0.9)];

      final status = await attachOne('小柠Hinako');
      expect(status['face_samples_added'], 0);
      expect(status['face_skipped_not_single'], 1);
      expect(await attachedSamples(), isEmpty);
    });

    test('a 团切 record has no single owner and teaches nothing', () async {
      final counter = await addCounter('卡绒Karon', '某团');
      final recordId = await DatabaseService.insertActivityRecord(
        ActivityRecordModel.multiCut(
          participants: [
            ActivityParticipant(
                memberName: counter.name, groupName: counter.groupName),
            const ActivityParticipant(memberName: '别人', groupName: '某团'),
          ],
          field: CounterCountField.groupCut,
          occurredAt: DateTime(2026, 11, 19),
        ),
      );
      detected = [_face(_member)];
      await SyncService.pushSnapshot(settings);
      final queued = await callTool('attach_cheki_photos', {
        'record_id': recordId,
        'member_id': counter.id,
        'images': [_jpegBase64(5)],
      });
      final result = await SyncService.syncNow(settings);
      expect(result.failures, isEmpty);
      final status = await photoStatus(queued['action_id'] as String);
      expect(status['status'], 'applied');
      expect(status['face_samples_added'], 0);
      expect(await attachedSamples(), isEmpty);
    });

    test('attached samples can be revoked, and go with their photo', () async {
      final counter = await addCounter('晕酱Mizuyu', '某团');
      await addRecord(counter, DateTime(2026, 11, 19));
      detected = [_face(_member)];
      await attachOne('晕酱Mizuyu');
      expect(await FaceSampleService.countAttached(), 1);

      // A manual sample of the same member is never touched.
      await FaceSampleService.addSamples([
        FaceSampleService.sampleFromAnalysis(_face([0.9, 0.1, 0]),
            source: FaceSampleSource.manual,
            owner: null),
      ]);
      expect(await FaceSampleService.revokeAttached(), 1);
      expect(await FaceSampleService.countAttached(), 0);
      expect(await FaceSampleService.getSamples(isSelf: false), hasLength(1));

      // Learn again, then delete the photo: its sample goes too.
      await FaceSampleService.addSamples([
        FaceSampleService.sampleFromAnalysis(_face(_member),
            source: FaceSampleSource.attached,
            mediaId: (await DatabaseService.getActivityRecordMedia()).single.id),
      ]);
      expect(await FaceSampleService.countAttached(), 1);
      await DatabaseService.deleteActivityRecordMedia(
          (await DatabaseService.getActivityRecordMedia()).single.id!);
      expect(await FaceSampleService.countAttached(), 0);
      expect(await FaceSampleService.getSamples(isSelf: false), hasLength(1));
    });
  });
}
