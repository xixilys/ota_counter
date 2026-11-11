import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mcp_protocol.dart';
import 'face_images.dart';
import 'face_upload_page.dart';
import 'store.dart';

const int _maxBodyBytes = 32 * 1024 * 1024;

class SyncHttpServer {
  SyncHttpServer({
    required this.store,
    required this.token,
    this.host = '127.0.0.1',
    this.port = 8787,
  }) : protocol = McpProtocol(store);

  final SyncStore store;
  final String token;
  final String host;
  final int port;
  final McpProtocol protocol;

  HttpServer? _server;
  Timer? _faceSweep;
  final Map<String, _SseSession> _sseSessions = {};

  int get actualPort => _server?.port ?? port;

  Future<void> start() async {
    await store.faceImages.sweep();
    final server = await HttpServer.bind(host, port, shared: false);
    _faceSweep = Timer.periodic(const Duration(hours: 24), (_) {
      unawaited(store.faceImages.sweep().catchError((Object _) => 0));
    });
    _server = server;
    server.listen(_handle, onError: (Object error, StackTrace stack) {
      stderr.writeln('[ota-sync] server error: $error');
    });
  }

  Future<void> close() async {
    _faceSweep?.cancel();
    for (final session in _sseSessions.values) {
      await session.close();
    }
    _sseSessions.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    _applyCors(request.response);
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    try {
      if (path == '/face-upload' && {'GET', 'POST'}.contains(request.method)) {
        request.response.headers.set('cache-control', 'no-store');
        request.response.headers.set('referrer-policy', 'no-referrer');
        request.response.headers.set('x-content-type-options', 'nosniff');
        request.response.headers.set('content-security-policy',
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src blob:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
        final header = request.headers.value('authorization') ?? '';
        final secret = header.toLowerCase().startsWith('bearer ')
            ? header.substring(7).trim()
            : request.uri.queryParameters['token'] ?? '';
        final link = await store.faceUploadLink(secret);
        final target = Map<String, dynamic>.from(link['target'] as Map);
        if (request.method == 'GET') {
          await _writeHtml(
              request.response,
              faceUploadPage(target['member_name'] as String,
                  target['group_name'] as String));
        } else {
          if (request.contentLength > maxFaceImageBytes) {
            await request.drain<void>();
            throw FaceImageException('图片不能超过 15 MB', status: 413);
          }
          final imageId = await store.faceImages.save(
              request, request.headers.value('content-type'),
              contentLength: request.contentLength, drainOversize: true);
          late final Map<String, dynamic> queued;
          try {
            queued = await store.queueFaceEnrollment(target, imageId, 'upload',
                uploadSecret: secret);
          } catch (_) {
            await store.faceImages.delete(imageId);
            rethrow;
          }
          await _writeJson(request.response, queued,
              statusCode: HttpStatus.created);
        }
        return;
      }
      if (path.startsWith('/api/v1/face-images/') && request.method == 'GET') {
        if (!await _requireAuth(request, bearerOnly: true)) return;
        final id = path.substring('/api/v1/face-images/'.length);
        final file = store.faceImages.file(id);
        if (!await file.exists()) {
          throw FaceImageException('图片不存在或已清理', status: 404);
        }
        request.response.headers.set('cache-control', 'no-store');
        request.response.headers.set('x-content-type-options', 'nosniff');
        request.response.headers.set('content-disposition', 'attachment');
        request.response.headers
            .set('content-type', await store.faceImages.mime(id));
        await request.response.addStream(file.openRead());
        await request.response.close();
        return;
      }
      if (path == '/' && request.method == 'GET') {
        await _writeHtml(request.response, _landingPage());
        return;
      }
      if ((path == '/health' || path == '/api/v1/health') &&
          request.method == 'GET') {
        await _writeJson(request.response, {
          'ok': true,
          'name': kSyncServerName,
          'version': kSyncServerVersion,
          'time': nowIso(),
        });
        return;
      }
      if (path == '/api/v1/status' && request.method == 'GET') {
        if (!await _requireAuth(request)) return;
        await _writeJson(request.response, await store.status());
        return;
      }
      if (path == '/api/v1/snapshot' && request.method == 'POST') {
        if (!await _requireAuth(request)) return;
        final body = await _readJsonBody(request);
        if (body == null) return;
        final snapshotValue = body['snapshot'] ?? body;
        if (snapshotValue is! Map) {
          await _writeError(request.response, HttpStatus.badRequest,
              'Expected a JSON snapshot object');
          return;
        }
        final snapshot = Map<String, dynamic>.from(snapshotValue);
        final schema = readString(snapshot, ['schema', 'type']);
        if (schema.isNotEmpty &&
            schema != 'ota-counter-snapshot' &&
            schema != 'ota_counter_snapshot') {
          await _writeError(request.response, HttpStatus.badRequest,
              'Unknown snapshot schema: $schema');
          return;
        }
        final clientId = readString(body, ['device_id']).trim().isNotEmpty
            ? readString(body, ['device_id'])
            : readString(snapshot, ['device_id']);
        final status = await store.replaceSnapshot(
          snapshot,
          clientId: clientId,
        );
        await _writeJson(request.response, {
          'ok': true,
          'rev': status['rev'],
          'received_at': nowIso(),
          'pending_actions': _pendingCount(status),
        });
        return;
      }
      if (path == '/api/v1/actions' && request.method == 'GET') {
        if (!await _requireAuth(request)) return;
        final status = request.uri.queryParameters['status'] ?? 'pending';
        final limit =
            int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 50;
        final supportsFaceEnrollment = _supportsFaceEnrollment(request);
        final actions = await store.actions(
          status: status.isEmpty ? null : status,
          limit: limit.clamp(1, 200),
          excludeKinds:
              supportsFaceEnrollment ? null : const {kFaceEnrollmentActionKind},
        );
        await _writeJson(request.response, {
          'actions': actions,
          'count': actions.length,
          'rev': (await store.status())['rev'],
        });
        return;
      }
      if (path == '/api/v1/actions' && request.method == 'POST') {
        if (!await _requireAuth(request)) return;
        final body = await _readJsonBody(request);
        if (body == null) return;
        final action = body['action'] is Map
            ? Map<String, dynamic>.from(body['action'] as Map)
            : body;
        if (readString(action, ['kind', 'type']).isEmpty) {
          await _writeError(request.response, HttpStatus.badRequest,
              'Action requires a kind');
          return;
        }
        final queued = await store.queueAction(action);
        await _writeJson(
          request.response,
          queued,
          statusCode:
              queued['duplicate'] == true ? HttpStatus.ok : HttpStatus.created,
        );
        return;
      }
      if (path == '/api/v1/actions/ack' && request.method == 'POST') {
        if (!await _requireAuth(request)) return;
        final body = await _readJsonBody(request);
        if (body == null) return;
        final ids = (body['ids'] is List)
            ? (body['ids'] as List).map((value) => value.toString())
            : <String>[];
        if (!_supportsFaceEnrollment(request) &&
            (await store.faceEnrollments(status: 'pending'))
                .any((action) => ids.contains(action['id']))) {
          throw FaceImageException('当前 App 版本不支持脸照录入，请更新 App 后同步', status: 409);
        }
        final failuresRaw = body['failures'];
        final failures = <String, String>{};
        if (failuresRaw is Map) {
          failuresRaw.forEach((key, value) {
            failures[key.toString()] = value.toString();
          });
        }
        final result = await store.acknowledgeActions(
          ids,
          failures: failures.isEmpty ? null : failures,
          results: body['results'] is Map
              ? Map<String, dynamic>.from(body['results'] as Map)
              : null,
        );
        await _writeJson(request.response, {'ok': true, ...result});
        return;
      }
      if (path == '/mcp' && request.method == 'POST') {
        if (!await _requireAuth(request)) return;
        final text = await _readBody(request);
        if (text == null) return;
        Object? decoded;
        try {
          decoded = jsonDecode(text);
        } catch (_) {
          await _writeError(
              request.response, HttpStatus.badRequest, 'Invalid JSON body');
          return;
        }
        final response =
            await McpProtocol(store, requestBaseUrl: _requestBaseUrl(request))
                .handle(decoded);
        final sessionId =
            request.headers.value('mcp-session-id') ?? _newSessionId('mcp');
        request.response.headers.set('mcp-session-id', sessionId);
        if (response == null) {
          request.response.statusCode = HttpStatus.accepted;
          await request.response.close();
          return;
        }
        await _writeJson(request.response, response);
        return;
      }
      if (path == '/mcp' && request.method == 'GET') {
        request.response.headers.set(HttpHeaders.allowHeader, 'POST');
        await _writeError(request.response, HttpStatus.methodNotAllowed,
            'Use POST /mcp or the legacy /sse transport');
        return;
      }
      if (path == '/mcp' && request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (path == '/sse' && request.method == 'GET') {
        if (!await _requireAuth(request)) return;
        await _handleSse(request);
        return;
      }
      if (path == '/messages' && request.method == 'POST') {
        if (!await _requireAuth(request)) return;
        await _handleSseMessage(request);
        return;
      }
      await _writeError(
        request.response,
        HttpStatus.notFound,
        'Not found. Try /health, /api/v1/status, /api/v1/snapshot, /mcp or /sse.',
      );
    } on FaceImageException catch (error) {
      await _writeError(request.response, error.status, error.message);
    } catch (error, stack) {
      stderr.writeln('[ota-sync] request error: $error');
      if (error is FormatException) {
        stderr.writeln(stack);
      }
      try {
        await _writeError(
          request.response,
          HttpStatus.internalServerError,
          'Internal error',
        );
      } catch (_) {
        // The response may already be closed.
      }
    }
  }

  String _requestBaseUrl(HttpRequest request) {
    String? firstHeader(String name) {
      final value = request.headers.value(name)?.split(',').first.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final forwarded = <String, String>{};
    for (final part in (firstHeader('forwarded') ?? '').split(';')) {
      final separator = part.indexOf('=');
      if (separator < 0) continue;
      final key = part.substring(0, separator).trim().toLowerCase();
      var value = part.substring(separator + 1).trim();
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      if (value.isNotEmpty) forwarded[key] = value;
    }
    final scheme = forwarded['proto'] ??
        firstHeader('x-forwarded-proto') ??
        request.requestedUri.scheme;
    var authority = forwarded['host'] ??
        firstHeader('x-forwarded-host') ??
        request.requestedUri.authority;
    final port = firstHeader('x-forwarded-port');
    if (forwarded['host'] == null && port != null) {
      final host = Uri.tryParse('$scheme://$authority');
      if (host != null && !host.hasPort) {
        authority =
            '${host.host.contains(':') ? '[${host.host}]' : host.host}:$port';
      }
    }
    var prefix = firstHeader('x-forwarded-prefix') ?? '';
    if (prefix.isNotEmpty && !prefix.startsWith('/')) {
      prefix = '/$prefix';
    }
    prefix = prefix.replaceFirst(RegExp(r'/+$'), '');
    return '$scheme://$authority$prefix';
  }

  bool _supportsFaceEnrollment(HttpRequest request) {
    final header = request.headers.value(kCapabilitiesHeader) ?? '';
    return header
        .split(',')
        .map((value) => value.trim().toLowerCase())
        .contains(kFaceEnrollmentCapability);
  }

  Future<void> _handleSse(HttpRequest request) async {
    final sessionId = _newSessionId('sse');
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers
        .set(HttpHeaders.contentTypeHeader, 'text/event-stream; charset=utf-8');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    response.bufferOutput = false;

    final controller = StreamController<String>();
    final session = _SseSession(sessionId, controller);
    _sseSessions[sessionId] = session;
    response.write('event: endpoint\n');
    response.write('data: /messages?sessionId=$sessionId\n\n');
    await response.flush();

    session.heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      try {
        response.write(': ping\n\n');
        unawaited(response.flush());
      } catch (_) {
        unawaited(session.close());
      }
    });
    controller.stream.listen(
      (data) {
        try {
          response.write(data);
          unawaited(response.flush());
        } catch (_) {
          unawaited(session.close());
        }
      },
      onDone: () => unawaited(session.close()),
      onError: (_) => unawaited(session.close()),
    );
    unawaited(response.done.whenComplete(() async {
      _sseSessions.remove(sessionId);
      await session.close();
    }));
  }

  Future<void> _handleSseMessage(HttpRequest request) async {
    final sessionId = request.uri.queryParameters['sessionId'] ?? '';
    final session = _sseSessions[sessionId];
    if (session == null) {
      await _writeError(
        request.response,
        HttpStatus.notFound,
        'Unknown SSE session; reconnect to /sse',
      );
      return;
    }
    final text = await _readBody(request);
    if (text == null) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      await _writeError(
        request.response,
        HttpStatus.badRequest,
        'Invalid JSON body',
      );
      return;
    }
    final response =
        await McpProtocol(store, requestBaseUrl: _requestBaseUrl(request))
            .handle(decoded);
    if (response != null) {
      session.controller.add(
        'event: message\ndata: ${jsonEncode(response)}\n\n',
      );
    }
    await _writeJson(
      request.response,
      {'ok': true, 'sessionId': sessionId},
      statusCode: HttpStatus.accepted,
    );
  }

