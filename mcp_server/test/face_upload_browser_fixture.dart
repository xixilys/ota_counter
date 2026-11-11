// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';
import '../lib/http_transport.dart';
import '../lib/mcp_protocol.dart';
import '../lib/store.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('ota-face-browser-');
  final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final store = SyncStore(dir.path,
      publicBaseUrl: 'http://127.0.0.1:${proxy.port}/ota-sync');
  final server =
      SyncHttpServer(store: store, token: 'synthetic-sync-only', port: 0);
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  await server.start();
  await store.replaceSnapshot({
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
  final uploadUrl =
      (result['result']['structuredContent'] as Map)['url'] as String;
  var posts = 0;
  final requests = <Map<String, Object?>>[];
  proxy.listen((req) async {
    if (req.uri.path == '/start') {
      req.response.statusCode = 302;
      req.response.headers.set('location', uploadUrl);
      await req.response.close();
      return;
    }
    if (req.uri.path == '/test-state') {
      final actions = await store.actions(status: 'pending');
      final entries = await store.faceImages.directory.exists()
          ? await store.faceImages.directory
              .list()
              .where((e) => e is File && !e.path.endsWith('.json'))
              .toList()
          : <FileSystemEntity>[];
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'actions': actions.map((a) => a['kind']).toList(),
        'requests': requests,
        'images': entries.length
      }));
      await req.response.close();
      return;
    }
    if (req.uri.path == '/test-image') {
      final entries = await store.faceImages.directory
          .list()
          .where((e) => e is File && !e.path.endsWith('.json'))
          .toList();
      req.response.headers.contentType = ContentType('image', 'jpeg');
      await req.response.addStream((entries.first as File).openRead());
      await req.response.close();
      return;
    }
    if (!req.uri.path.startsWith('/ota-sync/')) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    if (req.method == 'POST') {
      posts++;
      requests.add({
        'path': req.uri.path,
        'hasQuery': req.uri.hasQuery,
        'hasReferer': req.headers.value('referer') != null,
        'authBearer':
            (req.headers.value('authorization') ?? '').startsWith('Bearer ')
      });
      if (posts == 2) {
        await req.drain<void>();
        req.response.statusCode = 503;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': '合成故障，请重试'}));
        await req.response.close();
        return;
      }
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
  stdout.writeln('PORT ${proxy.port}');
  await ProcessSignal.sigterm.watch().first;
  client.close(force: true);
  await proxy.close(force: true);
  await server.close();
  await dir.delete(recursive: true);
}
