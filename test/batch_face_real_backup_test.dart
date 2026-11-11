// Leave-one-out recognition check on the owner's real, labelled cheki.
//
// The backup is private and never committed. Run with:
//
//   OTA_REAL_BACKUP=/path/to/ota_counter_backup_xxx.zip \
//   OTA_FACE_REFERENCE=/path/to/opencv_reference.json \
//     flutter test test/batch_face_real_backup_test.dart
//
// OTA_FACE_REFERENCE defaults to <backup dir>/../out/opencv_reference.json
// (the faceeval layout). It holds OpenCV 4.12 YuNet + SFace-int8 faces and
// features for every archived photo (faceeval/scripts/opencv_reference.py).
// `flutter test` runs on the host, where onnxruntime is not available, so
// FaceSampleService.analyzer is replaced by a lookup into that file; the
// app's own engine reproduces these numbers on device
// (integration_test/face_engine_parity_test.dart: cosine >= 0.99).
//
// Without OTA_REAL_BACKUP everything here is skipped. Nothing is asserted
// about accuracy: the numbers are printed (lines starting with "FACE_LOO")
// to calibrate FaceMatchThresholds.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/record_scan_service.dart';

import 'support/isolated_test_databases.dart';

// ignore: avoid_print
void _log(String line) => print('FACE_LOO $line');

Map<String, List<FaceAnalysis>> _loadReference(String path) {
  final json = jsonDecode(File(path).readAsStringSync()) as Map;
  return {
    for (final image in json['images'] as List)
      '${image['name']}': [
        for (final face in image['faces'] as List)
          FaceAnalysis(
            face: FaceDetection.fromOpenCvRow([
              for (final v in face['row'] as List) (v as num).toDouble(),
            ]),
            embedding: Float32List.fromList([
              for (final v in face['feature'] as List) (v as num).toDouble(),
            ]),
          ),
      ],
  };
}

class _Tally {
  int total = 0, autoRight = 0, autoWrong = 0, review = 0, unknown = 0;
  int reviewTop1 = 0, reviewInTop3 = 0, noFace = 0;

  @override
  String toString() => 'total=$total auto_correct=$autoRight '
      'auto_wrong=$autoWrong review=$review '
      '(top1_correct=$reviewTop1, in_top3=$reviewInTop3) '
      'unknown=$unknown (no_face=$noFace)';
}