  Future<bool> _requireAuth(HttpRequest request,
      {bool bearerOnly = false}) async {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    var supplied = '';
    if (header.toLowerCase().startsWith('bearer ')) {
      supplied = header.substring(7).trim();
    }
    if (supplied.isEmpty && !bearerOnly) {
      supplied = request.headers.value('x-ota-token') ?? '';
    }
    if (supplied.isEmpty && !bearerOnly) {
      supplied = request.uri.queryParameters['token'] ?? '';
    }
    if (supplied.isNotEmpty && SyncConfig.constantTimeEquals(supplied, token)) {
      return true;
    }
    await _writeError(
      request.response,
      HttpStatus.unauthorized,
      'Missing or invalid bearer token. Use Authorization: Bearer <token>.',
    );
    return false;
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest request) async {
    final text = await _readBody(request);
    if (text == null) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      await _writeError(
        request.response,
        HttpStatus.badRequest,
        'Invalid JSON body',
      );
      return null;
    }
    if (decoded is! Map) {
      await _writeError(
        request.response,
        HttpStatus.badRequest,
        'Expected a JSON object',
      );
      return null;
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<String?> _readBody(HttpRequest request) async {
    final length = request.contentLength;
    if (length > _maxBodyBytes) {
      await _writeError(
        request.response,
        HttpStatus.requestEntityTooLarge,
        'Body exceeds 32 MB',
      );
      return null;
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > _maxBodyBytes) {
        await _writeError(
          request.response,
          HttpStatus.requestEntityTooLarge,
          'Body exceeds 32 MB',
        );
        return null;
      }
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Future<void> _writeJson(
    HttpResponse response,
    Object? value, {
    int statusCode = HttpStatus.ok,
  }) async {
    response.statusCode = statusCode;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    response.write(const JsonEncoder.withIndent('  ').convert(value));
    await response.close();
  }

  Future<void> _writeError(
    HttpResponse response,
    int statusCode,
    String message,
  ) {
    return _writeJson(
      response,
      {'ok': false, 'error': message},
      statusCode: statusCode,
    );
  }

  Future<void> _writeHtml(HttpResponse response, String html) async {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    response.write(html);
    await response.close();
  }

  void _applyCors(HttpResponse response) {
    response.headers.set('access-control-allow-origin', '*');
    response.headers.set(
      'access-control-allow-headers',
      'authorization, content-type, mcp-session-id, x-ota-token',
    );
    response.headers.set(
      'access-control-allow-methods',
      'GET, POST, DELETE, OPTIONS',
    );
  }

  int _pendingCount(Map<String, dynamic> status) {
    final actions = status['actions'];
    return actions is Map ? readInt(actions, ['pending']) : 0;
  }

  String _newSessionId(String prefix) {
    final random = Random.secure();
    final bytes = List<int>.generate(12, (_) => random.nextInt(256));
    return '${prefix}_${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  String _landingPage() {
    return '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OTA Counter Sync</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         max-width: 720px; margin: 48px auto; padding: 0 20px; }
  h1 { font-size: 26px; margin-bottom: 4px; }
  p, li { color: #666; }
  code { background: #f2f2f7; padding: 2px 6px; border-radius: 6px; }
  .card { border: 1px solid #ddd; border-radius: 16px; padding: 18px 20px; margin: 18px 0; }
  @media (prefers-color-scheme: dark) {
    body { background: #121018; color: #f2eff8; }
    p, li { color: #c9c1da; }
    code { background: #272232; }
    .card { border-color: #3b3449; }
  }
</style>
</head>
<body>
<h1>OTA Counter Sync</h1>
<p>Local bridge for the OTA Counter Flutter app, MCP clients, and Grok / Hermes bots.</p>
<div class="card">
  <strong>MCP endpoints</strong>
  <ul>
    <li>Streamable HTTP: <code>POST /mcp</code></li>
    <li>Legacy SSE: <code>GET /sse</code> + <code>POST /messages?sessionId=…</code></li>
    <li>REST: <code>/api/v1/status</code>, <code>/api/v1/snapshot</code>, <code>/api/v1/actions</code></li>
  </ul>
  <p>All private endpoints require <code>Authorization: Bearer &lt;token&gt;</code>.</p>
</div>
<p>Token file: <code>~/.ota_counter_sync/token</code> (or the directory passed with <code>--data-dir</code>).</p>
</body>
</html>''';
  }
}

class _SseSession {
  _SseSession(this.id, this.controller);

  final String id;
  final StreamController<String> controller;
  Timer? heartbeat;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    heartbeat?.cancel();
    heartbeat = null;
    if (!controller.isClosed) {
      await controller.close();
    }
  }
}

String readString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String) return value;
  }
  return '';
}

int readInt(Map<dynamic, dynamic> map, List<String> keys, [int fallback = 0]) {
  for (final key in keys) {
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
  }
  return fallback;
}
