// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/http_transport.dart';
import '../lib/mcp_protocol.dart';
import '../lib/store.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('ota_sync_test');
  final store = SyncStore(dir.path);
  var passed = 0;
  void check(bool condition, String label) {
    if (!condition) {
      throw StateError('FAIL: $label');
    }
    passed += 1;
    stdout.writeln('ok $passed - $label');
  }

  try {
    final initial = await store.status();
    check(initial['rev'] == 0, 'new store starts at rev 0');
    check((await store.snapshot()) == null, 'new store has no snapshot');

    final snapshot = _sampleSnapshot();
    final pushed = await store.replaceSnapshot(snapshot, clientId: 'test-app');
    check(pushed['rev'] == 1, 'snapshot increments rev');
    check((await store.snapshot())?['schema'] == 'ota-counter-snapshot',
        'snapshot round-trips');

    final protocol = McpProtocol(store);
    final init = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'clientInfo': {'name': 'self-test'},
      },
    }) as Map;
    check(init['result']['serverInfo']['name'] == kSyncServerName,
        'MCP initialize returns server info');

    final tools = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 2,
      'method': 'tools/list',
    }) as Map;
    check((tools['result']['tools'] as List).length >= 8,
        'tools/list exposes the bridge tools');

    final resources = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 20,
      'method': 'resources/list',
    }) as Map;
    check((resources['result']['resources'] as List).length == 4,
        'resources/list exposes JSON views');

    final resourceRead = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 21,
      'method': 'resources/read',
      'params': {'uri': 'ota://overview'},
    }) as Map;
    check(
      (resourceRead['result']['contents'] as List)
          .first['text']
          .toString()
          .contains('total_count'),
      'resources/read returns overview JSON',
    );

    final prompt = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 22,
      'method': 'prompts/get',
      'params': {
        'name': 'daily-summary',
        'arguments': {'date': '2026-10-31'},
      },
    }) as Map;
    check((prompt['result']['messages'] as List).isNotEmpty,
        'prompts/get builds a daily summary request');

    final overviewCall = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'get_overview', 'arguments': {}},
    }) as Map;
    final overview = overviewCall['result']['structuredContent'] as Map;
    check(overview['total_count'] == 12, 'overview uses snapshot summary');
    check(overview['member_count'] == 2, 'overview counts members');
    check(overview['tickets']['ticket_count'] == 1,
        'overview includes ticket stats');

    final membersCall = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 4,
      'method': 'tools/call',
      'params': {
        'name': 'list_members',
        'arguments': {'query': '林'},
      },
    }) as Map;
    final members =
        (membersCall['result']['structuredContent'] as Map)['members'] as List;
    check(members.length == 1, 'list_members filters by name');
    check(members.first['name'] == '林小满', 'member name is preserved');

    final actionCall = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 5,
      'method': 'tools/call',
      'params': {
        'name': 'record_cheki',
        'arguments': {
          'member_id': 1,
          'three_inch': 2,
          'note': 'self test',
        },
      },
    }) as Map;
    final action = actionCall['result']['structuredContent'] as Map;
    check(action['status'] == 'pending', 'record_cheki queues an action');
    check((await store.actions(status: 'pending')).length == 1,
        'pending action is stored');

    final pendingCall = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 6,
      'method': 'tools/call',
      'params': {'name': 'list_pending_actions', 'arguments': {}},
    }) as Map;
    check(
      (pendingCall['result']['structuredContent'] as Map)['count'] == 1,
      'list_pending_actions sees the queue',
    );

    final ack = await store.acknowledgeActions([action['action_id'] as String]);
    check(ack['applied'] == 1, 'ack marks the action applied');
    check((await store.actions(status: 'pending')).isEmpty,
        'ack empties the pending queue');

    // Reload from disk to prove persistence and the file lock.
    final reloaded = SyncStore(dir.path);
    final reloadedStatus = await reloaded.status();
    check(reloadedStatus['rev'] == 3, 'state persists across store instances');
    check((await reloaded.snapshot()) != null, 'snapshot persists on disk');

    final token = 'test-token-123';
    final server = SyncHttpServer(
      store: reloaded,
      token: token,
      host: '127.0.0.1',
      port: 0,
    );
    await server.start();
    final base = 'http://127.0.0.1:${server.actualPort}';
    final client = HttpClient();

    final health = await _request(client, 'GET', '$base/health');
    check(health.status == 200, 'health is public');
    final healthJson = jsonDecode(health.body) as Map;
    check(healthJson['ok'] == true, 'health payload is ok');

    final unauthorized = await _request(client, 'GET', '$base/api/v1/status');
    check(unauthorized.status == 401, 'private endpoint rejects missing token');

    final status = await _request(
      client,
      'GET',
      '$base/api/v1/status',
      token: token,
    );
    check(status.status == 200, 'private endpoint accepts bearer token');

    final mcp = await _request(
      client,
      'POST',
      '$base/mcp',
      token: token,
      body: {
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'tools/call',
        'params': {'name': 'get_overview', 'arguments': {}},
      },
    );
    check(mcp.status == 200, 'MCP HTTP accepts a JSON-RPC POST');
    final mcpJson = jsonDecode(mcp.body) as Map;
    check(mcpJson['result']['structuredContent']['total_count'] == 12,
        'MCP HTTP returns overview data');

    final sse = await _sseFirstEvent(client, '$base/sse?token=$token');
    check(sse.contains('event: endpoint'), 'SSE sends the endpoint event');
    check(sse.contains('/messages?sessionId='), 'SSE endpoint has a session');

    client.close(force: true);
    await server.close();
    stdout.writeln('All $passed sync server checks passed.');
  } finally {
    await dir.delete(recursive: true);
  }
}

