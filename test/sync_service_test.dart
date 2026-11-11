// ignore_for_file: avoid_relative_lib_imports
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
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
