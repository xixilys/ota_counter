// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/face_images.dart';
import '../lib/http_transport.dart';
import '../lib/mcp_protocol.dart';
import '../lib/store.dart';

Future<void> main() async {
  var passed = 0;
  await testFaceEnrollment((condition, label) {
    if (!condition) throw StateError('FAIL: $label');
    stdout.writeln('ok ${++passed} - $label');
  });
  stdout.writeln('All $passed face enrollment checks passed.');
}

Future<void> testFaceEnrollment(void Function(bool, String) check) async {
  final dir = await Directory.systemTemp.createTemp('ota_face_test_');
  final store =
      SyncStore(dir.path, publicBaseUrl: 'https://example.test/ota-sync/');
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  final server =
      SyncHttpServer(store: store, token: 'synthetic-face-token', port: 0);
  final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final fixtureClient = HttpClient()..findProxy = (_) => 'DIRECT';
  final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==');
  const publicFixtureHost = '8.8.8.8';
  fixture.listen((request) async {
    final response = request.response;
    response.headers.contentType = ContentType('image', 'png');
    switch (request.uri.path) {
      case '/text':
        response.headers.contentType = ContentType.text;
        response.write('not an image');
      case '/large':
        response.contentLength = maxFaceImageBytes + 1;
      case '/redirect':
        response.statusCode = 302;
        response.headers.set('location', '/image');
      case '/private-redirect':
        response.statusCode = 302;
        response.headers
            .set('location', 'http://127.0.0.1:${fixture.port}/image');
      case '/unsafe-redirect':
        response.statusCode = 302;
        response.headers.set('location', 'file:///etc/passwd');
      case '/loop':
        response.statusCode = 302;
        response.headers.set('location', '/loop');
      case '/missing':
        response.statusCode = 404;
      case '/slow':
        await Future<void>.delayed(const Duration(seconds: 21));
      default:
        response.add(png);
    }
    try {
      await response.close();
    } catch (_) {/* Client rejected early. */}
  });
  Future<Map> call(String name,
      [Map<String, dynamic> arguments = const {}]) async {
    final response = await McpProtocol(store).handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments}
    }) as Map;
    return response['result'] as Map;
  }

  Future<_Reply> request(String method, String path,
      {String? token,
      Object? body,
      List<int>? bytes,
      String mime = 'image/png',
      bool queryToken = false,
      Map<String, String> headers = const {}}) async {
    final uri = Uri.parse('http://127.0.0.1:${server.actualPort}$path');
    final req = await client.openUrl(
        method,
        queryToken
            ? uri.replace(
                queryParameters: {...uri.queryParameters, 'token': token!})
            : uri);
    if (token != null && !queryToken) {
      req.headers.set('authorization', 'Bearer $token');
    }
    for (final entry in headers.entries) {
      req.headers.set(entry.key, entry.value);
    }
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    if (bytes != null) {
      req.headers.set('content-type', mime);
      req.add(bytes);
    }
    final response = await req.close();
    return _Reply(
        response.statusCode,
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
        response.headers);
  }

  Map content(Map result) => result['structuredContent'] as Map;
  String error(Map result) => result['content'][0]['text'] as String;
  Map validResult(
          {int facesFound = 1,
          int? usedFace = 1,
          int samplesKept = 1,
          List<dynamic> faces = const []}) =>
      {
        'faces_found': facesFound,
        'used_face': usedFace,
        'samples_kept': samplesKept,
        'faces': faces,
      };
  try {
    await server.start();
    await _testCli(dir.path, check);
    await _testAckFailures(dir.path, check);
    final empty = await call('create_face_upload_link', {'member': '合成'});
    check(empty['isError'] == true && error(empty).contains('No snapshot'),
        'face enrollment requires a snapshot');
    final snapshot = {
      'counters': [
        {
          'id': 1,
          'name': '合成成员',
          'group_name': '甲团',
          'person_id': 7,
          'person_name': '合成成员',
          'total_count': 10
        },
        {'id': 2, 'name': '合成成员', 'group_name': '乙团', 'total_count': 1},
        {'id': 3, 'name': '另一成员', 'group_name': '甲团', 'total_count': 2},
        {
          'id': 4,
          'name': '合成别名',
          'group_name': '丙团',
          'person_id': 7,
          'person_name': '合成成员',
          'total_count': 1
        },
      ]
    };
    await store.replaceSnapshot(snapshot);
    final ambiguous = await call('create_face_upload_link', {'member': '合成成员'});
    check(
        ambiguous['isError'] == true &&
            error(ambiguous).contains('多位成员') &&
            error(ambiguous).contains('member_id'),
        'ambiguous face target lists candidates and asks for member/group or member_id');
    final missing = await call('create_face_upload_link', {'member': '不存在'});
    check(missing['isError'] == true && error(missing).contains('可用成员'),
        'unknown member lists available candidates');
    check(
        (await call(
                'create_face_upload_link', {'member_id': 999}))['isError'] ==
            true,
        'unknown member_id rejected');
    final byId =
        content(await call('create_face_upload_link', {'member_id': '4'}));
    check(
        byId['member']['counter_id'] == 4 &&
            byId['member']['member_name'] == '合成别名' &&
            byId['member']['group_name'] == '丙团',
        'create link accepts member_id and keeps the requested affiliation');
    check(
        (await call('create_face_upload_link',
                {'member_id': 2, 'group': '甲团'}))['isError'] ==
            true,
        'member_id and mismatched group rejected');
    check(
        (await call('create_face_upload_link',
                {'member': '合成成员', 'group': '不存在'}))['isError'] ==
            true,
        'wrong group rejected');
    check(
        (await call('create_face_upload_link', {'group': '甲团'}))['isError'] ==
            true,
        'missing identity rejected');
    final noBase = McpProtocol(SyncStore('${dir.path}/no-base'));
    await noBase.store.replaceSnapshot(snapshot);
    final missingBase = await noBase.handle({
      'id': 1,
      'method': 'tools/call',
      'params': {
        'name': 'create_face_upload_link',
        'arguments': {'member': '另一成员'}
      }
    }) as Map;
    check(
        missingBase['result']['isError'] == true &&
            missingBase['result']['content'][0]['text']
                .contains('OTA_SYNC_PUBLIC_BASE_URL'),
        'missing public base is explicit, never guessed from request headers');
    final link = content(await call(
        'create_face_upload_link', {'member': '合成成员', 'group': '甲团'}));
    final httpTool = await request('POST', '/mcp',
        token: 'synthetic-face-token',
        queryToken: true,
        body: {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {
            'name': 'create_face_upload_link',
            'arguments': {'member_id': 3}
          }
        });
    check(
        httpTool.status == 200 &&
            (jsonDecode(utf8.decode(httpTool.bytes)) as Map)['result']
                    ['structuredContent']['max_images'] ==
                10,
        'HTTP MCP query-token client can create scoped face upload links');
    final url = Uri.parse(link['url'] as String);
    final secret = url.queryParameters['token']!;
    check(
        url.scheme == 'https' &&
            url.host == 'example.test' &&
            url.path == '/ota-sync/face-upload',
        'public base preserves HTTPS and stripped proxy prefix');
    check(
        secret.length == 43 &&
            link['max_images'] == 10 &&
            secret != 'synthetic-face-token',
        'upload capability is independent random 256-bit token');
    final expiry =
        DateTime.parse(link['expires_at'] as String).difference(DateTime.now());
    check(expiry.inSeconds >= 86390 && expiry.inHours <= 24,
        'link expires in 24 hours');
    final second =
        content(await call('create_face_upload_link', {'member': '另一成员'}));
    check(Uri.parse(second['url']).queryParameters['token'] != secret,
        'separate links have distinct random capabilities');
    final reloaded = SyncStore(dir.path, publicBaseUrl: store.publicBaseUrl);
    check((await reloaded.faceUploadLink(secret))['target']['person_id'] == 7,
        'upload link and resolved identity persist after restart');
    check((await request('GET', '/face-upload')).status == 401,
        'upload page rejects missing capability');
    check(
        (await request('GET', '/face-upload', token: 'synthetic-face-token'))
                .status ==
            401,
        'sync bearer cannot substitute for scoped upload capability');
    final page = await request('GET', '/face-upload?token=$secret');
    final html = utf8.decode(page.bytes);
    check(page.status == 200 && html.contains('合成成员') && html.contains('甲团'),
        'query-token client form serves correct Chinese member');
    check(
        page.headers.value('referrer-policy') == 'no-referrer' &&
            page.headers.value('cache-control') == 'no-store' &&
            !html.contains(secret) &&
            !html.contains('synthetic-face-token'),
        'upload HTML does not embed tokens and suppresses cache/referrer');
    check(
        html.contains('1600') &&
            html.contains("'image/jpeg', 0.9") &&
            html.contains('files.length > 10') &&
            html.contains('location.pathname'),
        'client canvas quality, dimension, selection limit and relative prefixed POST are present');
    check(html.contains('1.5 倍') && !html.contains('使用最大的人脸'),
        'page describes agreed multi-face selection policy');
    check((await request('GET', '/api/v1/status', token: secret)).status == 401,
        'upload capability cannot access private sync APIs');
    check(
        (await request('POST', '/face-upload',
                    token: secret, bytes: png, mime: 'text/plain'))
                .status ==
            415,
        'upload rejects non-image Content-Type');
    check(
        (await request('POST', '/face-upload',
                    token: secret, bytes: png, mime: 'image/svg+xml'))
                .status ==
            415,
        'upload rejects active SVG content');
    check(
        (await request('POST', '/face-upload', token: secret, bytes: []))
                .status ==
            400,
        'upload rejects empty image');
    final tooLarge = await request('POST', '/face-upload',
        token: secret, bytes: List.filled(maxFaceImageBytes + 1, 0));
    check(tooLarge.status == 413, 'HTTP upload enforces streamed 15 MB limit');
    final uploaded =
        await request('POST', '/face-upload', token: secret, bytes: png);
    final successId =
        (jsonDecode(utf8.decode(uploaded.bytes)) as Map)['action_id'] as String;
    check(uploaded.status == 201, 'bearer-capability upload queues image');
    final uploaded2 = await request('POST', '/face-upload',
        token: secret, queryToken: true, bytes: png);
    final failedId = (jsonDecode(utf8.decode(uploaded2.bytes))
        as Map)['action_id'] as String;
    check(
        uploaded2.status == 201, 'query-token upload client remains supported');
    final pending = await store.faceEnrollments();
    final payload =
        pending.firstWhere((a) => a['id'] == successId)['payload'] as Map;
    final imageId = payload['imageId'] as String;
    final failedImageId = pending
        .firstWhere((a) => a['id'] == failedId)['payload']['imageId'] as String;
    check(
        payload['counter_id'] == 1 &&
            payload['person_id'] == 7 &&
            payload['person_name'] == '合成成员' &&
            payload['member_name'] == '合成成员' &&
            payload['group_name'] == '甲团' &&
            payload['source'] == 'upload' &&
            payload['face'] == 'auto',
        'enroll_face payload matches app contract');
    check(
        await store.faceImages.file(imageId).exists() &&
            !(await store.stateFile.readAsString()).contains(base64Encode(png)),
        'image bytes persist separately, not in state JSON');
    check((await request('GET', '/api/v1/face-images/$imageId')).status == 401,
        'image download requires auth');
    check(
        (await request('GET', '/api/v1/face-images/$imageId', token: secret))
                .status ==
            401,
        'upload capability cannot download image');
    check(
        (await request('GET', '/api/v1/face-images/$imageId',
                    token: 'synthetic-face-token', queryToken: true))
                .status ==
            401,
        'image endpoint requires bearer header, not query token');
    final image = await request('GET', '/api/v1/face-images/$imageId',
        token: 'synthetic-face-token');
    check(
        image.status == 200 &&
            base64Encode(image.bytes) == base64Encode(png) &&
            image.headers.contentType?.mimeType == 'image/png',
        'authenticated download returns original synthetic bytes and MIME');
    check(
        (await request('GET', '/api/v1/face-images/invalid',
                    token: 'synthetic-face-token'))
                .status ==
            404,
        'malformed image id cannot traverse filesystem');

    // image_base64: exact-one argument, data prefix, JPEG/PNG magic and limit.
    check(
        (await call('enroll_face', {'member_id': 1}))['isError'] == true &&
            error(await call('enroll_face', {'member_id': 1}))
                .contains('只能有一个'),
        'enroll_face requires exactly one image argument');
    check(
        (await call('enroll_face', {
              'member_id': 1,
              'image_url': 'https://example.test/x.png',
              'image_base64': base64Encode(png)
            }))['isError'] ==
            true,
        'enroll_face rejects both image_url and image_base64');
    final b64Queued = content(await call('enroll_face', {
      'member_id': '3',
      'image_base64': base64Encode(png),
      'face': 'left_1'
    }));
    check(
        b64Queued['status'] == 'pending' &&
            b64Queued['enrollment_id'] is String &&
            b64Queued['face'] == 'left_1',
        'enroll_face queues base64 PNG with enrollment_id and face selector');
    final b64Payload = (await store.faceEnrollments())
            .firstWhere((a) => a['id'] == b64Queued['enrollment_id'])['payload']
        as Map;
    check(
        b64Payload['source'] == 'base64' &&
            b64Payload['face'] == 'left_1' &&
            b64Payload['counter_id'] == 3,
        'base64 payload records source, selector and resolved member');
    final prefixed = content(await call('enroll_face', {
      'member': '另一成员',
      'group': '甲团',
      'image_base64': 'data:image/png;base64,${base64Encode(png)}'
    }));
    check(prefixed['status'] == 'pending',
        'enroll_face accepts optional data:image/png prefix');
    for (final invalid in [
      'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==',
      'not-base64!!!',
      base64Encode([1, 2, 3]),
    ]) {
      check(
          (await call('enroll_face',
                  {'member_id': 1, 'image_base64': invalid}))['isError'] ==
              true,
          'invalid base64 image rejected: ${invalid.substring(0, invalid.length > 20 ? 20 : invalid.length)}');
    }
    check(
        (await call('enroll_face', {
              'member_id': 1,
              'image_base64':
                  List.filled(maxFaceBase64EncodedBytes + 1, 'A').join()
            }))['isError'] ==
            true,
        'base64 encoded payload over 8 MB rejected');
    check(
        (await call('enroll_face', {
              'member_id': 1,
              'image_url': 'https://example.test/a.png',
              'face': 'left_0'
            }))['isError'] ==
            true,
        'invalid face selector rejected');
    check(
        (await call('enroll_face_from_url', {'member': '另一成员'}))['isError'] ==
            true,
        'renamed tool no longer accepts the old name');

    final invalidAck = await request('POST', '/api/v1/actions/ack',
        token: 'synthetic-face-token',
        headers: {
          kCapabilitiesHeader: kFaceEnrollmentCapability
        },
        body: {
          'ids': [successId]
        });
    check(
        invalidAck.status == 400 &&
            await store.faceImages.file(imageId).exists(),
        'malformed enrollment success receipt is rejected before mutation or deletion');
    check(
        (await request('POST', '/api/v1/actions/ack',
                    token: 'synthetic-face-token',
                    headers: {
                  kCapabilitiesHeader: kFaceEnrollmentCapability
                },
                    body: {
                  'ids': [failedId],
                  'failures': {failedId: '未检测到人脸'},
                  'results': {
                    failedId: {
                      'faces_found': 0,
                      'used_face': null,
                      'samples_kept': 0,
                    }
                  }
                }))
                .status ==
            400,
        'failed enrollment without faces detail is rejected');
    final manual = await request('POST', '/api/v1/actions',
        token: 'synthetic-face-token',
        body: {'kind': 'enroll_face', 'payload': {}});
    check(manual.status == 400,
        'generic action API cannot create malformed enrollment image references');
    check(
        content(await call('list_face_enrollments', {'group': '乙团'}))[
                'count'] ==
            0,
        'group-only enrollment query is filtered before pagination');
    final faces = [
      {
        'index_from_left': 1,
        'box': {'x': 0.1, 'y': 0.2, 'width': 0.3, 'height': 0.4}
      },
      {
        'index_from_left': 2,
        'box': {'x': 0.5, 'y': 0.2, 'width': 0.2, 'height': 0.3}
      }
    ];
    final ack = await request('POST', '/api/v1/actions/ack',
        token: 'synthetic-face-token',
        headers: {
          kCapabilitiesHeader: kFaceEnrollmentCapability
        },
        body: {
          'ids': [successId, failedId],
          'failures': {failedId: '照片里有多张脸，无法判断是谁'},
          'results': {
            successId: validResult(facesFound: 2, samplesKept: 0),
            failedId: validResult(
                facesFound: 2, usedFace: null, samplesKept: 0, faces: faces),
          }
        });
    final ackJson = jsonDecode(utf8.decode(ack.bytes)) as Map;
    check(ackJson['applied'] == 1 && ackJson['failed'] == 1,
        'ack counts enrollment successes and failures once');
    check(
        !await store.faceImages.file(imageId).exists() &&
            !await store.faceImages.file(failedImageId).exists(),
        'successful and failed images both deleted on ack');
    check(
        (await request('GET', '/api/v1/face-images/$imageId',
                    token: 'synthetic-face-token'))
                .status ==
            404,
        'acknowledged image is no longer downloadable');
    final results = content(await call('list_face_enrollments',
        {'member': '合成成员', 'group': '甲团'}))['enrollments'] as List;
    final appliedView = results.firstWhere((a) => a['id'] == successId) as Map;
    final failedView = results.firstWhere((a) => a['id'] == failedId) as Map;
    check(
        appliedView['faces_found'] == 2 &&
            appliedView['used_face'] == 1 &&
            appliedView['samples_kept'] == 0 &&
            appliedView['result']['used_face_bounds'] == null,
        'MCP query exposes flattened success summary including samples_kept=0');
    check(
        failedView['failure'] == '照片里有多张脸，无法判断是谁' &&
            failedView['faces_found'] == 2 &&
            failedView['used_face'] == null &&
            (failedView['faces'] as List).length == 2 &&
            (failedView['faces'] as List).first['index_from_left'] == 1 &&
            (failedView['faces'] as List).first['box']['width'] == 0.3,
        'MCP query exposes Chinese failure plus normalized faces for left_N retry');
    check(
        content(await call('list_face_enrollments', {'status': 'failed'}))[
                'count'] ==
            1,
        'result query status filter works');
    check(
        (await call(
                'list_face_enrollments', {'status': 'invalid'}))['isError'] ==
            true,
        'result query rejects unknown status');
    final repeated = await store
        .acknowledgeActions([successId, failedId], failures: {failedId: '重复'});
    check(repeated['applied'] == 0 && repeated['failed'] == 0,
        'enrollment ack is idempotent');
    check(
        (await SyncStore(dir.path).faceEnrollments(status: 'applied'))
                .first['result']['faces_found'] ==
            2,
        'enrollment result persists after restart');

    // Backward compatibility: v1.6.0 clients never see enroll_face actions.
    final hidden = content(await call(
        'enroll_face', {'member_id': 1, 'image_base64': base64Encode(png)}));
    final hiddenId = hidden['enrollment_id'] as String;
    final legacyActions = jsonDecode(utf8.decode((await request(
            'GET', '/api/v1/actions?status=pending&limit=200',
            token: 'synthetic-face-token'))
        .bytes)) as Map;
    check(
        (legacyActions['actions'] as List)
                .every((a) => a['kind'] != 'enroll_face') &&
            (legacyActions['actions'] as List)
                .every((a) => a['id'] != hiddenId),
        'client without capability header is held back from enroll_face actions');
    final capableActions = jsonDecode(utf8.decode((await request(
            'GET', '/api/v1/actions?status=pending&limit=200',
            token: 'synthetic-face-token',
            headers: {kCapabilitiesHeader: kFaceEnrollmentCapability}))
        .bytes)) as Map;
    check(
        (capableActions['actions'] as List)
            .any((a) => a['id'] == hiddenId && a['kind'] == 'enroll_face'),
        'capability header exposes enroll_face actions');
    final legacyAck = await request('POST', '/api/v1/actions/ack',
        token: 'synthetic-face-token',
        body: {
          'ids': [hiddenId]
        });
    check(
        legacyAck.status == 409 &&
            await store.faceImages
                .file((await store.faceEnrollments())
                        .firstWhere((a) => a['id'] == hiddenId)['payload']
                    ['imageId'])
                .exists(),
        'legacy client cannot ACK a face action or delete its image');
    final capableAck = await request('POST', '/api/v1/actions/ack',
        token: 'synthetic-face-token',
        headers: {
          kCapabilitiesHeader: kFaceEnrollmentCapability
        },
        body: {
          'ids': [hiddenId],
          'results': {hiddenId: validResult()}
        });
    check(capableAck.status == 200,
        'capability client can complete a face action');

    final counters = snapshot['counters'] as List;
    counters.first['total_count'] = 0;
    counters.last['total_count'] = 100;
    await store.replaceSnapshot(snapshot);
    final history =
        content(await call('list_face_enrollments', {'member_id': 1}));
    check((history['enrollments'] as List).any((a) => a['id'] == successId),
        'enrollment history survives counter ranking and member_id query');
    final byMemberId =
        content(await call('list_face_enrollments', {'member_id': 4}));
    check((byMemberId['enrollments'] as List).isNotEmpty,
        'member_id lookup includes person aliases');
    final old =
        content(await call('record_cheki', {'name': '合成成员', 'three_inch': 1}));
    check(old['status'] == 'pending',
        'legacy record_cheki fuzzy matching behavior remains unchanged');
    final oldAck = await store.acknowledgeActions([old['action_id']],
        failures: {old['action_id']: '旧路径失败'});
    check(oldAck['applied'] == 1 && oldAck['failed'] == 1,
        'legacy non-enrollment ack counting preserved');
    final ticket = content(await call('add_ticket',
        {'event_name': '合成公演', 'is_free': true, 'unit_price': 99}));
    check(ticket['is_free'] == true && ticket['unit_price'] == 0,
        'legacy free ticket behavior unchanged');
    final prompt = await McpProtocol(store).handle({
      'id': 1,
      'method': 'prompts/get',
      'params': {'name': 'enroll-member-face'}
    }) as Map;
    final promptText =
        prompt['result']['messages'][0]['content']['text'] as String;
    check(
        promptText.contains('member_id') &&
            promptText.contains('image_base64') &&
            promptText.contains('left_N') &&
            promptText.contains('samples_kept') &&
            promptText.contains('30'),
        'MCP prompt describes member_id/base64/left_N/30-sample flow');
    final tools = await McpProtocol(store)
        .handle({'id': 1, 'method': 'tools/list'}) as Map;
    final names = [
      for (final tool in tools['result']['tools'] as List) tool['name']
    ];
    check(
        names.toSet().containsAll([
              'create_face_upload_link',
              'enroll_face',
              'list_face_enrollments',
              'get_overview',
              'list_members',
              'get_member',
              'list_records',
              'list_groups',
              'record_cheki',
              'add_ticket',
              'list_pending_actions',
              'get_sync_status',
            ]) &&
            !names.contains('enroll_face_from_url'),
        'tools/list contains three face tools and all legacy tools');
    for (var i = 2; i < 10; i++) {
      check(
          (await request('POST', '/face-upload', token: secret, bytes: png))
                  .status ==
              201,
          'scoped link upload ${i + 1} succeeds');
    }
    check(
        (await request('POST', '/face-upload', token: secret, bytes: png))
                .status ==
            409,
        'link enforces cumulative ten images even after ack');
    final state = jsonDecode(await store.stateFile.readAsString())
        as Map<String, dynamic>;
    final secondSecret = Uri.parse(second['url']).queryParameters['token']!;
    state['face_upload_links'][secondSecret]['expires_at'] =
        DateTime.now().subtract(const Duration(seconds: 1)).toIso8601String();
    final expiredDir = Directory('${dir.path}/expired')..createSync();
    await File('${expiredDir.path}/state.json')
        .writeAsString(jsonEncode(state));
    var rejected = false;
    try {
      await SyncStore(expiredDir.path).faceUploadLink(secondSecret);
    } on FaceImageException catch (e) {
      rejected = e.status == 401;
    }
    check(rejected, 'expired 24h link rejected from persisted state');
    final stale = await store.faceImages.save(Stream.value(png), 'image/png');
    await store.faceImages
        .file(stale)
        .setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    check(
        await store.faceImages.sweep() == 1 &&
            !await store.faceImages.file(stale).exists(),
        '7-day sweep deletes old image and metadata');
    check(
        await store.faceImages.directory
            .list()
            .where((e) => e.path.endsWith('$stale.json'))
            .isEmpty,
        'sweep removes MIME sidecar');
    check(
        await store.faceImages
            .file((await store.faceEnrollments(status: 'pending'))
                .first['payload']['imageId'])
            .exists(),
        'sweep retains fresh pending images');
    for (final address in [
      '127.0.0.1',
      '10.0.0.1',
      '192.168.1.1',
      '169.254.169.254',
      '172.16.1.1',
      '100.64.0.1',
      '::1',
      'fc00::1',
      '::ffff:127.0.0.1'
    ]) {
      check(!isPublicFaceAddress(InternetAddress(address)),
          'external fetch blocks private address $address');
    }
    check(
        isPublicFaceAddress(InternetAddress('8.8.8.8')) &&
            isPublicFaceAddress(InternetAddress('2606:4700:4700::1111')),
        'external fetch accepts global unicast addresses');
    check(
        (await call('enroll_face', {
              'member_id': 3,
              'image_url': 'file:///etc/passwd'
            }))['isError'] ==
            true,
        'URL tool rejects non-HTTP URL');
    final internal = await call('enroll_face', {
      'member_id': 3,
      'image_url': 'http://127.0.0.1:${fixture.port}/image?secret=never-echo'
    });
    check(
        internal['isError'] == true && !error(internal).contains('never-echo'),
        'real connection policy blocks loopback and does not echo signed URL');
    // Route only this test-zone client to a synthetic local HTTP origin.
    // The production connection policy is independently exercised above.
    final overrides = _FixtureOverrides(fixtureClient, fixture.port);
    await HttpOverrides.runWithHttpOverrides(() async {
      final fetched = content(await call('enroll_face', {
        'member_id': 3,
        'image_url': 'http://$publicFixtureHost/image',
        'face': 'left_2'
      }));
      check(fetched['status'] == 'pending',
          'URL tool downloads synthetic HTTP image and queues enrollment');
      final action = (await store.faceEnrollments())
          .firstWhere((a) => a['id'] == fetched['enrollment_id']);
      check(
          action['payload']['source'] == 'url' &&
              action['payload']['face'] == 'left_2' &&
              await store.faceImages
                  .file(action['payload']['imageId'])
                  .exists(),
          'URL image persisted with source=url and selector');
    }, overrides);
    // Each fetch closes its client; use a fresh override for every subsequent request.
    for (final path in [
      '/text',
      '/large',
      '/unsafe-redirect',
      '/private-redirect',
      '/loop',
      '/missing',
      '/slow'
    ]) {
      final mock = HttpClient()..findProxy = (_) => 'DIRECT';
      final watch = Stopwatch()..start();
      final rejected = await HttpOverrides.runWithHttpOverrides(
          () => call('enroll_face', {
                'member_id': 3,
                'image_url':
                    'http://$publicFixtureHost$path?secret=not-for-output'
              }),
          _FixtureOverrides(mock, fixture.port));
      check(
          rejected['isError'] == true &&
              !error(rejected).contains('not-for-output'),
          'URL fetch rejects $path without leaking URL credentials');
      if (path == '/slow') {
        check(
            watch.elapsed.inSeconds >= 19 &&
                watch.elapsed.inSeconds < 23 &&
                error(rejected).contains('20 秒'),
            'external fetch has real 20-second overall timeout');
      }
    }
    final mock = HttpClient()..findProxy = (_) => 'DIRECT';
    final redirect = await HttpOverrides.runWithHttpOverrides(
        () => call('enroll_face', {
              'member_id': 3,
              'image_url': 'http://$publicFixtureHost/redirect'
            }),
        _FixtureOverrides(mock, fixture.port));
    check(redirect['isError'] == false,
        'URL fetch follows bounded safe HTTP redirects');
  } finally {
    client.close(force: true);
    fixtureClient.close(force: true);
    fixture.close(force: true);
    await server.close();
    await dir.delete(recursive: true);
  }
}

