// ignore_for_file: avoid_relative_lib_imports
// HTTP-only companion to the browser verification; does not exercise JS.
import 'dart:convert';
import 'dart:io';
import '../lib/http_transport.dart';
import '../lib/mcp_protocol.dart';
import '../lib/store.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('ota-face-synthetic-');
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final store = SyncStore(dir.path,
      publicBaseUrl: 'http://127.0.0.1:${proxy.port}/ota-sync');
  final server =
      SyncHttpServer(store: store, token: 'synthetic-sync-credential', port: 0);
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  void check(bool ok, String message) {
    if (!ok) throw StateError(message);
    stdout.writeln('PASS $message');
  }

  try {
    await server.start();
    proxy.listen((req) async {
      if (!req.uri.path.startsWith('/ota-sync/')) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final target = Uri(
          scheme: 'http',
          host: '127.0.0.1',
          port: server.actualPort,
          path: req.uri.path.substring('/ota-sync'.length),
          query: req.uri.hasQuery ? req.uri.query : null);
      final out = await client.openUrl(req.method, target);
      req.headers.forEach((name, values) {
        if (name != 'host' && name != 'content-length') {
          for (final value in values) {
            out.headers.add(name, value);
          }
        }
      });
      await out.addStream(req);
      final response = await out.close();
      req.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (name != 'transfer-encoding' && name != 'content-length') {
          for (final value in values) {
            req.response.headers.add(name, value);
          }
        }
      });
      await req.response.addStream(response);
      await req.response.close();
    });
    await store.replaceSnapshot({
      'schema': 'ota-counter-snapshot',
      'counters': [
        {'id': 1, 'name': '合成成员', 'group_name': '合成团体'}
      ]
    });
    final result = await McpProtocol(store).handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'create_face_upload_link',
        'arguments': {'member': '合成成员', 'group': '合成团体'}
      }
    }) as Map;
    final content = result['result']['structuredContent'] as Map;
    final url = Uri.parse(content['url'] as String);
    check(url.path == '/ota-sync/face-upload' && content['max_images'] == 10,
        'MCP link includes proxy prefix and 10-image limit');
    final get = await client.getUrl(url);
    final page = await get.close();
    final html = await utf8.decoder.bind(page).join();
    check(
        page.statusCode == 200 &&
            html.contains('合成成员') &&
            html.contains('合成团体'),
        'proxy serves Chinese synthetic member page');
    check(
        page.headers.value('referrer-policy') == 'no-referrer' &&
            !html.contains(url.queryParameters['token']!),
        'GET suppresses referrer and does not embed capability in HTML');
    final capability = url.queryParameters['token']!;
    final postUrl = url.replace(query: '');
    for (var i = 0; i < 11; i++) {
      final req = await client.postUrl(postUrl);
      req.headers.set('authorization', 'Bearer $capability');
      req.headers.contentType = ContentType('image', 'jpeg');
      req.add([0xff, 0xd8, 0xff, 0xd9]);
      final response = await req.close();
      await response.drain<void>();
      check(response.statusCode == (i < 10 ? 201 : 409),
          'upload ${i + 1}: ${i < 10 ? 'queued' : 'limit enforced'}');
    }
    final actions = await store.actions(status: 'pending');
    check(
        actions.length == 10 &&
            actions.every((a) => a['kind'] == 'enroll_face'),
        'exactly ten enroll_face actions queued');
    final files = await store.faceImages.directory
        .list()
        .where((e) => e is File && !e.path.endsWith('.json'))
        .length;
    check(files == 10, 'ten synthetic byte streams persisted');
    final state = await store.stateFile.readAsString();
    check(!state.contains('synthetic-sync-credential'),
        'sync credential absent from persisted state');
  } finally {
    client.close(force: true);
    await proxy.close(force: true);
    await server.close();
    await dir.delete(recursive: true);
  }
}
