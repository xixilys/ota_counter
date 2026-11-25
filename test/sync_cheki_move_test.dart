// ignore_for_file: avoid_relative_lib_imports
// End-to-end: MCP move_cheki_photo → app pull → photo on another member /
// day, counts moved with it → receipt; plus the album sheet's direct path.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/services/cheki_photo_move_service.dart';
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

  Future<int> addRecord(CounterModel counter,
          {int threeInch = 2, DateTime? day, String note = ''}) =>
      DatabaseService.insertActivityRecordWithCounterImpact(
        ActivityRecordModel.counterAdjustment(
          counter: counter,
          note: note,
          occurredAt: day ?? DateTime(2026, 11, 21),
          deltas: {CounterCountField.threeInch: threeInch},
          pricing: GroupPricingModel.unconfigured(counter.groupName),
          activityName: '生诞祭',
        ),
      );

  Future<List<int>> attach(int recordId, List<int> shades,
      {List<FaceAnalysis>? faces}) async {
    if (faces != null) detected = faces;
    await SyncService.pushSnapshot(settings);
    await tool('attach_cheki_photos', {
      'record_id': recordId,
      'images': [for (final shade in shades) base64Encode(_jpeg(shade))],
    });
    expect((await SyncService.syncNow(settings)).failures, isEmpty);
    final listed = await tool('list_record_photos', {'record_id': recordId});
    return [
      for (final p in (listed['photos'] as List).cast<Map>())
        p['media_id'] as int
    ];
  }

  Future<ActivityRecordModel?> record(int id) async =>
      (await DatabaseService.getActivityRecords())
          .where((r) => r.id == id)
          .firstOrNull;

  Future<ActivityRecordMediaModel> photo(int id) async =>
      (await DatabaseService.getActivityRecordMedia())
          .singleWhere((m) => m.id == id);

  Future<Map<String, dynamic>> moveAndSync(Map<String, dynamic> args) async {
    await SyncService.pushSnapshot(settings);
    final queued = await tool('move_cheki_photo', args);
    final result = await SyncService.syncNow(settings);
    expect(result.failures, isEmpty,
        reason: result.failures.map((f) => f.message).join('; '));
    return queued;
  }

  test('moves a photo to the same member\'s existing record on another day',
      () async {
    final tutu = await addCounter('兔兔Miottie');
    final wrong = await addRecord(tutu, threeInch: 2);
    final right =
        await addRecord(tutu, threeInch: 1, day: DateTime(2026, 11, 22));
    final ids = await attach(wrong, [10, 20]);
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 3);

    final queued =
        await moveAndSync({'media_id': ids[0], 'date': '2026-11-22'});
    expect((queued['to'] as Map)['likely_record'], containsPair('id', right));

    expect((await photo(ids[0])).recordId, right);
    expect((await record(wrong))!.threeInchCount, 1, reason: '原流水减一张');
    expect((await record(right))!.threeInchCount, 2, reason: '目标加一张');
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 3,
        reason: '同一成员，累计不变');
    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'applied');
    expect(
        status['result'],
        allOf(
          containsPair('record_id', right),
          containsPair('count_moved', true),
          containsPair('count_field', 'three_inch_count'),
          containsPair('created_record', false),
        ));
  });

  test(
      'creates the day\'s record when there is none, and a replay adds nothing',
      () async {
    final tutu = await addCounter('兔兔Miottie');
    final wrong = await addRecord(tutu, threeInch: 2);
    final ids = await attach(wrong, [10, 20]);

    await SyncService.pushSnapshot(settings);
    final queued = await tool('move_cheki_photo', {
      'media_id': ids[1],
      'date': '2026-11-23',
      'activity_name': '上海公演',
      'venue_name': 'Livehouse',
    });
    expect((queued['to'] as Map)['will_create_record'], isTrue);
    final pulled = await SyncService.pullActions(settings);
    expect(
        (await SyncService.applyActions(settings, pulled)).failures, isEmpty);

    final moved = await photo(ids[1]);
    final created = (await record(moved.recordId))!;
    expect(created.id, isNot(wrong));
    expect(recordDay(created), DateTime(2026, 11, 23));
    expect(created.activityName, '上海公演');
    expect(created.venueName, 'Livehouse');
    expect(created.threeInchCount, 1);
    expect((await record(wrong))!.threeInchCount, 1);
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 2);

    // Lost receipt: the same action is applied again.
    expect(
        (await SyncService.applyActions(settings, pulled)).failures, isEmpty);
    expect(await DatabaseService.getActivityRecords(), hasLength(2));
    expect((await record(wrong))!.threeInchCount, 1);
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 2);
    expect(
        (await editStatus(queued['action_id'] as String))['status'], 'applied');
  });

  test('a new member gets the photo, the count, and the face samples',
      () async {
    final tutu = await addCounter('兔兔Miottie');
    final mimi = await addCounter('米米');
    final wrong = await addRecord(tutu, threeInch: 2);
    final ids = await attach(wrong, [
      10,
      20
    ], faces: [
      _face(const [1, 0, 0])
    ]);
    Future<List<FaceSampleModel>> samplesOf(int mediaId) async =>
        (await FaceSampleService.getSamples(isSelf: false))
            .where((s) => s.mediaId == mediaId)
            .toList();
    expect((await samplesOf(ids[0])).single.counterId, tutu.id);

    detected = [
      _face(const [0, 1, 0])
    ];
    final queued = await moveAndSync({'media_id': ids[0], 'member': '米米'});

    final moved = await photo(ids[0]);
    final target = (await record(moved.recordId))!;
    expect(target.counterId, mimi.id);
    expect(recordDay(target), DateTime(2026, 11, 21), reason: '没给日期沿用原日期');
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 1);
    expect((await counterNamed('米米')).threeInchCount, 1);
    final samples = await samplesOf(ids[0]);
    expect(samples, hasLength(1));
    expect(samples.single.counterId, mimi.id, reason: '旧成员的样本撤掉，按新成员重学');
    expect((await samplesOf(ids[1])).single.counterId, tutu.id,
        reason: '同流水别的照片不受影响');
    final result =
        (await editStatus(queued['action_id'] as String))['result'] as Map;
    expect(result['face_samples_removed'], 1);
    expect(result['face_samples_added'], 1);
  });

  test('photos beyond the record\'s count move without a count', () async {
    final tutu = await addCounter('兔兔Miottie');
    final wrong = await addRecord(tutu, threeInch: 1);
    final ids = await attach(wrong, [10, 20, 30]);
    final queued =
        await moveAndSync({'media_id': ids[2], 'date': '2026-11-22'});
    final target = (await record((await photo(ids[2])).recordId))!;
    expect(target.counterCountTotal, 0);
    expect((await record(wrong))!.threeInchCount, 1);
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 1);
    final result =
        (await editStatus(queued['action_id'] as String))['result'] as Map;
    expect(result['count_moved'], isFalse);
    expect(result['count_not_moved_reason'], contains('多出来的照片'));
  });

  test('a record emptied by the move is removed; one with a note is kept',
      () async {
    final tutu = await addCounter('兔兔Miottie');
    final lone = await addRecord(tutu, threeInch: 1);
    final noted = await addRecord(tutu,
        threeInch: 1, day: DateTime(2026, 11, 20), note: '记得');
    final loneIds = await attach(lone, [10]);
    final notedIds = await attach(noted, [20]);
    await moveAndSync({'media_id': loneIds.single, 'date': '2026-11-24'});
    await moveAndSync({'media_id': notedIds.single, 'date': '2026-11-24'});
    expect(await record(lone), isNull, reason: '0 张、无照片、无备注 → 删掉');
    expect((await record(noted))!.counterCountTotal, 0, reason: '有备注保留');
    expect((await counterNamed('兔兔Miottie')).threeInchCount, 2);
    final day24 = (await DatabaseService.getActivityRecords())
        .where((r) => recordDay(r) == DateTime(2026, 11, 24))
        .toList();
    expect(day24.single.threeInchCount, 2, reason: '第二张挂到第一次新建的流水');
  });

  test('a photo already moved on the phone is not moved again', () async {
    final tutu = await addCounter('兔兔Miottie');
    final wrong = await addRecord(tutu, threeInch: 2);
    final other =
        await addRecord(tutu, threeInch: 1, day: DateTime(2026, 11, 25));
    final ids = await attach(wrong, [10, 20]);
    await SyncService.pushSnapshot(settings);
    final queued = await tool(
        'move_cheki_photo', {'media_id': ids[0], 'date': '2026-11-22'});
    // Moved by hand in the album first.
    final plan = await ChekiPhotoMoveService.plan(PhotoMoveRequest(
        mediaId: ids[0], counterId: tutu.id!, day: DateTime(2026, 11, 25)));
    await ChekiPhotoMoveService.apply(plan);

    final result = await SyncService.syncNow(settings);
    expect(result.failures, hasLength(1));
    expect((await photo(ids[0])).recordId, other);
    final status = await editStatus(queued['action_id'] as String);
    expect(status['status'], 'failed');
    expect(status['failure'], contains('已挪到'));
  });

  group('album sheet path', () {
    Future<int> saveScan(int recordId, {DateTime? capturedAt}) async =>
        (await DatabaseService.saveActivityRecordMediaBytes(
          recordId: recordId,
          bytes: _jpeg(77),
          mediaType: ActivityRecordMediaType.scan,
          capturedAt: capturedAt,
        ))
            .id!;

    test('moves the count, clears a contradicting camera date', () async {
      final tutu = await addCounter('兔兔Miottie');
      final wrong = await addRecord(tutu, threeInch: 1);
      final mediaId =
          await saveScan(wrong, capturedAt: DateTime(2026, 11, 21, 19));
      final plan = await ChekiPhotoMoveService.plan(PhotoMoveRequest(
          mediaId: mediaId, counterId: tutu.id!, day: DateTime(2026, 11, 22)));
      expect(plan.createsTarget, isTrue);
      expect(plan.countField, CounterCountField.threeInch);
      expect(plan.clearsCapturedAt, isTrue);
      expect(plan.removesEmptySource, isTrue);
      expect(plan.memberChanged, isFalse);
      final result = await ChekiPhotoMoveService.apply(plan);
      expect(result.outcome.sourceRemoved, isTrue);
      final moved = await photo(mediaId);
      expect(moved.capturedAt, isNull);
      expect(
          recordDay((await record(moved.recordId))!), DateTime(2026, 11, 22));
      expect((await counterNamed('兔兔Miottie')).threeInchCount, 1);
    });

    test('memory photos and 多人切 sources never carry a count', () {
      final counter =
          CounterModel(id: 1, name: 'A', groupName: 'G', color: '#000000');
      final single = ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: DateTime(2026, 11, 21),
        deltas: {CounterCountField.fiveInch: 2},
      ).copyWith(id: 5);
      ActivityRecordMediaModel media(ActivityRecordMediaType type) =>
          ActivityRecordMediaModel(
              id: 1,
              recordId: 5,
              path: 'x',
              createdAt: DateTime(2026),
              mediaType: type);
      expect(
          ChekiPhotoMoveService.countToMove(
                  media: media(ActivityRecordMediaType.scan),
                  source: single,
                  target: null,
                  sourceScanCount: 2)
              .$1,
          CounterCountField.fiveInch);
      expect(
          ChekiPhotoMoveService.countToMove(
                  media: media(ActivityRecordMediaType.memory),
                  source: single,
                  target: null,
                  sourceScanCount: 2)
              .$2,
          contains('纪念照'));
      final multi = ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G'),
        ],
        occurredAt: DateTime(2026, 11, 21),
        field: CounterCountField.groupCut,
      );
      expect(
          ChekiPhotoMoveService.countToMove(
                  media: media(ActivityRecordMediaType.scan),
                  source: multi,
                  target: null,
                  sourceScanCount: 1)
              .$2,
          contains('多人切'));
    });
  });
}

DateTime recordDay(ActivityRecordModel record) => DateTime(
    record.occurredAt.year, record.occurredAt.month, record.occurredAt.day);