Future<void> _testAckFailures(
    String root, void Function(bool, String) check) async {
  var store = SyncStore('$root/ack-faults');
  const target = {
    'counter_id': 1,
    'person_id': null,
    'person_name': '合成成员',
    'member_name': '合成成员',
    'group_name': '合成团'
  };
  final image =
      await store.faceImages.save(Stream.value([1, 2, 3]), 'image/jpeg');
  final queued = await store.queueFaceEnrollment(target, image, 'upload');
  final id = queued['action_id'] as String;
  const okResult = {
    'faces_found': 1,
    'used_face': 1,
    'samples_kept': 1,
    'faces': <dynamic>[],
  };
  final blocker = Directory('${store.dataDir}/state.json.tmp')..createSync();
  var failed = false;
  try {
    await store.acknowledgeActions([id], results: {id: okResult});
  } on FileSystemException {
    failed = true;
  }
  check(
      failed &&
          await store.faceImages.file(image).exists() &&
          (await store.faceEnrollments()).single['status'] == 'pending' &&
          (await SyncStore(store.dataDir).faceEnrollments()).single['status'] ==
              'pending',
      'failed receipt persistence keeps pending state and image retryable in memory and on disk');
  await blocker.delete();
  if (!Platform.isWindows &&
      (await Process.run('id', ['-u'])).stdout.toString().trim() != '0') {
    await Process.run('chmod', ['500', store.faceImages.directory.path]);
    var deleteFailed = false;
    try {
      await store.acknowledgeActions([id], results: {id: okResult});
    } on FileSystemException {
      deleteFailed = true;
    } finally {
      await Process.run('chmod', ['700', store.faceImages.directory.path]);
    }
    check(
        deleteFailed &&
            await store.faceImages.file(image).exists() &&
            (await SyncStore(store.dataDir).faceEnrollments()).single['result']
                    ['used_face'] ==
                1,
        'image cleanup failure occurs only after receipt is durable');
    final state = jsonDecode(await store.stateFile.readAsString()) as Map;
    (state['actions'] as List).addAll([
      for (var i = 0; i < 500; i++)
        {'id': 'old-$i', 'kind': 'counter_delta', 'status': 'applied'},
      {'id': 'other-ack', 'kind': 'ticket', 'status': 'pending'},
    ]);
    await store.stateFile.writeAsString(jsonEncode(state));
    store = SyncStore(store.dataDir);
    await store.acknowledgeActions(['other-ack']);
    check(
        (await store.faceEnrollments()).any(
                (a) => a['id'] == id && a['image_cleanup_pending'] == true) &&
            await store.faceImages.file(image).exists(),
        'another ACK cannot prune an earlier enrollment with failed image cleanup');
    final retry = await store.acknowledgeActions([id]);
    check(retry['applied'] == 0 && !await store.faceImages.file(image).exists(),
        'duplicate ACK retries failed image cleanup without reapplying enrollment');
  } else {
    stdout.writeln(
        'skip - cleanup permission fault requires non-root POSIX user');
    await store.acknowledgeActions([id], results: {id: okResult});
  }
}

