// ignore_for_file: avoid_relative_lib_imports
//
// Checks the attach_cheki_photos / record_cheki images / list_cheki_photos
// MCP tools and their sync REST contract. Run with:
//
//   dart mcp_server/test/cheki_photos_test.dart
import 'dart:convert';
import 'dart:io';

import '../lib/http_transport.dart';
import '../lib/mcp_protocol.dart';
import '../lib/store.dart';

Future<void> main() async {
  var passed = 0;
  await testChekiPhotos((condition, label) {
    if (!condition) throw StateError('FAIL: $label');
    stdout.writeln('ok ${++passed} - $label');
  });
  stdout.writeln('All $passed cheki photo checks passed.');
}

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';

Future<void> testChekiPhotos(void Function(bool, String) check) async {
  final dir = await Directory.systemTemp.createTemp('ota_cheki_photo_test_');
  final store = SyncStore(dir.path);
  final protocol = McpProtocol(store);
  final server = SyncHttpServer(store: store, token: 'photo-token', port: 0);
  final client = HttpClient()..findProxy = (_) => 'DIRECT';
  await server.start();
  final base = 'http://127.0.0.1:${server.actualPort}';

  Future<Map<String, dynamic>> call(
      String name, Map<String, dynamic> arguments) async {
    final response = await protocol.handle({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }) as Map;
    return Map<String, dynamic>.from(response['result'] as Map);
  }

  String error(Map<String, dynamic> result) =>
      ((result['content'] as List).first as Map)['text'].toString();
  Map<String, dynamic> ok(Map<String, dynamic> result) =>
      Map<String, dynamic>.from(result['structuredContent'] as Map);

  Future<(int, Map<String, dynamic>)> rest(String method, String path,
      {Object? body, String? capabilities}) async {
    final request = await client.openUrl(method, Uri.parse('$base$path'));
    request.headers.set('authorization', 'Bearer photo-token');
    if (capabilities != null) {
      request.headers.set(kCapabilitiesHeader, capabilities);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    if (response.headers.contentType?.mimeType != 'application/json') {
      await response.drain<void>();
      return (response.statusCode, <String, dynamic>{});
    }
    final text = await response.transform(utf8.decoder).join();
    return (
      response.statusCode,
      text.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(text) as Map)
    );
  }

  Future<int> stagedFiles() async => (await store.faceImages.directory.exists())
      ? await store.faceImages.directory
          .list()
          .where((e) => e is File && !e.path.endsWith('.json'))
          .length
      : 0;

  try {
    final tools = await protocol
        .handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}) as Map;
    final names = [
      for (final tool in (tools['result'] as Map)['tools'] as List)
        (tool as Map)['name']
    ];
    check(names.contains('attach_cheki_photos'),
        'tools/list exposes attach_cheki_photos');
    check(names.contains('list_cheki_photos'),
        'tools/list exposes list_cheki_photos');
    final recordTool = ((tools['result'] as Map)['tools'] as List)
        .cast<Map>()
        .singleWhere((tool) => tool['name'] == 'record_cheki');
    check(
        ((recordTool['inputSchema'] as Map)['properties'] as Map)
            .containsKey('images'),
        'record_cheki accepts images');

    await store.replaceSnapshot({
      'schema': 'ota-counter-snapshot',
      'counters': [
        {
          'id': 1,
          'name': '兔兔Miottie',
          'group_name': 'ReCream',
          'person_id': 11,
          'person_name': '兔兔Miottie',
          'threeInchCount': 3,
        },
        {
          'id': 2,
          'name': '小羽',
          'group_name': '起源',
          'threeInchCount': 1,
        },
      ],
      'records': [
        {
          'id': 70,
          'record_type': 'counter',
          'counter_id': 1,
          'subject_name': '兔兔Miottie',
          'group_name': 'ReCream',
          'occurred_at': '2026-11-19T00:00:00.000',
        },
        {
          'id': 71,
          'record_type': 'ticket',
          'subject_name': '某公演',
          'occurred_at': '2026-11-19T00:00:00.000',
        },
      ],
    });

    final noImage = await call(
        'attach_cheki_photos', {'member_id': 1, 'occurred_at': '2026-11-19'});
    check(noImage['isError'] == true && error(noImage).contains('至少提供一张'),
        'attach without images is rejected in Chinese');
    final noDate = await call('attach_cheki_photos', {
      'member_id': 1,
      'images': [
        {'image_base64': _png}
      ]
    });
    check(noDate['isError'] == true && error(noDate).contains('occurred_at'),
        'attach without date or record is rejected');
    final badImage = await call('attach_cheki_photos', {
      'member_id': 1,
      'occurred_at': '2026-11-19',
      'images': [
        {'image_base64': _png},
        {'image_base64': base64Encode(utf8.encode('not an image'))},
      ]
    });
    check(
        badImage['isError'] == true &&
            error(badImage).contains('第 2 张') &&
            await stagedFiles() == 0,
        'a bad second image rejects the call and stages nothing');
    final ticket = await call('attach_cheki_photos', {
      'record_id': 71,
      'images': [
        {'image_base64': _png}
      ]
    });
    check(ticket['isError'] == true && error(ticket).contains('门票'),
        'ticket record ids are rejected');
    final unknownRecord = await call('attach_cheki_photos', {
      'record_id': 999,
      'images': [_png]
    });
    check(
        unknownRecord['isError'] == true &&
            error(unknownRecord).contains('不在最新快照'),
        'unknown record ids are rejected');
    final tooMany = await call('attach_cheki_photos', {
      'member_id': 1,
      'occurred_at': '2026-11-19',
      'images': List.filled(21, _png),
    });
    check(tooMany['isError'] == true && error(tooMany).contains('最多 20'),
        'more than 20 images are rejected');

    final attached = ok(await call('attach_cheki_photos', {
      'name': '兔兔',
      'group': 'ReCream',
      'occurred_at': '2026-11-19',
      'activity_name': '周四公演',
      'images': [
        {'image_base64': 'data:image/png;base64,$_png'},
        _png,
      ],
    }));
    check(
        attached['status'] == 'pending' &&
            attached['kind'] == kChekiPhotoActionKind &&
            attached['image_count'] == 2 &&
            await stagedFiles() == 2,
        'attach_cheki_photos stages two images and queues one action');
    final pending = ok(await call('list_pending_actions', {}));
    final queuedAction = (pending['actions'] as List)
        .cast<Map>()
        .singleWhere((a) => a['id'] == attached['action_id']);
    final queuedPayload = queuedAction['payload'] as Map;
    check(
        queuedPayload['counter_id'] == 1 &&
            queuedPayload['activity_name'] == '周四公演' &&
            (queuedPayload['images'] as List).length == 2 &&
            !jsonEncode(queuedAction).contains(_png),
        'list_pending_actions shows the photo action without image bytes');

    final withCount = ok(await call('record_cheki', {
      'member_id': 2,
      'three_inch': 1,
      'occurred_at': '2026-11-19',
      'images': [
        {'image_base64': _png}
      ],
    }));
    check(
        withCount['kind'] == 'counter_delta' &&
            withCount['photo_action_id'] is String &&
            withCount['image_count'] == 1,
        'record_cheki with images queues the count and the photo');
    final photos = ok(await call('list_cheki_photos', {'status': 'pending'}));
    final linked = (photos['attachments'] as List)
        .cast<Map>()
        .singleWhere((a) => a['id'] == withCount['photo_action_id']);
    check(linked['record_action_id'] == withCount['action_id'],
        'the photo is linked to the queued counter_delta');

    final hinted = ok(await call('attach_cheki_photos', {
      'member_id': 2,
      'occurred_at': '2026-11-19T21:00:00',
      'images': [_png],
    }));
    check(hinted['record_action_hint'] == withCount['action_id'],
        'a separate attach falls back to the same-day pending record_cheki');

    final badLink = await call('attach_cheki_photos', {
      'member_id': 2,
      'record_action_id': 'act_missing',
      'images': [_png],
    });
    check(
        badLink['isError'] == true &&
            error(badLink).contains('record_action_id') &&
            await stagedFiles() == 4,
        'unknown record_action_id is rejected and its image removed');

    final (_, oldApp) = await rest('GET', '/api/v1/actions?status=pending',
        capabilities: 'face-enroll-v1');
    check(
        !(oldApp['actions'] as List)
            .cast<Map>()
            .any((a) => a['kind'] == kChekiPhotoActionKind),
        'apps without cheki-photo-v1 never receive photo actions');
    final (_, newApp) = await rest('GET', '/api/v1/actions?status=pending',
        capabilities: 'face-enroll-v1,cheki-photo-v1');
    check(
        (newApp['actions'] as List)
                .cast<Map>()
                .where((a) => a['kind'] == kChekiPhotoActionKind)
                .length ==
            3,
        'apps with cheki-photo-v1 receive every photo action');

    final firstImage = (queuedPayload['images'] as List).first as Map;
    final (imageStatus, _) =
        await rest('GET', '/api/v1/face-images/${firstImage['imageId']}');
    check(imageStatus == 200, 'the app can download a staged photo');

    final (blankStatus, _) = await rest('POST', '/api/v1/actions/ack', body: {
      'ids': [attached['action_id']],
      'failures': {attached['action_id']: ' '},
    });
    check(blankStatus >= 400, 'a failed photo receipt needs a reason');

    final (ackStatus, ack) = await rest('POST', '/api/v1/actions/ack', body: {
      'ids': [attached['action_id'], hinted['action_id']],
      'failures': {hinted['action_id']: '找不到「小羽」在 2026-11-19 的切奇流水，照片未挂'},
      'results': {
        attached['action_id']: {
          'record_id': 70,
          'photos_saved': 1,
          'duplicates': 1,
        }
      },
    });
    check(ackStatus == 200 && ack['applied'] == 1 && ack['failed'] == 1,
        'ack records one applied and one failed photo action');
    check(await stagedFiles() == 1,
        'acknowledged photo actions delete their staged images');
    final applied = ok(await call('list_cheki_photos', {'status': 'applied'}));
    final appliedView = (applied['attachments'] as List).single as Map;
    check(
        appliedView['attached_record_id'] == 70 &&
            appliedView['photos_saved'] == 1 &&
            appliedView['duplicates'] == 1,
        'list_cheki_photos reports where the photos went');
    final failed = ok(await call('list_cheki_photos', {'status': 'failed'}));
    check(
        ((failed['attachments'] as List).single as Map)['failure']
            .toString()
            .contains('找不到'),
        'list_cheki_photos reports the Chinese failure reason');

    final (restStatus, _) = await rest('POST', '/api/v1/actions', body: {
      'kind': kChekiPhotoActionKind,
      'payload': {
        'images': [
          {'imageId': 'x'}
        ]
      },
    });
    check(restStatus >= 400,
        'photo actions cannot be forged through POST /api/v1/actions');
  } finally {
    client.close(force: true);
    await server.close();
    await dir.delete(recursive: true);
  }
}
