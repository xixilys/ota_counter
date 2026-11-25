// Parity of CardLocator with the desktop pipeline's locate_cards
// (~/.ota-counter/cheki_pipeline.py) on real photos.
//
// The photos are private and never enter the repository. Produce the
// reference with the desktop pipeline (scanner proposals + located cards):
//
//   python3 dump_locator.py /tmp/cheki-fix/locator_ref.json <photos...>
//
// and point OTA_CHEKI_LOCATOR_REF at it (default
// /tmp/cheki-fix/locator_ref.json). Without the file the test is skipped.
// dump_locator.py and the regression tools live outside the repository, in
// ~/.ota-counter/cheki-fix-20261126/回归脚本/.
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/card_edge_fit.dart';
import 'package:ota_counter/services/card_locator.dart';

final _ref = Platform.environment['OTA_CHEKI_LOCATOR_REF'] ??
    '/tmp/cheki-fix/locator_ref.json';

// ignore: avoid_print
void _log(String line) => print('CHEKI_LOCATOR $line');

List<Pt> _quad(dynamic json) => [
      for (final p in json as List)
        math.Point((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];

void main() {
  final file = File(_ref);
  test('CardLocator matches the desktop pipeline', () {
    final sources = jsonDecode(file.readAsStringSync()) as List;
    var matched = 0, close = 0, total = 0;
    final misses = <String>[];
    for (final source in sources.cast<Map<String, dynamic>>()) {
      final decoded =
          img.decodeImage(File(source['source'] as String).readAsBytesSync())!;
      final image = img.bakeOrientation(decoded);
      final rgb =
          image.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
      final signal = PaperSignalImage.fromRgb(rgb, image.width, image.height);
      final proposals = [
        for (final q in source['proposals'] as List) _quad(q),
      ];
      final watch = Stopwatch()..start();
      final located = CardLocator.locate(signal, proposals);
      final expected = [
        for (final c in source['located'] as List)
          (_quad(c['quad']), c['complete'] as bool),
      ];
      final name = (source['source'] as String).split('/').last;
      _log('$name: ${proposals.length} seeds -> dart ${located.length}, '
          'python ${expected.length} (${watch.elapsedMilliseconds} ms)');
      // Every Python card has a Dart card within 3 % of its diagonal, and
      // almost all within 1.5 %: where two refinements score almost the
      // same, the ports may pick different ones a few pixels apart.
      for (final (quad, complete) in expected) {
        total++;
        final diagonal = quad[0].distanceTo(quad[2]);
        double worst(List<Pt> other) => [
              for (var i = 0; i < 4; i++) quad[i].distanceTo(other[i])
            ].reduce(math.max);
        final best = located.isEmpty
            ? double.infinity
            : located.map((c) => worst(c.quad)).reduce(math.min);
        if (best <= 0.015 * diagonal) matched++;
        if (best <= 0.03 * diagonal) close++;
        if (best > 0.015 * diagonal) {
          misses.add('$name: corner error ${best.toStringAsFixed(1)} px '
              '(diag ${diagonal.toStringAsFixed(0)}, complete $complete)');
        }
      }
      expect(located.length, expected.length, reason: name);
    }
    misses.forEach(_log);
    _log('within 1.5 %: $matched / $total, within 3 %: $close / $total');
    expect(close, total);
    expect(matched, greaterThanOrEqualTo((0.95 * total).ceil()));
  }, skip: file.existsSync() ? false : 'no $_ref');
}
