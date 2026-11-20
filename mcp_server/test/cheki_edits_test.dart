// ignore_for_file: avoid_relative_lib_imports
//
// Checks list_record_photos / delete_cheki_photo / replace_cheki_photo /
// edit_record / list_cheki_edits and their sync REST contract. Run with:
//
//   dart mcp_server/test/cheki_edits_test.dart
import 'dart:convert';
import 'dart:io';

import '../lib/http_transport.dart';
import '../lib/mcp_protocol.dart';
import '../lib/store.dart';

Future<void> main() async {
  var passed = 0;
  await testChekiEdits((condition, label) {
    if (!condition) throw StateError('FAIL: $label');
    stdout.writeln('ok ${++passed} - $label');
  });
  stdout.writeln('All $passed cheki edit checks passed.');
}

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';
const _caps = 'face-enroll-v1,cheki-photo-v1,cheki-edit-v1';

Future<void> testChekiEdits(void Function(bool, String) check) async {
  final dir = await Directory.systemTemp.createTemp('ota_cheki_edit_test_');
  final store = SyncStore(dir.path);
  final protocol = McpProtocol(store);
  final server = SyncHttpServer(store: store, token: 'edit-token', port: 0);
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
  Map<String, dynamic> ok(Map<String, dynamic> result) {
    if (result['isError'] == true) throw StateError(error(result));
    return Map<String, dynamic>.from(result['structuredContent'] as Map);
  }

  Future<(int, Map<String, dynamic>)> rest(String method, String path,
      {Object? body, String? capabilities}) async {
    final request = await client.openUrl(method, Uri.parse('$base$path'));
    request.headers.set('authorization', 'Bearer edit-token');
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

  final snapshot = {
    'schema': 'ota-counter-snapshot',
    'counters': [
      {'id': 1, 'name': '兔兔Miottie', 'group_name': 'ReCream'},
    ],
    'records': [
      {
        'id': 227,
        'record_type': 'counter',
        'counter_id': 1,
        'subject_name': '兔兔Miottie',
        'group_name': 'ReCream',
        'activity_name': '生诞祭',
        'note': '',
        'three_inch_count': 2,
        'five_inch_count': 0,
        'occurred_at': '2026-11-19T00:00:00.000',
      },
      {
        'id': 228,
        'record_type': 'ticket',
        'subject_name': '某公演',
        'occurred_at': '2026-11-19T00:00:00.000',
      },
      {
        'id': 229,
        'record_type': 'counter',
        'subject_name': '小羽',
        'group_name': '起源',
        'occurred_at': '2026-10-01T00:00:00.000',
      },
    ],
    'photos': [
      {'media_id': 900, 'record_id': 227, 'position': 1, 'sha1': 'aaa'},
      {'media_id': 901, 'record_id': 227, 'position': 2, 'sha1': 'bbb'},
      {'media_id': 950, 'record_id': 229, 'position': 1, 'sha1': 'ccc'},
    ],
  };

  try {
    final tools = await protocol
        .handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}) as Map;
    final names = {
      for (final tool in (tools['result'] as Map)['tools'] as List)
        (tool as Map)['name']
    };
    check(
        names.containsAll([
          'list_record_photos',
          'delete_cheki_photo',
          'replace_cheki_photo',
          'edit_record',
          'list_cheki_edits',
        ]),
        'tools/list exposes the five new tools');

    // An app older than 1.7.13 uploads no photo list.
    await store.replaceSnapshot({...snapshot}..remove('photos'));
    final old = await call('list_record_photos', {'record_id': 227});
    check(old['isError'] == true && error(old).contains('1.7.13'),
        'list_record_photos asks for App 1.7.13 when the snapshot has no photos');
    await store.replaceSnapshot(snapshot);

    final listed = ok(await call('list_record_photos', {'record_id': 227}));
    final photos = (listed['photos'] as List).cast<Map>();
    check(listed['count'] == 2 && photos.first['media_id'] == 900,
        'list_record_photos returns the record\'s photos in order');
    check(
        photos.last['position'] == 2 &&
            photos.last['sha1'] == 'bbb' &&
            (photos.last['record'] as Map)['subject'] == '兔兔Miottie',
        'each photo carries position, sha1 and its record');
    final byMember = ok(await call('list_record_photos', {'member': '小羽'}));
    check(byMember['count'] == 1 &&
        ((byMember['photos'] as List).single as Map)['media_id'] == 950,
        'list_record_photos filters by member');
    final unscoped = await call('list_record_photos', {});
    check(unscoped['isError'] == true, 'list_record_photos needs a scope');

    // delete_cheki_photo
    final missing = await call('delete_cheki_photo', {'media_id': 999});
    check(missing['isError'] == true && error(missing).contains('不在最新快照'),
        'deleting an unknown photo is refused');
    final wrongHash =
        await call('delete_cheki_photo', {'media_id': 900, 'sha1': 'zzz'});
    check(wrongHash['isError'] == true && error(wrongHash).contains('不一致'),
        'a sha1 mismatch is refused before queueing');
    final deleted = ok(await call('delete_cheki_photo', {'media_id': 900}));
    check(deleted['status'] == 'pending' &&
        (deleted['photo'] as Map)['position'] == 1,
        'delete_cheki_photo queues and echoes the photo');
    final twice = await call('delete_cheki_photo', {'media_id': 900});
    check(twice['isError'] == true && error(twice).contains('待同步'),
        'a second pending action on the same photo is refused');
    final relisted = ok(await call('list_record_photos', {'record_id': 227}));
    check(
        ((relisted['photos'] as List).first as Map)['pending_action_id'] ==
            deleted['action_id'],
        'list_record_photos marks photos with a pending action');

    // replace_cheki_photo
    final noImage = await call('replace_cheki_photo', {'media_id': 901});
    check(noImage['isError'] == true, 'replace needs a new image');
    final twoImages = await call('replace_cheki_photo', {
      'media_id': 901,
      'images': [_png, _png],
    });
    check(twoImages['isError'] == true && error(twoImages).contains('一张'),
        'replace takes exactly one image');
    check(await stagedFiles() == 0, 'refused replacements stage nothing');
    final replaced = ok(await call(
        'replace_cheki_photo', {'media_id': 901, 'image_base64': _png}));
    check(replaced['status'] == 'pending' && await stagedFiles() == 1,
        'replace_cheki_photo stages one image');
    final busy = await call(
        'replace_cheki_photo', {'media_id': 901, 'image_base64': _png});
    check(busy['isError'] == true && await stagedFiles() == 1,
        'a refused replacement removes its staged image');

    // edit_record
    final ticketCounts =
        await call('edit_record', {'record_id': 228, 'three_inch': 1});
    check(ticketCounts['isError'] == true && error(ticketCounts).contains('门票'),
        'counts on a ticket record are refused');
    final ticketNote =
        ok(await call('edit_record', {'record_id': 228, 'note': '前排'}));
    check(ticketNote['status'] == 'pending',
        'a ticket record\'s note can be edited');
    final negative =
        await call('edit_record', {'record_id': 227, 'three_inch': -1});
    check(negative['isError'] == true, 'negative counts are refused');
    final fractional =
        await call('edit_record', {'record_id': 227, 'five_inch': 1.5});
    check(fractional['isError'] == true, 'fractional counts are refused');
    final empty = await call('edit_record', {'record_id': 227});
    check(empty['isError'] == true && error(empty).contains('没有要改'),
        'an edit without fields is refused');
    final same =
        ok(await call('edit_record', {'record_id': 227, 'three_inch': 2}));
    check(same['status'] == 'unchanged' && same['action_id'] == null,
        'an edit to the current values queues nothing');
    final edited = ok(await call('edit_record', {
      'record_id': 227,
      'three_inch': 3,
      'five_inch': 0,
      'note': ' 补签一张 ',
    }));
    check(
        jsonEncode(edited['before']) == jsonEncode({'three_inch_count': 2, 'note': ''}) &&
            jsonEncode(edited['after']) ==
                jsonEncode({'three_inch_count': 3, 'note': '补签一张'}),
        'edit_record returns the old and new values of changed fields only');
    final overlap =
        await call('edit_record', {'record_id': 227, 'three_inch': 4});
    check(overlap['isError'] == true && error(overlap).contains('待同步'),
        'a second pending edit of the same field is refused');
    final otherField =
        ok(await call('edit_record', {'record_id': 227, 'venue_name': 'Livehouse'}));
    check(otherField['status'] == 'pending',
        'a pending edit of a different field is allowed');

    // REST: capability gating and receipts.
    final (_, legacy) = await rest('GET', '/api/v1/actions',
        capabilities: 'face-enroll-v1,cheki-photo-v1');
    check(legacy['count'] == 0,
        'apps without cheki-edit-v1 never receive the new actions');
    final (_, pulled) =
        await rest('GET', '/api/v1/actions', capabilities: _caps);
    final pending = (pulled['actions'] as List).cast<Map>();
    check(pending.length == 5, 'apps with cheki-edit-v1 receive all five');
    final replaceAction =
        pending.singleWhere((a) => a['kind'] == kReplacePhotoActionKind);
    final imageId =
        (((replaceAction['payload'] as Map)['images'] as List).single
            as Map)['imageId'];
    final (imageStatus, _) =
        await rest('GET', '/api/v1/face-images/$imageId', capabilities: _caps);
    check(imageStatus == 200, 'the staged replacement image is downloadable');
    final editAction = pending.firstWhere((a) =>
        a['kind'] == kEditRecordActionKind &&
        (a['payload'] as Map)['record_id'] == 227);
    check(
        jsonEncode((editAction['payload'] as Map)['expected']) ==
            jsonEncode({'three_inch_count': 2, 'note': ''}),
        'the edit payload carries the values the assistant saw');

    final (rawStatus, _) = await rest('POST', '/api/v1/actions',
        body: {'kind': kDeletePhotoActionKind, 'payload': {'media_id': 1}});
    check(rawStatus >= 400 && rawStatus < 500,
        'generic POST cannot queue the new kinds');

    final (emptyReasonStatus, _) =
        await rest('POST', '/api/v1/actions/ack', capabilities: _caps, body: {
      'ids': [deleted['action_id']],
      'failures': {deleted['action_id']: ' '},
    });
    check(emptyReasonStatus >= 400, 'a failure without a reason is refused');

    final (ackStatus, ack) =
        await rest('POST', '/api/v1/actions/ack', capabilities: _caps, body: {
      'ids': [
        deleted['action_id'],
        replaced['action_id'],
        edited['action_id'],
      ],
      'failures': {
        edited['action_id']: '流水 #227 在手机上已改过，未覆盖：three_inch_count 现在是 5，你看到的是 2',
      },
      'results': {
        deleted['action_id']: {'media_id': 900, 'deleted': true},
        replaced['action_id']: {'media_id': 901, 'replaced': true},
      },
      'deferred': {otherField['action_id']: '数据库忙，下次同步重试'},
    });
    check(ackStatus == 200 &&
        ack['applied'] == 2 &&
        ack['failed'] == 1 &&
        ack['deferred'] == 1,
        'receipts: applied, failed and deferred are counted');
    check(await stagedFiles() == 0,
        'the replacement image is removed once the receipt arrives');

    final edits = ok(await call('list_cheki_edits', {})) ;
    final views = (edits['edits'] as List).cast<Map>();
    Map view(Object? id) => views.singleWhere((v) => v['id'] == id);
    check(
        view(deleted['action_id'])['status'] == 'applied' &&
            (view(deleted['action_id'])['result'] as Map)['deleted'] == true,
        'list_cheki_edits shows the delete receipt');
    check(
        view(edited['action_id'])['status'] == 'failed' &&
            view(edited['action_id'])['failure'].toString().contains('已改过'),
        'list_cheki_edits shows the failure reason');
    check(
        view(otherField['action_id'])['status'] == 'pending' &&
            view(otherField['action_id'])['attempts'] == 1 &&
            view(otherField['action_id'])['last_error'] == '数据库忙，下次同步重试',
        'a deferred edit stays pending with its reason');
    final byMedia = ok(await call('list_cheki_edits', {'media_id': 901}));
    check(
        byMedia['count'] == 1 &&
            ((byMedia['edits'] as List).single as Map)['kind'] ==
                kReplacePhotoActionKind,
        'list_cheki_edits filters by media_id');

    // After the receipt the same photo can be targeted again.
    final again = await call('delete_cheki_photo', {'media_id': 901});
    check(again['isError'] != true,
        'a photo is free again once its action has a receipt');
  } finally {
    client.close(force: true);
    await server.close();
    await dir.delete(recursive: true);
  }
}
