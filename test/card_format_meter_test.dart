// CardFormatMeter: film format from outline + all four window margins,
// neighbours' size as a weaker vote, measured proportions when unsure.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/services/card_format_meter.dart';

const _size = CardFormatMeter.previewSize;

/// A rectified card: white paper, a dark picture window at the given
/// margins (top, right, bottom, left as fractions of the card).
Uint8List _card(List<double> margins, {bool window = true}) {
  final rgb = Uint8List(_size * _size * 3);
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      final fx = x / (_size - 1), fy = y / (_size - 1);
      final inside = window &&
          fy > margins[0] &&
          fx < 1 - margins[1] &&
          fy < 1 - margins[2] &&
          fx > margins[3];
      final i = (y * _size + x) * 3;
      rgb[i] = inside ? 60 : 238;
      rgb[i + 1] = inside ? 50 : 238;
      rgb[i + 2] = inside ? 55 : 236;
    }
  }
  return rgb;
}

/// Upright margins of [format], turned [turns] quarter turns.
List<double> _margins(FilmFormat format, int turns) {
  final x = (1 - format.printWidth / format.width) / 2;
  final y = 1 - format.printHeight / format.height;
  final upright = [x, x, y - x, x];
  return [for (var s = 0; s < 4; s++) upright[(s - turns) % 4]];
}

CardMeasurement _measured(FilmFormat format,
    {int turns = 0, double stretch = 1, bool window = true, double scale = 1}) {
  var w = format.width * scale, h = format.height * scale;
  if (turns.isOdd) (w, h) = (h, w);
  final (offsets, profiles) = CardFormatMeter.windowProfiles(
      CardFormatMeter.paperSignal(
          _card(_margins(format, turns), window: window), _size),
      _size);
  return CardMeasurement(
    axisWidth: w * stretch,
    axisHeight: h,
    relativeSize: math.max(w * stretch, h),
    candidates:
        CardFormatMeter.measureFormats(offsets, profiles, [w * stretch, h]),
  );
}

void main() {
  test('mini, WIDE and SQUARE are told apart by outline and window', () {
    final decisions = CardFormatMeter.decide([
      _measured(FilmFormat.mini),
      _measured(FilmFormat.wide),
      _measured(FilmFormat.square),
    ]);
    expect([for (final d in decisions) d.format],
        [FilmFormat.mini, FilmFormat.wide, FilmFormat.square]);
    expect(decisions[0].portrait, isTrue);
    expect(decisions[1].portrait, isFalse);
    expect(decisions[0].aspectRatio, closeTo(54 / 86, 1e-9));
  });

  test('a card lying sideways keeps its turn in the output frame', () {
    final d = CardFormatMeter.decide([_measured(FilmFormat.mini, turns: 1)]);
    expect(d.single.format, FilmFormat.mini);
    expect(d.single.portrait, isFalse, reason: '横放的三寸按横向裁，之后再按人脸转正');
  });

  test('a slightly stretched outline is still snapped to its format', () {
    final d = CardFormatMeter.decide([_measured(FilmFormat.mini, stretch: 1.06)]);
    expect(d.single.format, FilmFormat.mini);
    expect(d.single.aspectRatio, closeTo(54 / 86, 1e-9));
  });

  test('without a picture window the measured proportions are kept', () {
    final d = CardFormatMeter.decide(
        [_measured(FilmFormat.mini, window: false, stretch: 1.1)]);
    expect(d.single.format, isNull);
    expect(d.single.width / d.single.height, closeTo(54 * 1.1 / 86, 1e-9),
        reason: '证据不足不硬拉');
  });

  test('the size vote of mini neighbours does not override a clear WIDE',
      () {
    // Same photo, same scale: a WIDE is larger than its mini neighbours.
    final decisions = CardFormatMeter.decide([
      _measured(FilmFormat.mini),
      _measured(FilmFormat.mini),
      _measured(FilmFormat.wide),
    ]);
    expect([for (final d in decisions) d.format],
        [FilmFormat.mini, FilmFormat.mini, FilmFormat.wide]);
  });

  test('a card twice the peers\' scale loses confidence, not its format', () {
    final normal = CardFormatMeter.decide([
      _measured(FilmFormat.mini),
      _measured(FilmFormat.mini),
      _measured(FilmFormat.mini),
    ]).last;
    final oversized = CardFormatMeter.decide([
      _measured(FilmFormat.mini),
      _measured(FilmFormat.mini),
      _measured(FilmFormat.mini, scale: 2),
    ]).last;
    expect(oversized.format, FilmFormat.mini);
    expect(oversized.confidence, lessThanOrEqualTo(normal.confidence));
  });

  test('a fronto-parallel card keeps its true proportions', () {
    // Unit square → axis-aligned 200 × 318 rectangle centred in the image.
    const w = 200.0, h = 318.0, left = 300.0, top = 200.0;
    final (a0, a1, size) = CardFormatMeter.projectedDimensions(
        [w, 0, left, 0, h, top, 0, 0], 800, 718);
    expect(a0 / a1, closeTo(w / h, 1e-6));
    expect(size, greaterThan(0));
  });
}