Future<void> _testCli(String root, void Function(bool, String) check) async {
  final dir = Directory('$root/cli')..createSync();
  const syntheticToken = 'synthetic-cli-log-secret';
  await File('${dir.path}/token').writeAsString(syntheticToken);
  await SyncStore(dir.path).replaceSnapshot({
    'counters': [
      {'id': 1, 'name': 'CLI合成成员', 'group_name': '合成团'}
    ]
  });
  final script = File('mcp_server/bin/ota_sync_server.dart').absolute.path;
  final input = jsonEncode({
    'id': 1,
    'method': 'tools/call',
    'params': {
      'name': 'create_face_upload_link',
      'arguments': {'member': 'CLI合成成员'}
    }
  });
  Future<Map> invoke(List<String> flags) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      script,
      'mcp',
      '--data-dir',
      dir.path,
      ...flags
    ], environment: {
      'OTA_SYNC_PUBLIC_BASE_URL': 'https://env.example/ota-sync',
      'OTA_SYNC_TOKEN': '',
    });
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.writeln(input);
    await process.stdin.close();
    final code = await process.exitCode;
    final text = await output;
    check(code == 0 && (await errors).isEmpty && !text.contains(syntheticToken),
        'stdio MCP emits only JSON and no sync credential');
    return (jsonDecode(text) as Map)['result']['structuredContent'] as Map;
  }

  final env = await invoke([]);
  check(Uri.parse(env['url']).host == 'env.example',
      'CLI reads OTA_SYNC_PUBLIC_BASE_URL');
  final cli =
      await invoke(['--public-base-url', 'https://cli.example/ota-sync/']);
  check(
      Uri.parse(cli['url']).host == 'cli.example' &&
          Uri.parse(cli['url']).path == '/ota-sync/face-upload',
      'CLI public base overrides environment and preserves prefix');
  final process = await Process.start(Platform.resolvedExecutable, [
    script,
    'serve',
    '--data-dir',
    dir.path,
    '--host',
    '127.0.0.1',
    '--port',
    '0'
  ], environment: {
    'OTA_SYNC_TOKEN': ''
  });
  final output = StringBuffer();
  final ready = Completer<void>();
  final subscription = process.stdout.transform(utf8.decoder).listen((chunk) {
    output.write(chunk);
    if (output.toString().contains('Press Ctrl+C') && !ready.isCompleted) {
      ready.complete();
    }
  });
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    await ready.future.timeout(const Duration(seconds: 10));
    check(
        !output.toString().contains(syntheticToken) &&
            !output.toString().contains('Token    :'),
        'real serve startup stdout never prints bearer token');
  } finally {
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await subscription.cancel();
    check(!(await errors).contains(syntheticToken),
        'real serve stderr never prints bearer token');
  }
}

class _Reply {
  _Reply(this.status, this.bytes, this.headers);
  final int status;
  final List<int> bytes;
  final HttpHeaders headers;
}

class _FixtureOverrides extends HttpOverrides {
  _FixtureOverrides(this.client, this.port);
  final HttpClient client;
  final int port;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FixtureClient(client, port);
}

class _FixtureClient implements HttpClient {
  _FixtureClient(this.client, this.port) {
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, port);
  }
  final HttpClient client;
  final int port;
  @override
  set findProxy(String Function(Uri)? value) {
    client.findProxy = value;
  }

  @override
  set connectionFactory(
      Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value) {
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        uri.host == '8.8.8.8'
            ? Socket.startConnect(InternetAddress.loopbackIPv4, port)
            : value!(uri, proxyHost, proxyPort);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => client.getUrl(url);
  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected HttpClient call');
}
