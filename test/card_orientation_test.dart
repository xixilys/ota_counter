import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/album_orientation_service.dart';
import 'package:ota_counter/services/card_edge_fit.dart';
import 'package:ota_counter/services/card_orientation.dart';

typedef _Pt = math.Point<double>;

CardOrientation _decide(int w, int h, int? layout, {int? face, int? text}) =>
    CardOrientationDecider.decide(
        width: w,
        height: h,
        layoutTurns: layout,
        faceTurns: face,
        textTurns: text);

/// A light card with a dark picture window on a grey table.
(PaperSignalImage, List<_Pt>) _desk() {
  const width = 400, height = 400;
  final image = img.Image(width: width, height: height)
    ..clear(img.ColorRgb8(95, 95, 95));
  final card = [
    const math.Point(120.0, 60.0),
    const math.Point(282.0, 66.0),
    const math.Point(276.0, 324.0),
    const math.Point(114.0, 318.0),
  ];
  bool inside(List<_Pt> q, double x, double y) {
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4];
      if ((b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) < 0) return false;
    }
    return true;
  }

  final window = [
    const math.Point(133.0, 73.0),
    const math.Point(269.0, 78.0),
    const math.Point(265.0, 258.0),
    const math.Point(129.0, 253.0),
  ];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (inside(window, x + .5, y + .5)) {
        image.setPixelRgb(x, y, 40, 45, 60);
      } else if (inside(card, x + .5, y + .5)) {
        image.setPixelRgb(x, y, 244, 244, 240);
      }
    }
  }
  final rgb = image.getBytes(order: img.ChannelOrder.rgb);
  return (PaperSignalImage.fromRgb(rgb, width, height), card);
}

double _worst(List<_Pt> a, List<_Pt> b) =>
    [for (var i = 0; i < 4; i++) a[i].distanceTo(b[i])].reduce(math.max);

void main() {
  group('orientation from thick border + faces', () {
    test('a portrait cut with the border at the bottom stays', () {
      final o = _decide(854, 1360, 0);
      expect(o.turns, 0);
      expect(o.basis, CardOrientationBasis.filmLayout);
      expect(o.lowConfidence, isFalse);
    });

    test('border and face agree: the sideways mini stands up', () {
      final o = _decide(1360, 854, 1, face: 1);
      expect(o.turns, 1);
      expect(o.basis, CardOrientationBasis.filmLayoutAndFace);
      expect(o.clockwiseDegrees, 270);
      expect(o.lowConfidence, isFalse);
    });

    test('a portrait picture on WIDE film follows the face', () {
      // The thick border is at the top (layout 2), the face is sideways:
      // the print is composed upright across the film.
      final o = _decide(1360, 1083, 2, face: 1);
      expect(o.turns, 1);
      expect(o.basis, CardOrientationBasis.face);
      expect(o.lowConfidence, isFalse);
    });

    test('no face: the border alone keeps the cut, low confidence', () {
      final o = _decide(1360, 854, 3);
      expect(o.turns, 0);
      expect(o.basis, CardOrientationBasis.sourceUnconfirmed);
      expect(o.lowConfidence, isTrue);
    });

    test('face and border opposite: kept, low confidence', () {
      final o = _decide(1360, 854, 1, face: 3);
      expect(o.turns, 0);
      expect(o.basis, CardOrientationBasis.conflicting);
      expect(o.lowConfidence, isTrue);
    });

    test('portrait cut with the border on a side is kept', () {
      expect(
          _decide(1083, 1360, 1, face: 0),
          isA<CardOrientation>()
              .having((o) => o.turns, 'turns', 0)
              .having(
                  (o) => o.basis, 'basis', CardOrientationBasis.sourceUpright)
              .having((o) => o.lowConfidence, 'low', false));
      expect(_decide(1083, 1360, 1).lowConfidence, isTrue);
    });

    test('an upside-down portrait turns only with an agreeing face', () {
      expect(_decide(854, 1360, 2, face: 2).turns, 2);
      final sideways = _decide(854, 1360, 2, face: 1);
      expect(sideways.turns, 0);
      expect(sideways.lowConfidence, isTrue);
    });

    test('handwriting hook corroborates the border', () {
      final o = _decide(1360, 854, 1, text: 1);
      expect(o.turns, 1);
      expect(o.basis, CardOrientationBasis.filmLayoutAndText);
      expect(_decide(1360, 854, 1, text: 0).lowConfidence, isTrue);
    });

    test('without a film format only a face can turn it', () {
      expect(_decide(1360, 900, null).lowConfidence, isTrue);
      expect(_decide(1360, 900, null, face: 3).turns, 3);
    });

    test('face direction needs a strong, clear winner', () {
      int? turns(Map<int, double> s, {int? layout}) =>
          CardOrientationDecider.faceTurns(s, layoutTurns: layout);
      expect(turns({1: .85}), 1);
      expect(turns({2: .66}), isNull); // too weak
      expect(turns({0: .80, 1: .70}), isNull); // not clear
      // A lead of .14 is enough only when the border agrees.
      expect(turns({0: .68, 1: .82}), isNull);
      expect(turns({0: .68, 1: .82}, layout: 1), 1);
      expect(turns({0: .68, 1: .82}, layout: 3), isNull);
    });
  });

  group('cut along the paper edge', () {
    test('a loose outline snaps to the card', () {
      final (signal, card) = _desk();
      final loose = [
        math.Point(card[0].x - 9, card[0].y - 7),
        math.Point(card[1].x + 8, card[1].y - 9),
        math.Point(card[2].x + 9, card[2].y + 8),
        math.Point(card[3].x - 7, card[3].y + 9),
      ];
      final fitted = CardEdgeFit.refineQuad(signal, loose);
      expect(_worst(fitted, card), lessThan(2.5));
    });

    test('a sliver of background is trimmed, a tight cut is kept', () {
      final (signal, card) = _desk();
      // 3 px of table along the right side.
      final sliver = [
        card[0],
        math.Point(card[1].x + 3, card[1].y),
        math.Point(card[2].x + 3, card[2].y),
        card[3],
      ];
      final tight = CardEdgeFit.tightenPaperEdges(signal, sliver);
      expect(_worst(tight, card), lessThan(1.5));
      final inset = [
        for (final p in card)
          math.Point(
              p.x + (p.x < 200 ? 1.0 : -1.0), p.y + (p.y < 200 ? 1.0 : -1.0)),
      ];
      expect(
          identical(CardEdgeFit.tightenPaperEdges(signal, inset), inset), true);
    });
  });

  test('face input: equalized grey, turned counter-clockwise', () {
    final card = img.Image(width: 300, height: 200)
      ..clear(img.ColorRgb8(150, 20, 30));
    img.fillRect(card,
        x1: 0, y1: 0, x2: 29, y2: 199, color: img.ColorRgb8(240, 240, 240));
    final inputs = AlbumOrientationService.faceInputs(card);
    expect(inputs[0]!.width, AlbumOrientationService.faceInputSide);
    final p = inputs[0]!.getPixel(320, 100);
    expect(p.r, p.g);
    expect(p.g, p.b);
    // One turn counter-clockwise puts the light left strip at the bottom.
    final turned = inputs[1]!;
    expect(turned.height, AlbumOrientationService.faceInputSide);
    expect(turned.getPixel(100, turned.height - 5).r,
        greaterThan(turned.getPixel(100, 5).r));
  });
}