Map<String, dynamic> _sampleSnapshot() {
  return {
    'schema': 'ota-counter-snapshot',
    'version': 1,
    'exported_at': '2026-10-31T12:00:00.000',
    'device_id': 'test-device',
    'app_version': '1.5.4+20',
    'counters': [
      {
        'id': 1,
        'name': '林小满',
        'group_name': 'Aurora',
        'person_id': null,
        'person_name': '',
        'color': '#FF7A9E',
        'is_hidden': 0,
        'three_inch_count': 5,
        'five_inch_count': 2,
        'group_cut_count': 1,
        'total_count': 8,
      },
      {
        'id': 2,
        'name': '阿岚',
        'group_name': 'Lumiere',
        'person_id': null,
        'person_name': '',
        'color': '#21B6A8',
        'is_hidden': 0,
        'three_inch_count': 2,
        'five_inch_count': 2,
        'total_count': 4,
      },
    ],
    'records': [
      {
        'id': 1,
        'record_type': 'counter',
        'subject_name': '林小满',
        'group_name': 'Aurora',
        'occurred_at': '2026-10-31T10:00:00.000',
        'three_inch_count': 2,
        'total_amount': 160,
      },
      {
        'id': 2,
        'record_type': 'ticket',
        'subject_name': 'Aurora 公演',
        'occurred_at': '2026-10-30T18:00:00.000',
        'ticket_quantity': 1,
        'total_amount': 80,
      },
    ],
    'pricings': [
      {
        'group_name': 'Aurora',
        'label': '标准价',
        'three_inch_price': 80,
        'five_inch_price': 120,
      },
    ],
    'summary': {
      'total_count': 12,
      'by_type': {
        'threeInchCount': 7,
        'fiveInchCount': 4,
        'groupCutCount': 1,
      },
      'member_count': 2,
      'record_count': 2,
      'revenue': 240,
    },
  };
}

class _Response {
  _Response(this.status, this.body);
  final int status;
  final String body;
}

Future<_Response> _request(
  HttpClient client,
  String method,
  String url, {
  String? token,
  Object? body,
}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  return _Response(response.statusCode, text);
}

Future<String> _sseFirstEvent(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close().timeout(const Duration(seconds: 5));
  final buffer = StringBuffer();
  await for (final chunk in response.transform(utf8.decoder)) {
    buffer.write(chunk);
    if (buffer.toString().contains('/messages?sessionId=')) {
      break;
    }
  }
  return buffer.toString();
}