void main() {
  final backupPath = Platform.environment['OTA_REAL_BACKUP'] ?? '';
  final referencePath = Platform.environment['OTA_FACE_REFERENCE'] ??
      (backupPath.isEmpty
          ? ''
          : p.normalize(p.join(
              p.dirname(backupPath), '..', 'out', 'opencv_reference.json')));
  final skip = backupPath.isEmpty
      ? 'OTA_REAL_BACKUP is not set'
      : !File(referencePath).existsSync()
          ? 'face reference $referencePath not found (OTA_FACE_REFERENCE)'
          : null;

  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final databases = await useIsolatedTestDatabases();
    final documents = Directory('${databases.path}/documents')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => documents.path,
    );
  });

  test('learn from archive, then leave-one-out recognition', () async {
    final reference = _loadReference(referencePath);
    final payload = await ExportImportService.parseImportPayloadFile(
      fileName: p.basename(backupPath),
      path: backupPath,
    );
    await ExportImportService.restoreFullBackup(payload.fullBackup!);

    // The service reads archived photos itself; recognise them by content.
    final media = await DatabaseService.getActivityRecordMedia();
    final bytesToName = <String, String>{
      for (final m in media)
        _fingerprint(File(m.path).readAsBytesSync()): p.basename(m.path),
    };
    FaceSampleService.analyzer = (bytes) async {
      final name = bytesToName[_fingerprint(bytes)];
      final faces = name == null ? null : reference[name];
      if (faces == null) throw StateError('no reference for photo');
      return faces;
    };

    final learn = await FaceSampleService.learnFromArchive();
    _log('archive: scanned=${learn.scanned} learned=${learn.learned} '
        'not_single_face=${learn.notSingleFace} no_owner=${learn.noOwner} '
        'failed=${learn.failed}');

    final samples = await FaceSampleService.getSamples();
    final records = {
      for (final r in await DatabaseService.getActivityRecords())
        if (r.id != null) r.id!: r,
    };
    final counters = await DatabaseService.getCounters();
    final everyone = buildCandidateMembers(
      dayMembers: const [],
      sessionGroupMembers: const [],
      allMembers: BatchImportService.allMembers(counters),
    );

    final dayTally = _Tally(), allTally = _Tally();
    for (final m in media) {
      final record = records[m.recordId];
      final owner = FaceSampleService.ownerOfMedia(m, record, counters);
      if (owner == null || record == null) continue;
      final faces = reference[p.basename(m.path)] ?? const [];
      final others = [
        for (final s in samples)
          if (s.mediaId != m.id) s,
      ];
      final day = await BatchImportService.loadDayContext(
          recordActivityDay(record.occurredAt));
      final dayCandidates = buildCandidateMembers(
        dayMembers: day.dayMembers,
        sessionGroupMembers: const [],
        allMembers: BatchImportService.allMembers(day.counters),
      );
      for (final (label, candidates, tally) in [
        ('day', dayCandidates, dayTally),
        ('all', everyone, allTally),
      ]) {
        final card = BatchImportService.recognize(
          sources: [
            BatchSourceResult(
              photo: BatchSourcePhoto(
                path: m.path,
                capturedAt: m.capturedAt,
                fromCamera: false,
              ),
              sourceHash: '',
              cards: [
                BatchCard(
                  bytes: Uint8List(0),
                  fileExtension: '.jpg',
                  processingMode: m.processingMode,
                  quad: const RecordScanQuad(
                    topLeftX: 0,
                    topLeftY: 0,
                    topRightX: 1,
                    topRightY: 0,
                    bottomLeftX: 0,
                    bottomLeftY: 1,
                    bottomRightX: 1,
                    bottomRightY: 1,
                  ),
                  sizeClass: RecordScanCardSize.mini,
                  confidence: 1,
                  splitFromMerged: false,
                  faces: faces,
                ),
              ],
            ),
          ],
          candidates: candidates,
          samples: others,
          day: day,
        ).single;
        tally.total++;
        final hasOwner = card.members.any((x) => x.sameAs(owner));
        final exact = hasOwner && card.members.length == 1;
        String outcome;
        switch (card.status) {
          case FaceMatchStatus.auto:
            if (exact) {
              tally.autoRight++;
              outcome = 'auto_correct';
            } else {
              tally.autoWrong++;
              outcome = 'auto_wrong';
            }
          case FaceMatchStatus.review:
            tally.review++;
            final top1 = hasOwner;
            final inTop3 = card.suggestions.any((x) => x.sameAs(owner));
            if (top1) tally.reviewTop1++;
            if (inTop3 || top1) tally.reviewInTop3++;
            outcome = 'review${top1 ? '(top1 ok)' : inTop3 ? '(in top3)' : ''}';
          case FaceMatchStatus.unknown:
            tally.unknown++;
            if (faces.isEmpty) tally.noFace++;
            outcome = faces.isEmpty ? 'unknown(no face)' : 'unknown';
        }
        final perMember = FaceSampleService.samplesByMember(candidates, others);
        final scores = [
          for (final f in faces)
            ([
              for (var i = 0; i < candidates.length; i++)
                if (perMember[i].isNotEmpty)
                  (
                    candidates[i].name,
                    maxSimilarity(f.embedding, perMember[i]),
                  ),
            ]..sort((x, y) => y.$2.compareTo(x.$2)))
                .take(2)
                .map((e) => '${e.$1}:${e.$2.toStringAsFixed(2)}')
                .join(','),
        ];
        final best = card.faceMatches.isEmpty
            ? ''
            : ' samples_of_owner=${others.where((s) => owner.isSamePerson(counterId: s.counterId, personId: s.personId, name: s.personName)).length}';
        _log('$label media#${m.id} faces=${faces.length} '
            'candidates=${candidates.length} -> $outcome '
            '[${card.members.map((x) => x.name).join('+')}]$best '
            'top2=$scores');
      }
    }
    _log('day-candidates: $dayTally');
    _log('all-members:    $allTally');
    expect(
      dayTally.autoRight +
          dayTally.autoWrong +
          dayTally.review +
          dayTally.unknown,
      dayTally.total,
    );
    expect(
        samples.every((s) => s.source == FaceSampleSource.bootstrap), isTrue);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}

String _fingerprint(Uint8List bytes) => sha1.convert(bytes).toString();
