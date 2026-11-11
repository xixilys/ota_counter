// On-device parity check of lib/services/face against OpenCV 4.12.
//
// Not self-contained on purpose (test photos must not live in the repo, and
// `flutter test` uninstalls the app afterwards, wiping pushed files):
//   1. python -I faceeval/scripts/opencv_reference.py <faceeval> \
//        <dir>/opencv_reference.json <imgs>   (and copy the imgs into <dir>)
//   2. python3 -m http.server 8765 --bind 127.0.0.1 -d <dir>
//      adb reverse tcp:8765 tcp:8765
//   3. flutter test integration_test/face_engine_parity_test.dart -d <device>
//      (--dart-define=FACE_FIXTURE_URL=... to override the default URL)
// Lines starting with "FACE_PARITY" are the report.
//
// Two comparisons per image:
//   engine — the app pipeline fed imread's exact pixels (<name>.bgr):
//            asserts IoU >= 0.9, cosine >= 0.99, same face count.
//   e2e    — the production path (platform decoder). Asserted the same way
//            when the decoded pixels equal imread's; otherwise (e.g. Display
//            P3 photos, which Flutter colour-converts and OpenCV does not)
//            only reported.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ota_counter/services/face/face_engine.dart';
import 'package:ota_counter/services/face/face_math.dart';
import 'package:ota_counter/services/face/face_models.dart';

const double _minIou = 0.9;
const double _minCosine = 0.99;

void _log(String line) => debugPrint('FACE_PARITY $line');

const String _fixtureUrl = String.fromEnvironment(
  'FACE_FIXTURE_URL',
  defaultValue: 'http://127.0.0.1:8765',
);

Future<Uint8List> _fetch(String name) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('$_fixtureUrl/$name'));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('GET $name -> ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

typedef _RefFace = ({FaceDetection face, List<double> feature});

/// Match each OpenCV face to the best-IoU app face; returns report text and
/// appends threshold violations to [failures] (when [enforce]).
String _compare(
  String label,
  List<_RefFace> refFaces,
  FaceDetectionResult result,
  List<Float32List> embeddings,
  List<String> failures, {
  required bool enforce,
}) {
  final pairs = <String>[];
  void fail(String why) {
    if (enforce) failures.add('$label: $why');
  }

  if (refFaces.length != result.faces.length) {
    fail('${result.faces.length} faces, OpenCV ${refFaces.length}');
  }
  final used = <int>{};
  for (final r in refFaces) {
    var best = -1;
    var bestIou = 0.0;
    for (var i = 0; i < result.faces.length; i++) {
      if (used.contains(i)) continue;
      final iou = FaceMath.boxIou(r.face, result.faces[i]);
      if (iou > bestIou) {
        bestIou = iou;
        best = i;
      }
    }
    if (best < 0) {
      fail('OpenCV face ${r.face} not found');
      pairs.add('missing');
      continue;
    }
    used.add(best);
    final cos = FaceMath.cosineSimilarity(r.feature, embeddings[best]);
    pairs
        .add('iou=${bestIou.toStringAsFixed(4)} cos=${cos.toStringAsFixed(4)}');
    if (bestIou < _minIou) fail('IoU ${bestIou.toStringAsFixed(4)}');
    if (cos < _minCosine) fail('cosine ${cos.toStringAsFixed(4)}');
  }
  return 'faces=${result.faces.length}/${refFaces.length} [${pairs.join('; ')}]';
}

double _meanAbsDiff(Uint8List a, Uint8List b) {
  if (a.length != b.length) return double.infinity;
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('face engine matches OpenCV FaceDetectorYN + FaceRecognizerSF',
      (tester) async {
    await tester.runAsync(() async {
      final ref =
          jsonDecode(utf8.decode(await _fetch('opencv_reference.json'))) as Map;
      final options = FaceDetectorOptions(
        scoreThreshold: (ref['score_threshold'] as num).toDouble(),
        nmsThreshold: (ref['nms_threshold'] as num).toDouble(),
        topK: ref['top_k'] as int,
        maxDetectSide: ref['max_side'] as int,
        minFaceFraction: (ref['min_face_fraction'] as num).toDouble(),
      );

      final load = Stopwatch()..start();
      await FaceEngine.warmUp();
      _log('model_load_ms=${load.elapsedMilliseconds} '
          'mode=${kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug'}');

      Future<List<Float32List>> embedAll(FaceDetectionResult r) async => [
            for (var i = 0; i < r.faces.length; i++)
              await FaceEngine.embed(r, i),
          ];

      final failures = <String>[];
      final images = (ref['images'] as List).cast<Map>();
      // Pass 0 warms JIT/ORT caches; pass 1 is timed, reported and checked.
      for (var pass = 0; pass < 2; pass++) {
        for (final entry in images) {
          final name = entry['name'] as String;
          final bytes = await _fetch(name);

          // e2e: production path, timed.
          final sw = Stopwatch()..start();
          final image = await FaceEngine.decodeImageBytes(bytes);
          final decodeMs = sw.elapsedMicroseconds / 1000;
          sw.reset();
          final result = await FaceEngine.detect(image, options: options);
          final detectMs = sw.elapsedMicroseconds / 1000;
          sw.reset();
          final embeddings = await embedAll(result);
          final embedMs = sw.elapsedMicroseconds / 1000;
          if (pass == 0) continue;

          final refFaces = <_RefFace>[
            for (final f in (entry['faces'] as List).cast<Map>())
              (
                face: FaceDetection.fromOpenCvRow(
                    [for (final v in f['row'] as List) (v as num).toDouble()]),
                feature: [
                  for (final v in f['feature'] as List) (v as num).toDouble()
                ],
              ),
          ];

          // engine: same pipeline on imread's pixels.
          final cvPixels = BgrImage(
            entry['width'] as int,
            entry['height'] as int,
            await _fetch('$name.bgr'),
          );
          final engineResult =
              await FaceEngine.detect(cvPixels, options: options);
          final engineReport = _compare('$name engine', refFaces, engineResult,
              await embedAll(engineResult), failures,
              enforce: true);

          final decodeDiff = _meanAbsDiff(image.data, cvPixels.data);
          final e2eReport = _compare(
              '$name e2e', refFaces, result, embeddings, failures,
              enforce: decodeDiff == 0);

          _log('image=$name size=${image.width}x${image.height} '
              'det=${result.detectionImage.width}x'
              '${result.detectionImage.height} '
              'decode_ms=${decodeMs.toStringAsFixed(1)} '
              'detect_ms=${detectMs.toStringAsFixed(1)} '
              'embed_ms=${embedMs.toStringAsFixed(1)} '
              'decoder_vs_imread_mean_abs=${decodeDiff.toStringAsFixed(3)}');
          _log('  engine $engineReport');
          _log('  e2e    $e2eReport');
        }
      }
      _log('failures=${failures.length} ${failures.join(' | ')}');
      expect(failures, isEmpty);
    });
  }, timeout: const Timeout(Duration(minutes: 15)));
}
