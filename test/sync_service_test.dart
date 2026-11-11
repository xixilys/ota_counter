// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/sync_service.dart';

import '../mcp_server/lib/http_transport.dart';
import '../mcp_server/lib/mcp_protocol.dart';
import '../mcp_server/lib/store.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dataDir;
  late SyncStore store;
  late SyncHttpServer server;
  late SyncSettings settings;

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'top.huangxuanqi.otacounter',
      version: '1.5.4',
      buildNumber: '20',
      buildSignature: '',
    );
    await DatabaseService.clearAppData();
    dataDir = await Directory.systemTemp.createTemp('ota_sync_app_test');
    store = SyncStore(dataDir.path);
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
    if (await dataDir.exists()) {
      await dataDir.delete(recursive: true);
    }
  });

  test('snapshot upload, queued MCP action, apply and ack round trip',
      () async {
    final counterId = await DatabaseService.insertCounter(
      CounterModel(
        name: '林小满',
        groupName: 'Aurora',
        color: '#FF7A9E',
        threeInchCount: 3,
        fiveInchCount: 1,
      ),
    );

    final pushed = await SyncService.pushSnapshot(settings);
    expect(pushed['ok'], isTrue);
    final snapshot = await store.snapshot();
    expect(snapshot, isNotNull);
    expect(snapshot!['schema'], 'ota-counter-snapshot');
    expect(snapshot['summary']['total_count'], 4);

    final protocol = McpProtocol(store);
    final queued = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'record_cheki',
        'arguments': {
          'member_id': counterId,
          'three_inch': 2,
          'note': 'MCP integration test',
          'occurred_at': '2026-10-31',
        },
      },
    }) as Map;
    expect(queued['result']['isError'], isFalse);
    final actionId = queued['result']['structuredContent']['action_id'];

    final result = await SyncService.syncNow(settings);
    expect(result.pulled, 1);
    expect(result.applied, 1);
    expect(result.pending, 0);
    expect(result.failures, isEmpty);

    final counters = await DatabaseService.getCounters();
    expect(counters.single.threeInchCount, 5);
    final records = await DatabaseService.getActivityRecords();
    final applied = records.singleWhere(
      (record) => record.sourceRecordId == actionId,
    );
    expect(applied.source, SyncService.mcpSource);
    expect(applied.note, 'MCP integration test');
    expect(applied.threeInchCount, 2);

    final actions = await store.actions(status: 'pending');
    expect(actions, isEmpty);
    final updated = await store.snapshot();
    expect(updated!['summary']['total_count'], 6);
  });

  test('face uploads round trip through the real sync server and App',
      () async {
    await DatabaseService.insertCounter(
      CounterModel(name: '合成成员', groupName: '测试团', color: '#FF7A9E'),
    );
    await SyncService.pushSnapshot(settings);

    final originalAnalyzer = FaceSampleService.analyzer;
    var analyses = 0;
    FaceSampleService.analyzer = (bytes) async {
      expect(bytes, isNotEmpty);
      analyses++;
      if (analyses == 2) return [];
      return [
        FaceAnalysis(
          face: const FaceDetection(
            x: 2,
            y: 3,
            width: 4,
            height: 5,
            landmarks: [],
            score: 0.9,
          ),
          embedding: Float32List.fromList([1, 0, 0]),
        ),
      ];
    };
    addTearDown(() => FaceSampleService.analyzer = originalAnalyzer);

    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    Future<Map<String, dynamic>> callTool(
      String name,
      Map<String, dynamic> arguments,
    ) async {
      final request =
          await client.postUrl(Uri.parse('${settings.baseUrl}/mcp'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
      request.write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      }));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final envelope =
          jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect(envelope['result']['isError'], isFalse);
      return Map<String, dynamic>.from(
          envelope['result']['structuredContent'] as Map);
    }

    final link = await callTool('create_face_upload_link', {
      'member': '合成成员',
      'group': '测试团',
    });
    final uri = Uri.parse(link['url'] as String);
    expect(uri.port, server.actualPort);
    final jpeg = image.encodeJpg(image.Image(width: 8, height: 8));
    for (var i = 0; i < 2; i++) {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType('image', 'jpeg');
      request.add(jpeg);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.created);
      await response.drain<void>();
    }

    final pending = await SyncService.pullActions(settings);
    expect(pending, hasLength(2));
    final imageIds = pending
        .map((action) => (action['payload'] as Map)['imageId'] as String)
        .toList();
    final unauthenticated = await client.getUrl(
        Uri.parse('${settings.baseUrl}/api/v1/face-images/${imageIds.first}'));
    final denied = await unauthenticated.close();
    expect(denied.statusCode, HttpStatus.unauthorized);
    await denied.drain<void>();

    final result = await SyncService.syncNow(settings);
    expect(result.pulled, 2);
    expect(result.applied, 1);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.message, contains('未检测到'));
    expect(await store.actions(status: 'pending'), isEmpty);

    final enrollmentList = await callTool('list_face_enrollments', {});
    final enrollments = List<Map<String, dynamic>>.from(
        (enrollmentList['enrollments'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map)));
    final applied = enrollments.singleWhere((e) => e['status'] == 'applied');
    final failed = enrollments.singleWhere((e) => e['status'] == 'failed');
    expect(applied['result']['faces_found'], 1);
    expect(applied['result']['used_face'], 1);
    expect(applied['result']['samples_kept'], 1);
    expect(applied['result']['used_face_bounds']['x'], 2);
    expect(failed['failure'], contains('未检测到'));
    expect(await FaceSampleService.getSamples(isSelf: false), hasLength(1));
    for (final id in imageIds) {
      final request = await client
          .getUrl(Uri.parse('${settings.baseUrl}/api/v1/face-images/$id'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
      final response = await request.close();
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    }
  });

  test('ticket action is applied and missing members stay pending', () async {
    await DatabaseService.insertCounter(
      CounterModel(name: '阿岚', groupName: 'Lumiere', color: '#21B6A8'),
    );
    await SyncService.pushSnapshot(settings);

    final protocol = McpProtocol(store);
    final ticket = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/call',
      'params': {
        'name': 'add_ticket',
        'arguments': {
          'event_name': 'Aurora 公演',
          'quantity': 2,
          'unit_price': 80,
          'ticket_type': '预售票',
          'occurred_at': '2026-10-31',
        },
      },
    }) as Map;
    expect(ticket['result']['isError'], isFalse);

    final missing = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'record_cheki',
        'arguments': {
          'member_id': 99999,
          'three_inch': 1,
        },
      },
    }) as Map;
    expect(missing['result']['isError'], isTrue);

    final result = await SyncService.syncNow(settings);
    // The missing member was rejected before queueing, so only the ticket is
    // pending and it should apply cleanly.
    expect(result.applied, 1);
    expect(result.failures, isEmpty);
    final records = await DatabaseService.getActivityRecords();
    final tickets = records.where((record) => record.isTicket).toList();
    expect(tickets, hasLength(1));
    expect(tickets.single.ticketQuantity, 2);
    expect(tickets.single.totalAmount, 160);
    expect(tickets.single.ticketType, '预售票');
    expect(tickets.single.resolvedTicketIsFree, isFalse);
  });

  test('snapshot total ignores legacy multi rows without a count field',
      () async {
    await DatabaseService.insertCounter(CounterModel(
      name: 'A',
      groupName: 'G',
      color: '#ffffff',
      threeInchCount: 1,
    ));
    await DatabaseService.insertCounter(CounterModel(
      name: 'B',
      groupName: 'G',
      color: '#ffffff',
      threeInchCount: 1,
    ));
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel(
        type: ActivityRecordType.multi,
        subjectName: 'A',
        groupName: 'G',
        occurredAt: DateTime(2026, 10, 31),
        multiCutQuantity: 2,
        totalAmount: 0,
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G'),
        ],
      ),
    );

    final snapshot = await SyncService.buildSnapshot(settings);
    final summary = snapshot['summary'] as Map;
    expect(summary['total_count'], 2);
    expect(snapshot['records'], hasLength(1));
  });
  Future<String> queueCheki(int counterId, {int threeInch = 2}) async {
    final protocol = McpProtocol(store);
    final queued = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 10,
      'method': 'tools/call',
      'params': {
        'name': 'record_cheki',
        'arguments': {
          'member_id': counterId,
          'three_inch': threeInch,
          'occurred_at': '2026-11-01',
        },
      },
    }) as Map;
    expect(queued['result']['isError'], isFalse);
    return queued['result']['structuredContent']['action_id'] as String;
  }

  test('same MCP action applied by two overlapping syncs is counted once',
      () async {
    final counterId = await DatabaseService.insertCounter(
      CounterModel(name: '林小满', groupName: 'Aurora', color: '#FF7A9E'),
    );
    await SyncService.pushSnapshot(settings);
    final actionId = await queueCheki(counterId);

    // Startup auto-sync and a manual "sync now" can both pull the action
    // before either of them acks it.
    final firstPull = await SyncService.pullActions(settings);
    final secondPull = await SyncService.pullActions(settings);
    expect(firstPull, hasLength(1));
    expect(secondPull, hasLength(1));
    await Future.wait([
      SyncService.applyActions(settings, firstPull),
      SyncService.applyActions(settings, secondPull),
    ]);

    final counter = (await DatabaseService.getCounters()).single;
    expect(counter.threeInchCount, 2);
    final records = await DatabaseService.getActivityRecords();
    expect(records.where((r) => r.sourceRecordId == actionId), hasLength(1));
    await DatabaseService.recalculateCountersFromActivityRecords();
    expect((await DatabaseService.getCounters()).single.threeInchCount, 2);
  });

  test('a duplicated action inside one pulled batch is counted once', () async {
    final counterId = await DatabaseService.insertCounter(
      CounterModel(name: '林小满', groupName: 'Aurora', color: '#FF7A9E'),
    );
    await SyncService.pushSnapshot(settings);
    await queueCheki(counterId, threeInch: 1);
    final pulled = await SyncService.pullActions(settings);

    final result =
        await SyncService.applyActions(settings, [...pulled, ...pulled]);

    expect(result.failures, isEmpty);
    expect((await DatabaseService.getCounters()).single.threeInchCount, 1);
    expect(await DatabaseService.getActivityRecordCount(), 1);
  });

  test('snapshot de-duplicates unsigned multi-cut photos per field', () async {
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.multiCut(
        participants: const [
          ActivityParticipant(memberName: 'A', groupName: 'G'),
          ActivityParticipant(memberName: 'B', groupName: 'G'),
        ],
        field: CounterCountField.unsignedThreeInch,
        occurredAt: DateTime(2026, 11, 1),
        quantity: 1,
      ),
    );

    final summary =
        (await SyncService.buildSnapshot(settings))['summary'] as Map;
    // One physical unsigned 3-inch photo with two members on it.
    expect(summary['total_count'], 1);
    expect(summary['by_type']['threeInchCount'], 1);
    expect(summary['by_type']['unsignedThreeInchCount'], 1);
  });
}
