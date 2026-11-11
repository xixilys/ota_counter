// Checks createMultiScan against a real photo with hand-marked corners.
// The photo stays outside the repository; set both variables to run:
//
//   OTA_SCAN_REAL_PHOTO=/path/desk.png \
//   OTA_SCAN_REAL_TRUTH=/path/desk_truth.json \
//   flutter test test/record_scan_real_photo_test.dart
//
// Truth JSON: {"sizeClass": "mini" (optional),
//              "cards": [{"corners": [[x,y] TL, TR, BR, BL]}, ...]}
// in reading order, in the photo's pixel coordinates. Optionally set
// OTA_SCAN_REAL_OUT to a directory to write the crops there.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/services/record_scan_service.dart';

void main() {
  final photo = Platform.environment['OTA_SCAN_REAL_PHOTO'];
  final truthPath = Platform.environment['OTA_SCAN_REAL_TRUTH'];
  final outDir = Platform.environment['OTA_SCAN_REAL_OUT'];
  final skip = photo == null || truthPath == null
      ? 'set OTA_SCAN_REAL_PHOTO and OTA_SCAN_REAL_TRUTH to run'
      : null;

  test('real photo: every card found with IoU ≥ 0.85', () async {
    final truth =
        jsonDecode(File(truthPath!).readAsStringSync()) as Map<String, dynamic>;
    final expected = [
      for (final card in truth['cards'] as List)
        [
          for (final c in (card as Map)['corners'] as List)
            math.Point<double>(
              ((c as List)[0] as num).toDouble(),
              (c[1] as num).toDouble(),
            ),
        ],
    ];
    final stopwatch = Stopwatch()..start();
    final result =
        await RecordScanService.createMultiScan(sourceFile: File(photo!));
    stopwatch.stop();

    final found = [
      for (final card in result.cards)
        [
          math.Point(card.quad.topLeftX, card.quad.topLeftY),
          math.Point(card.quad.topRightX, card.quad.topRightY),
          math.Point(card.quad.bottomRightX, card.quad.bottomRightY),
          math.Point(card.quad.bottomLeftX, card.quad.bottomLeftY),
        ],
    ];
    final ious = [
      for (var i = 0; i < math.min(found.length, expected.length); i++)
        _iou(found[i], expected[i]),
    ];
    // ignore: avoid_print
    print('real photo ${result.sourceWidth}×${result.sourceHeight}: '
        '${found.length}/${expected.length} cards, wall '
        '${stopwatch.elapsedMilliseconds} ms, stages '
        '${result.stageMilliseconds}\n'
        'IoU in reading order: '
        '${ious.map((v) => v.toStringAsFixed(3)).toList()}\n'
        'size classes: ${result.cards.map((c) => c.sizeClass.name).toList()}, '
        'ratios: ${result.cards.map((c) => c.aspectRatio.toStringAsFixed(3)).toList()}\n'
        'warnings: ${result.warnings.map((w) => w.name).toList()}');
    if (outDir != null) {
      final dir = Directory(outDir)..createSync(recursive: true);
      for (var i = 0; i < result.cards.length; i++) {
        File('${dir.path}/card_${i.toString().padLeft(2, '0')}.jpg')
            .writeAsBytesSync(result.cards[i].bytes);
      }
      File('${dir.path}/quads.json').writeAsStringSync(jsonEncode([
        for (final q in found)
          [
            for (final p in q) [p.x, p.y]
          ],
      ]));
    }

    expect(found, hasLength(expected.length));
    for (var i = 0; i < expected.length; i++) {
      expect(ious[i], greaterThanOrEqualTo(0.85), reason: 'card $i');
      expect(result.cards[i].quad.isUsable(), isTrue, reason: 'card $i');
    }
    final sizeClass = truth['sizeClass'] as String?;
    if (sizeClass != null) {
      for (var i = 0; i < result.cards.length; i++) {
        expect(result.cards[i].sizeClass.name, sizeClass, reason: 'card $i');
      }
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}

double _area(List<math.Point<double>> p) {
  var sum = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i];
    final b = p[(i + 1) % p.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2;
}

double _iou(List<math.Point<double>> a, List<math.Point<double>> b) {
  final sign = _area(b).sign;
  var output = a;
  for (var i = 0; i < b.length && output.isNotEmpty; i++) {
    final p = b[i];
    final q = b[(i + 1) % b.length];
    double side(math.Point<double> r) =>
        sign * ((q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x));
    final input = output;
    output = [];
    for (var j = 0; j < input.length; j++) {
      final cur = input[j];
      final prev = input[(j + input.length - 1) % input.length];
      final sc = side(cur);
      final sp = side(prev);
      if (sc >= 0) {
        if (sp < 0) output.add(prev + (cur - prev) * (sp / (sp - sc)));
        output.add(cur);
      } else if (sp >= 0) {
        output.add(prev + (cur - prev) * (sp / (sp - sc)));
      }
    }
  }
  final inter = output.length < 3 ? 0.0 : _area(output).abs();
  return inter / (_area(a).abs() + _area(b).abs() - inter);
}
