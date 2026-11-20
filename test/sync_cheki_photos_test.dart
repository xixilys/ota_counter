// ignore_for_file: avoid_relative_lib_imports
// End-to-end: MCP attach_cheki_photos / record_cheki images → app pull →
// photo archived on the record (切册) → applied / failed receipt.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/services/database_service.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
}
