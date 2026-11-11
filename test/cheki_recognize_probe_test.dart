// Probe: what would 自动记录 propose for the cheki cards cut out of today's
// desk photos?
//
// Everything the app does on device, minus the native face engine: the face
// features come from OpenCV (YuNet + SFace-int8, same pipeline as
// FaceEngine) through a reference JSON, exactly like
// batch_face_real_backup_test.dart does on the host.
//
//   OTA_REAL_BACKUP=/path/to/backup.zip \
//   OTA_ARCHIVE_REFERENCE=/path/to/media_reference.json \
//   OTA_CHEKI_CROPS=/path/to/crops \
//   OTA_CHEKI_REFERENCE=/path/to/crops_reference.json \
//     flutter test test/cheki_recognize_probe_test.dart
//
// Report lines start with CHEKI_FACE. Without the variables the test skips.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/export_import_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/record_scan_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  final backupPath = Platform.environment['OTA_REAL_BACKUP'] ?? '';
  final archiveReferencePath =
      Platform.environment['OTA_ARCHIVE_REFERENCE'] ?? '';
  final cropsDir = Platform.environment['OTA_CHEKI_CROPS'] ?? '';
  final cropsReferencePath =
      Platform.environment['OTA_CHEKI_REFERENCE'] ?? '';

  final missing = backupPath.isEmpty
      ? 'OTA_REAL_BACKUP is not set'
      : archiveReferencePath.isEmpty
          ? 'OTA_ARCHIVE_REFERENCE is not set'
          : cropsDir.isEmpty
              ? 'OTA_CHEKI_CROPS is not set'
              : cropsReferencePath.isEmpty
                  ? 'OTA_CHEKI_REFERENCE is not set'
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

  test('recognise the cards from today\'s desk photos', () async {
    final archiveReference = _loadReference(archiveReferencePath);
    final cropsReference = _loadReference(cropsReferencePath);

    final payload = await ExportImportService.parseImportPayloadFile(
      fileName: p.basename(backupPath),
      path: backupPath,
    );
    await ExportImportService.restoreFullBackup(payload.fullBackup!);

    // FaceSampleService reads archived media itself; recognise them by content.
    final media = await DatabaseService.getActivityRecordMedia();
    final bytesToName = <String, String>{
      for (final m in media)
        _fingerprint(File(m.path).readAsBytesSync()): p.basename(m.path),
    };
    FaceSampleService.analyzer = (bytes) async {
      final name = bytesToName[_fingerprint(bytes)];
      final faces = name == null ? null : archiveReference[name];
      if (faces == null) throw StateError('no archive reference for $name');
      return faces;
    };

    final learn = await FaceSampleService.learnFromArchive();
    final stats = await FaceSampleService.getStats();
    _log('archive: scanned=${learn.scanned} learned=${learn.learned} '
        'not_single_face=${learn.notSingleFace} no_owner=${learn.noOwner} '
        'failed=${learn.failed} | samples self=${stats.self} '
        'members=${stats.members} people=${stats.people}');
    if (stats.members == 0) {
      fail('no member samples after learning the archive: '
          '自动记录 would have nothing to match against');
    }

    final samples = await FaceSampleService.getSamples();
    final counters = await DatabaseService.getCounters();
    final candidates = buildCandidateMembers(
      dayMembers: const [],
      sessionGroupMembers: const [],
      allMembers: BatchImportService.allMembers(counters),
    );
    final day = await BatchImportService.loadDayContext(DateTime(2026, 11, 8));
    _log('candidates=${candidates.length} counters=${counters.length} '
        'dayMembers=${day.dayMembers.length} sessions=${day.sessions.length}');

    final crops = Directory(cropsDir)
        .listSync()
        .whereType<File>()
        .where((file) =>
            RegExp(r'\.(jpe?g|png)$', caseSensitive: false)
                .hasMatch(file.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final crop in crops) {
      final name = crop.uri.pathSegments.last;
      final faces = cropsReference[name] ?? const <FaceAnalysis>[];
      final bytes = crop.readAsBytesSync();
      final card = BatchImportService.recognize(
        sources: [
          BatchSourceResult(
            photo: BatchSourcePhoto(
              path: crop.path,
              capturedAt: null,
              fromCamera: false,
            ),
            sourceHash: _fingerprint(Uint8List.fromList(bytes)),
            cards: [
              BatchCard(
                bytes: Uint8List.fromList(bytes),
                fileExtension: p.extension(name),
                processingMode:
                    ActivityRecordMediaProcessingMode.manualAssist,
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
        samples: samples,
        day: day,
      ).single;

      _log('CHEKI_FACE $name faces=${faces.length} '
          'status=${card.status.name} '
          'members=[${card.members.map((m) => m.name).join('+')}] '
          'suggestions=[${card.suggestions.map((m) => m.name).join(',')}] '
          'size=${card.size.name} sizeUncertain=${card.sizeUncertain} '
          'groupSuggested=${card.groupSuggested}');
    }
  },
      skip: missing,
      timeout: const Timeout(Duration(minutes: 5)));
}

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

String _fingerprint(Uint8List bytes) => sha1.convert(bytes).toString();

void _log(String line) => debugPrint('CHEKI_FACE_LOG $line');
