import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/sync_service.dart';

import 'support/isolated_test_databases.dart';

FaceAnalysis face(List<double> embedding,
        {double area = 100, double x = 0, double y = 0}) =>
    FaceAnalysis(
      face: FaceDetection(
          x: x, y: y, width: area, height: 1, landmarks: const [], score: 0.9),
      embedding: Float32List.fromList(embedding),
    );
FaceAnalysis scored(double score, {double area = 100}) =>
    face([score, math.sqrt(1 - score * score), 0], area: area);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const memberFeature = [1.0, 0.0, 0.0];
  const otherFeature = [0.0, 1.0, 0.0];
  const selfFeature = [0.0, 0.0, 1.0];

  group('automatic enrollment selection', () {
    test('empty input and self-only input fail', () {
      expect(FaceSampleService.selectEnrollmentFace([]), isNull);
      expect(
          FaceSampleService.selectEnrollmentFace([face(selfFeature)],
              selfSamples: [selfFeature]),
          isNull);
    });
    test('one remaining face is selected at its original index', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [face(selfFeature, area: 10000), face(memberFeature)],
              selfSamples: [selfFeature]),
          1);
    });
    test('similarity wins over area and does not mutate input', () {
      final small = scored(0.8, area: 1);
      final large = scored(0.6, area: 1000);
      final faces = [large, small];
      expect(
          FaceSampleService.selectEnrollmentFace(faces,
              memberSamples: [memberFeature]),
          1);
      expect(faces, [large, small]);
    });
    test('uses best of all member samples', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [face(memberFeature), face(selfFeature)],
              memberSamples: [otherFeature, memberFeature]),
          0);
    });
    test('below reviewMin is not selected by similarity', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [scored(FaceMatchThresholds.reviewMin - 0.001), scored(0.1)],
              memberSamples: [memberFeature]),
          isNull);
    });
    test('above reviewMin with sufficient lead is selected', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [scored(FaceMatchThresholds.reviewMin + 0.001), scored(0.1)],
              memberSamples: [memberFeature]),
          0);
    });
    test('insufficient lead, even at high similarity, fails for equal areas',
        () {
      expect(
          FaceSampleService.selectEnrollmentFace([
            scored(0.9),
            scored(0.9 - FaceMatchThresholds.reviewMargin + 0.001)
          ], memberSamples: [
            memberFeature
          ]),
          isNull);
    });
    test('sufficient reviewMargin accepts high similarity', () {
      expect(
          FaceSampleService.selectEnrollmentFace([
            scored(0.9),
            scored(0.9 - FaceMatchThresholds.reviewMargin - 0.001)
          ], memberSamples: [
            memberFeature
          ]),
          0);
    });
    test('area fallback accepts exactly 1.5x and rejects below it', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [face(memberFeature, area: 150), face(otherFeature)]),
          0);
      expect(
          FaceSampleService.selectEnrollmentFace(
              [face(memberFeature, area: 149.99), face(otherFeature)]),
          isNull);
    });
    test('ambiguous similarity still allows dominant area fallback', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [scored(0.9, area: 100), scored(0.85, area: 150)],
              memberSamples: [memberFeature]),
          1);
    });
    test('self is removed before similarity and area comparison', () {
      expect(
          FaceSampleService.selectEnrollmentFace([
            face(selfFeature, area: 10000),
            face(memberFeature, area: 150),
            face(otherFeature),
          ], selfSamples: [
            selfFeature
          ]),
          1);
    });
    test('largest picks the biggest non-self face without similarity', () {
      expect(
          FaceSampleService.selectEnrollmentFace(
              [
                face(selfFeature, area: 10000, x: 1),
                face(memberFeature, area: 100, x: 10),
                face(otherFeature, area: 400, x: 20),
              ],
              face: 'largest',
              selfSamples: [selfFeature]),
          2);
    });
    test('largest fails when only the user face exists', () {
      expect(
          FaceSampleService.selectEnrollmentFace([face(selfFeature)],
              face: 'largest', selfSamples: [selfFeature]),
          isNull);
    });
    test('left_N counts faces by box center x, including self', () {
      final faces = [
        face(memberFeature, area: 100, x: 100),
        face(otherFeature, area: 100, x: 0),
        face(selfFeature, area: 100, x: 50),
      ];
      expect(FaceSampleService.faceOrderFromLeft(faces), [1, 2, 0]);
      expect(FaceSampleService.selectEnrollmentFace(faces, face: 'left_1'), 1);
      expect(FaceSampleService.selectEnrollmentFace(faces, face: 'left_2'), 2);
      expect(FaceSampleService.selectEnrollmentFace(faces, face: 'left_3'), 0);
      expect(FaceSampleService.selectEnrollmentFace(faces, face: 'left_4'),
          isNull);
    });
    test('invalid selector is rejected', () {
      expect(
          () => FaceSampleService.selectEnrollmentFace([face(memberFeature)],
              face: 'middle'),
          throwsArgumentError);
    });
  });

  group('sync enroll_face handler', () {
    late HttpServer server;
    late SyncSettings settings;
    late int counterId;
    late FaceAnalyzer originalAnalyzer;
    late Future<({int width, int height})> Function(Uint8List)
        originalImageSize;
    late List<FaceAnalysis> detected;
    late List<Map<String, dynamic>> acks;
    late int fetches;
    late bool failAck;
    late int imageStatus;
    late bool timeoutImage;

    Map<String, dynamic> action(String id, {Map<String, dynamic>? payload}) => {
          'id': id,
          'kind': 'enroll_face',
          'payload': payload ??
              {
                'counter_id': counterId,
                'person_id': 101,
                'person_name': '真人名',
                'member_name': '成员',
                'group_name': 'P',
                'imageId': 'synthetic-image',
                'source': 'mcp',
              },
        };
    Future<List<FaceSampleModel>> samples() =>
        FaceSampleService.getMemberSamples(FaceMember(
            counterId: counterId,
            personId: 101,
            name: '成员',
            personName: '真人名'));

    setUpAll(() async {
      await useIsolatedTestDatabases();
    });
    setUp(() async {
      HttpOverrides.global = null;
      await DatabaseService.clearAppData();
      await FaceSampleService.clearAll();
      counterId = await DatabaseService.insertCounter(CounterModel(
          name: '成员',
          groupName: 'P',
          personId: 101,
          personName: '真人名',
          color: '#ffffff'));
      detected = [face(memberFeature)];
      originalAnalyzer = FaceSampleService.analyzer;
      originalImageSize = FaceSampleService.imageSize;
      FaceSampleService.imageSize = (bytes) async => (width: 200, height: 100);
      FaceSampleService.analyzer = (bytes) async {
        expect(
            bytes, [1, 2, 3]); // Synthetic bytes only; no photo files accessed.
        return detected;
      };
      acks = [];
      fetches = 0;
      failAck = false;
      imageStatus = 200;
      timeoutImage = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        // Check auth without ever printing its value in diagnostics.
        expect(
            request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer synthetic-test-credential',
            isTrue);
        if (request.uri.path.startsWith('/api/v1/face-images/')) {
          fetches++;
          expect(request.uri.path, '/api/v1/face-images/synthetic-image');
          // Leave headers unsent to exercise the real HTTP response timeout.
          if (timeoutImage) return;
          request.response.statusCode = imageStatus;
          request.response.add([1, 2, 3]);
        } else if (request.uri.path == '/api/v1/actions/ack') {
          acks.add(Map<String, dynamic>.from(
              jsonDecode(await utf8.decoder.bind(request).join()) as Map));
          request.response.statusCode = failAck ? 503 : 200;
          request.response.write('{}');
        } else {
          request.response.statusCode = 404;
          request.response.write('{}');
        }
        await request.response.close();
      });
      settings = SyncSettings(
          baseUrl: 'http://127.0.0.1:${server.port}',
          token: 'synthetic-test-credential',
          deviceId: 'test-device',
          autoSync: false,
          lastSyncAt: '');
    });
    tearDown(() async {
      FaceSampleService.analyzer = originalAnalyzer;
      FaceSampleService.imageSize = originalImageSize;
      await server.close(force: true);
      await DatabaseService.clearAppData();
      await FaceSampleService.clearAll();
    });

    test(
        'single face uses shared manual storage and ACK summary without ledger impact',
        () async {
      final result = await SyncService.applyActions(settings, [action('one')]);
      expect(result.applied, 1);
      expect(result.failures, isEmpty);
      final stored = (await samples()).single;
      expect(stored.source, FaceSampleSource.manual);
      expect(stored.personId, 101);
      expect(stored.counterId, counterId);
      expect(stored.personName, '真人名');
      expect(stored.embedding, memberFeature);
      expect(stored.mediaId, isNull);
      expect(await DatabaseService.getActivityRecords(), isEmpty);
      expect((await DatabaseService.getCounters()).single.count, 0);
      expect(acks.single['ids'], ['one']);
      expect(acks.single['results']['one']['faces_found'], 1);
      expect(acks.single['results']['one']['used_face'], 1);
      expect(acks.single['results']['one']['used_face_bounds'],
          {'x': 0, 'y': 0, 'width': 100, 'height': 1});
      expect(acks.single.containsKey('failures'), isFalse);
    });
    test('self-filtered face reports its left-to-right index', () async {
      await FaceSampleService.addSamples([
        FaceSampleService.sampleFromAnalysis(face(selfFeature),
            source: FaceSampleSource.self)
      ]);
      detected = [
        face(selfFeature, area: 999),
        face(memberFeature, area: 37.5, x: 12.25, y: 29.75)
      ];
      await SyncService.applyActions(settings, [action('self-filter')]);
      expect(acks.single['results']['self-filter']['faces_found'], 2);
      expect(acks.single['results']['self-filter']['used_face'], 1);
      expect(acks.single['results']['self-filter']['used_face_bounds'],
          {'x': 12.25, 'y': 29.75, 'width': 37.5, 'height': 1});
      expect((await samples()).single.embedding, memberFeature);
      expect(await FaceSampleService.getSamples(isSelf: true), hasLength(1));
    });
    test('existing member samples choose smaller matching face', () async {
      await FaceSampleService.addSamples([
        FaceSampleService.sampleFromAnalysis(face(memberFeature),
            source: FaceSampleSource.manual,
            owner: FaceMember(counterId: counterId, personId: 101, name: '真人名'))
      ]);
      detected = [face(otherFeature, area: 1000), face(memberFeature, area: 1)];
      await SyncService.applyActions(settings, [action('match')]);
      expect(acks.single['results']['match']['used_face'], 1);
      expect(acks.single['results']['match']['used_face_bounds'],
          {'x': 0, 'y': 0, 'width': 1, 'height': 1});
    });
    test('no face failure is acknowledged with Chinese reason and no result',
        () async {
      detected = [];
      final result =
          await SyncService.applyActions(settings, [action('empty')]);
      expect(result.applied, 0);
      expect(result.failures.single.message, contains('未检测到'));
      expect(await samples(), isEmpty);
      expect(acks.single['ids'], ['empty']);
      expect(acks.single['failures']['empty'], contains('未检测到'));
      expect(acks.single['results']['empty']['faces_found'], 0);
      expect(acks.single['results']['empty']['samples_kept'], 0);
      expect(acks.single['results']['empty']['faces'], isEmpty);
    });
    test('multiple ambiguous faces fail instead of enrolling arbitrary person',
        () async {
      detected = [face(memberFeature), face(otherFeature)];
      final result =
          await SyncService.applyActions(settings, [action('ambiguous')]);
      expect(result.failures.single.message, contains('多张人脸'));
      expect(await samples(), isEmpty);
      expect(acks.single['failures']['ambiguous'], contains('left_N'));
      expect(acks.single['results']['ambiguous']['faces'], hasLength(2));
      expect(
          (acks.single['results']['ambiguous']['faces'] as List)
              .first['index_from_left'],
          1);
      expect(
          (acks.single['results']['ambiguous']['faces'] as List).first['box'],
          {'x': 0.0, 'y': 0.0, 'width': 0.5, 'height': 0.01});
    });
    test('temporary analyzer error keeps pending and succeeds after recovery',
        () async {
      final workingAnalyzer = FaceSampleService.analyzer;
      FaceSampleService.analyzer =
          (_) async => throw StateError('native session initialization error');
      final pending = [action('engine-error')];
      final result = await SyncService.applyActions(settings, pending);
      expect(result.applied, 0);
      expect(result.failures.single.message, contains('请稍后同步重试'));
      expect(result.failures.single.message, isNot(contains('native session')));
      expect(acks, isEmpty);
      expect(await samples(), isEmpty);
      final db = await DatabaseService.database;
      expect(await db.query(DatabaseService.faceEnrollmentActionsTableName),
          isEmpty);

      FaceSampleService.analyzer = workingAnalyzer;
      final retry = await SyncService.applyActions(settings, pending);
      expect(retry.applied, 1);
      expect(retry.failures, isEmpty);
      expect(await samples(), hasLength(1));
      expect(fetches, 2);
      expect(acks.single['ids'], ['engine-error']);
      expect(acks.single['results']['engine-error']['faces_found'], 1);
      expect(await db.query(DatabaseService.faceEnrollmentActionsTableName),
          hasLength(1));
    });
    test('undecodable image is a terminal Chinese failure and is ACKed',
        () async {
      FaceSampleService.analyzer =
          (_) async => throw const FormatException('无法解码图片');
      final result =
          await SyncService.applyActions(settings, [action('invalid-photo')]);
      expect(result.applied, 0);
      expect(result.failures.single.message, contains('无法解码照片'));
      expect(await samples(), isEmpty);
      expect(acks.single['ids'], ['invalid-photo']);
      expect(acks.single['failures']['invalid-photo'], contains('有效照片'));
      expect(acks.single['results']['invalid-photo']['faces'], isEmpty);
      final db = await DatabaseService.database;
      expect(
          (await db.query(DatabaseService.faceEnrollmentActionsTableName))
              .single['failure'],
          contains('无法解码照片'));
    });
    test('missing image returns Chinese failure', () async {
      imageStatus = 404;
      final result =
          await SyncService.applyActions(settings, [action('download-error')]);
      expect(result.failures.single.message, contains('下载失败'));
      expect(await samples(), isEmpty);
      expect(acks.single['ids'], ['download-error']);
      expect(acks.single['failures']['download-error'], contains('下载失败'));
      expect(acks.single['results']['download-error']['faces_found'], 0);
      final db = await DatabaseService.database;
      expect(
          (await db.query(DatabaseService.faceEnrollmentActionsTableName))
              .single['failure'],
          contains('下载失败'));
    });
    for (final transient in ['503', 'timeout']) {
      test(
          '$transient keeps pending without receipt or ACK, then same action succeeds',
          () async {
        imageStatus = transient == '503' ? 503 : 200;
        timeoutImage = transient == 'timeout';
        final pending = [action('transient-$transient')];
        final first = await SyncService.applyActions(settings, pending);
        expect(first.applied, 0);
        expect(first.failures.single.message, contains('下次同步将重试'));
        expect(acks, isEmpty);
        expect(await samples(), isEmpty);
        final db = await DatabaseService.database;
        expect(await db.query(DatabaseService.faceEnrollmentActionsTableName),
            isEmpty);

        imageStatus = 200;
        timeoutImage = false;
        final retry = await SyncService.applyActions(settings, pending);
        expect(retry.applied, 1);
        expect(retry.failures, isEmpty);
        expect(await samples(), hasLength(1));
        expect(fetches, 2);
        expect(acks.single['ids'], ['transient-$transient']);
        expect(
            acks.single['results']['transient-$transient']['faces_found'], 1);
        expect(await db.query(DatabaseService.faceEnrollmentActionsTableName),
            hasLength(1));
      }, timeout: const Timeout(Duration(seconds: 60)));
    }

    test('missing, empty, invalid imageId are rejected before network',
        () async {
      for (final value in [null, '', 123]) {
        final result = await SyncService.applyActions(settings, [
          action('bad-image-$value',
              payload: {'counter_id': counterId, 'imageId': value})
        ]);
        expect(result.failures.single.message, contains('照片编号'));
      }
      expect(fetches, 0);
    });
    test(
        'missing, unknown and conflicting identities never fall back to another member',
        () async {
      final invalid = [
        <String, dynamic>{},
        {'counter_id': 99999, 'member_name': '成员'},
        {'counter_id': -1},
        {'counter_id': counterId, 'person_id': 102},
      ];
      for (var i = 0; i < invalid.length; i++) {
        final result = await SyncService.applyActions(settings, [
          action('bad-member-$i',
              payload: {...invalid[i], 'imageId': 'synthetic-image'})
        ]);
        expect(result.failures, hasLength(1));
      }
      expect(fetches, 0);
      expect(await samples(), isEmpty);
    });
    test('same-name different members require disambiguation', () async {
      await DatabaseService.insertCounter(
          CounterModel(name: '成员', groupName: 'Q', color: '#ffffff'));
      final result = await SyncService.applyActions(settings, [
        action('same-name',
            payload: {'member_name': '成员', 'imageId': 'synthetic-image'})
      ]);
      expect(result.failures.single.message, contains('同名'));
      expect(fetches, 0);
      final good = await SyncService.applyActions(settings, [
        action('group-name', payload: {
          'member_name': '成员',
          'group_name': 'P',
          'imageId': 'synthetic-image'
        })
      ]);
      expect(good.failures, isEmpty);
    });
    test('person id aliases share samples and preserve 30-sample cap',
        () async {
      for (var i = 0; i < 35; i++) {
        final result = await SyncService.applyActions(settings, [
          action('cap-$i',
              payload: {'person_id': 101, 'imageId': 'synthetic-image'})
        ]);
        expect(result.failures, isEmpty);
      }
      expect(await samples(), hasLength(30));
      expect(acks, hasLength(35));
    });
    test(
        'ACK error retries durable summary without fetching or adding sample again',
        () async {
      failAck = true;
      final pending = [action('retry')];
      await SyncService.applyActions(settings, pending);
      expect(await samples(), hasLength(1));
      expect(acks.single['results']['retry']['used_face_bounds'],
          {'x': 0, 'y': 0, 'width': 100, 'height': 1});
      // Even if the remote ACK succeeded but its response was lost, the image
      // may already be deleted; the durable receipt must avoid re-fetching it.
      imageStatus = 404;
      FaceSampleService.analyzer =
          (_) async => throw StateError('must not rerun');
      failAck = false;
      final retry = await SyncService.applyActions(settings, pending);
      expect(retry.failures, isEmpty);
      expect(retry.skipped, 1);
      expect(await samples(), hasLength(1));
      expect(fetches, 1);
      expect(acks[1], acks[0]);
    });
    test(
        'failed enrollment ACK retry repeats same failure without new analysis',
        () async {
      detected = [];
      failAck = true;
      await SyncService.applyActions(settings, [action('retry-failure')]);
      detected = [face(memberFeature)];
      failAck = false;
      await SyncService.applyActions(settings, [action('retry-failure')]);
      expect(fetches, 1);
      expect(await samples(), isEmpty);
      expect(acks[1], acks[0]);
    });
    test('overlapping sync and duplicate batch persist one sample per action',
        () async {
      final pending = [action('overlap'), action('overlap')];
      final results = await Future.wait([
        SyncService.applyActions(settings, pending),
        SyncService.applyActions(settings, pending),
      ]);
      expect(results.every((r) => r.failures.isEmpty), isTrue);
      expect(await samples(), hasLength(1));
    });
    test('receipt and sample writes roll back together on database failure',
        () async {
      final db = await DatabaseService.database;
      await db.execute(
          "CREATE TRIGGER reject_receipt BEFORE INSERT ON ${DatabaseService.faceEnrollmentActionsTableName} BEGIN SELECT RAISE(ABORT, 'synthetic db failure'); END");
      addTearDown(() => db.execute('DROP TRIGGER IF EXISTS reject_receipt'));
      final pending = [action('rollback')];
      final first = await SyncService.applyActions(settings, pending);
      expect(first.failures, hasLength(1));
      expect(await samples(), isEmpty);
      expect(acks, isEmpty);
      await db.execute('DROP TRIGGER reject_receipt');
      final second = await SyncService.applyActions(settings, pending);
      expect(second.failures, isEmpty);
      expect(await samples(), hasLength(1));
    });
    test(
        'mixed actions ACK enrollment failures but leave ordinary failures pending',
        () async {
      detected = [];
      final result = await SyncService.applyActions(settings, [
        action('enroll-fail'),
        {
          'id': 'delta',
          'kind': 'counter_delta',
          'payload': {
            'counter_id': counterId,
            'counts': {'threeInchCount': 2}
          }
        },
        {
          'id': 'missing',
          'kind': 'counter_delta',
          'payload': {'counter_id': 99999}
        },
      ]);
      expect(result.applied, 1);
      expect(result.failures, hasLength(2));
      expect(acks.single['ids'], ['delta', 'enroll-fail']);
      expect((acks.single['failures'] as Map).keys, ['enroll-fail']);
      expect((await DatabaseService.getCounters()).single.threeInchCount, 2);
      await SyncService.applyActions(settings, [
        {
          'id': 'delta',
          'kind': 'counter_delta',
          'payload': {
            'counter_id': counterId,
            'counts': {'threeInchCount': 2}
          }
        },
      ]);
      expect(acks.last, {
        'ids': ['delta']
      });
      expect((await DatabaseService.getCounters()).single.threeInchCount, 2);
    });
    test('explicit largest and left_N selectors are honored', () async {
      detected = [
        face(memberFeature, area: 100, x: 0),
        face(otherFeature, area: 400, x: 0),
      ];
      await SyncService.applyActions(settings, [
        action('largest', payload: {
          'counter_id': counterId,
          'person_id': 101,
          'person_name': '真人名',
          'member_name': '成员',
          'group_name': 'P',
          'imageId': 'synthetic-image',
          'source': 'mcp',
          'face': 'largest',
        })
      ]);
      expect((await samples()).single.embedding, otherFeature);
      expect(acks.single['results']['largest']['used_face'], 2);

      await FaceSampleService.clearAll();
      await SyncService.applyActions(settings, [
        action('left-one', payload: {
          'counter_id': counterId,
          'imageId': 'synthetic-image',
          'face': 'left_1',
        })
      ]);
      expect((await samples()).single.embedding, memberFeature);
      expect(acks.last['results']['left-one']['used_face'], 1);

      await FaceSampleService.clearAll();
      await SyncService.applyActions(settings, [
        action('left-two', payload: {
          'counter_id': counterId,
          'imageId': 'synthetic-image',
          'face': 'left_2',
        })
      ]);
      expect((await samples()).single.embedding, otherFeature);
      expect(acks.last['results']['left-two']['used_face'], 2);
    });
    test('left_N out of range reports boxes and a later left_N succeeds',
        () async {
      detected = [
        face(memberFeature, area: 100, x: 0),
        face(otherFeature, area: 200, x: 10),
      ];
      final first = await SyncService.applyActions(settings, [
        action('left-retry', payload: {
          'counter_id': counterId,
          'imageId': 'synthetic-image',
          'face': 'left_3',
        })
      ]);
      expect(first.failures.single.message, contains('无法选择'));
      expect(first.failures.single.message, contains('left_3'));
      expect(acks.single['results']['left-retry']['faces_found'], 2);
      expect(acks.single['results']['left-retry']['used_face'], isNull);
      expect(acks.single['results']['left-retry']['samples_kept'], 0);
      final faces =
          acks.single['results']['left-retry']['faces'] as List<dynamic>;
      expect(faces[0]['index_from_left'], 1);
      expect(
          faces[0]['box'], {'x': 0.0, 'y': 0.0, 'width': 0.5, 'height': 0.01});
      expect(faces[1]['index_from_left'], 2);
      expect(faces[1]['box']['x'], 0.05);
      expect(faces[1]['box']['width'], 1.0);

      final retry = await SyncService.applyActions(settings, [
        action('left-retry-ok', payload: {
          'counter_id': counterId,
          'imageId': 'synthetic-image',
          'face': 'left_1',
        })
      ]);
      expect(retry.failures, isEmpty);
      expect((await samples()).single.embedding, memberFeature);
      expect(acks.last['results']['left-retry-ok']['used_face'], 1);
      expect(fetches, 2);
    });
    test('left_N may select the user face and fails clearly', () async {
      await FaceSampleService.addSamples([
        FaceSampleService.sampleFromAnalysis(face(selfFeature),
            source: FaceSampleSource.self)
      ]);
      detected = [
        face(selfFeature, area: 100, x: 0),
        face(memberFeature, area: 100, x: 100),
      ];
      final result = await SyncService.applyActions(settings, [
        action('self-left', payload: {
          'counter_id': counterId,
          'imageId': 'synthetic-image',
          'face': 'left_1',
        })
      ]);
      expect(result.failures.single.message, contains('「我」'));
      expect(await samples(), isEmpty);
      expect(acks.single['results']['self-left']['used_face'], isNull);
      expect(acks.single['results']['self-left']['faces'], hasLength(2));
    });
    test('invalid face selector is a terminal Chinese failure', () async {
      final result = await SyncService.applyActions(settings, [
        action('bad-face', payload: {
          'counter_id': counterId,
          'imageId': 'synthetic-image',
          'face': 'middle',
        })
      ]);
      expect(result.failures.single.message, contains('人脸选择'));
      expect(await samples(), isEmpty);
      expect(acks.single['results']['bad-face']['faces'], hasLength(1));
    });
  });
}
