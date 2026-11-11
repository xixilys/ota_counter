import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/record_scan_service.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('record_scan_multi_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<File> writeJpg(img.Image image, String name) async {
    final file = File('${tempDir.path}/$name.jpg');
    await file.writeAsBytes(img.encodeJpg(image, quality: 92));
    return file;
  }

  group('RecordScanService.createMultiScan', () {
    test('2×2 grid: four cards, each box matches ground truth', () async {
      final cards = _grid(
        columns: 2,
        rows: 2,
        canvasWidth: 1800,
        canvasHeight: 1350,
        cardWidth: 440,
        cardHeight: 550,
      );
      final file = await writeJpg(_render(1800, 1350, cards), 'grid2x2');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      expect(result.warnings, isEmpty);
      for (final card in result.cards) {
        expect(card.sizeClass, RecordScanCardSize.wide);
        _expectDecodableCrop(card, portrait: true);
      }
    });

    test('3×2 grid with 五寸 and 三寸 rows, timing printed', () async {
      const wideWidth = 360.0;
      const wideHeight = 450.0;
      const miniWidth = 54 / 86 * 450;
      final cards = [
        for (var i = 0; i < 3; i++)
          _Card(
            cx: 330 + i * 570,
            cy: 340,
            width: wideWidth,
            height: wideHeight,
            angle: [-4.0, 0.0, 6.0][i],
          ),
        for (var i = 0; i < 3; i++)
          _Card(
            cx: 330 + i * 570,
            cy: 990,
            width: miniWidth,
            height: 450,
            angle: [3.0, -7.0, 0.0][i],
            photoTint: 1,
          ),
      ];
      final file = await writeJpg(_render(1800, 1350, cards), 'grid3x2');
      final stopwatch = Stopwatch()..start();
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      stopwatch.stop();
      // ignore: avoid_print
      print('createMultiScan 1800×1350, 6 cards: wall '
          '${stopwatch.elapsedMilliseconds} ms, stages '
          '${result.stageMilliseconds}');
      _expectMatches(result, cards);
      expect(result.warnings, isEmpty);
      for (var i = 0; i < 6; i++) {
        expect(result.cards[i].sizeClass,
            i < 3 ? RecordScanCardSize.wide : RecordScanCardSize.mini,
            reason: 'card $i ratio ${result.cards[i].aspectRatio}');
        _expectDecodableCrop(result.cards[i], portrait: true);
      }
    });

    test('different rotation per card is corrected independently', () async {
      final angles = [-22.0, -9.0, 14.0, 26.0];
      final cards = [
        for (var i = 0; i < 4; i++)
          _Card(
            cx: 470 + (i % 2) * 860,
            cy: 360 + (i ~/ 2) * 650,
            width: 360,
            height: 450,
            angle: angles[i],
          ),
      ];
      final file = await writeJpg(_render(1800, 1350, cards), 'rotated');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      for (final card in result.cards) {
        // Deskewed: the white frame reaches all four corners of the crop.
        _expectDecodableCrop(card, portrait: true, whiteCorners: true);
      }
    });

    test('very dark textured background', () async {
      final cards = _grid(
        columns: 3,
        rows: 2,
        canvasWidth: 1800,
        canvasHeight: 1200,
        cardWidth: 320,
        cardHeight: 400,
      );
      final file = await writeJpg(
        _render(1800, 1200, cards, background: _Background.dark),
        'dark',
      );
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      expect(result.warnings, isEmpty);
    });

    test('mid-gray background is separated with an adaptive threshold',
        () async {
      final cards = _grid(
        columns: 2,
        rows: 2,
        canvasWidth: 1800,
        canvasHeight: 1350,
        cardWidth: 400,
        cardHeight: 500,
      );
      final file = await writeJpg(
        _render(1800, 1350, cards, background: _Background.midGray),
        'gray',
      );
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      expect(result.warnings, isEmpty);
    });

    test('near-white background warns instead of cutting', () async {
      final cards = _grid(
        columns: 2,
        rows: 2,
        canvasWidth: 1800,
        canvasHeight: 1350,
        cardWidth: 400,
        cardHeight: 500,
      );
      final file = await writeJpg(
        _render(1800, 1350, cards, background: _Background.light),
        'light',
      );
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      expect(result.warnings, contains(RecordScanMultiWarning.lightBackground));
      expect(result.cards, isEmpty);
    });

    test('two cards touching are split, a separate third stays whole',
        () async {
      final cards = [
        const _Card(cx: 380, cy: 600, width: 400, height: 500),
        const _Card(cx: 780, cy: 600, width: 400, height: 500, photoTint: 1),
        const _Card(cx: 1420, cy: 600, width: 400, height: 500, angle: 8),
      ];
      final file = await writeJpg(_render(1800, 1200, cards), 'touching');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      expect(result.warnings, contains(RecordScanMultiWarning.possiblyMerged));
      expect(result.cards.where((c) => c.splitFromMerged), hasLength(2));
    });

    test('tilt beyond the single-card 28° limit is pre-rotated then deskewed',
        () async {
      final cards = [
        const _Card(cx: 480, cy: 600, width: 400, height: 500, angle: 38),
        const _Card(cx: 1320, cy: 600, width: 400, height: 500),
      ];
      final file = await writeJpg(_render(1800, 1200, cards), 'steep');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      _expectDecodableCrop(result.cards.first,
          portrait: true, whiteCorners: true);
    });

    test('2×2 block of touching cards warns and does not guess a cut',
        () async {
      final cards = [
        for (var i = 0; i < 4; i++)
          _Card(
            cx: 700 + (i % 2) * 400,
            cy: 350 + (i ~/ 2) * 500,
            width: 400,
            height: 500,
            photoTint: i % 3,
          ),
      ];
      final file = await writeJpg(_render(1800, 1200, cards), 'block');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      expect(result.warnings, contains(RecordScanMultiWarning.possiblyMerged));
      expect(result.cards, isEmpty);
    });

    test('single card matches createBasicScan exactly', () async {
      final file = await writeJpg(_buildSyntheticPolaroid(), 'single');
      final multi = await RecordScanService.createMultiScan(sourceFile: file);
      final basic = await RecordScanService.createBasicScan(sourceFile: file);
      expect(multi.cards, hasLength(1));
      expect(multi.cards.single.bytes, orderedEquals(basic.bytes));
      final truth = [
        const math.Point<double>(280, 220),
        const math.Point<double>(800, 220),
        const math.Point<double>(800, 870),
        const math.Point<double>(280, 870),
      ];
      expect(_iou(_quadPoints(multi.cards.single.quad), truth),
          greaterThanOrEqualTo(0.85));
      expect(multi.warnings, isEmpty);
    });

    // Layouts that defeat a white-blob detector: busy colourful or pale
    // backgrounds, cards touching, sleeves, writing on the borders. Each
    // card must still come out alone, in reading order, as instax mini.
    Future<void> expectMiniCards(
      String name,
      int width,
      int height,
      List<_Card> cards, {
      required _Background background,
    }) async {
      final file = await writeJpg(
          _render(width, height, cards, background: background), name);
      final stopwatch = Stopwatch()..start();
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      // ignore: avoid_print
      print('$name: ${stopwatch.elapsedMilliseconds} ms');
      _expectMatches(result, cards);
      for (var i = 0; i < cards.length; i++) {
        expect(result.cards[i].sizeClass, RecordScanCardSize.mini,
            reason: 'card $i ratio ${result.cards[i].aspectRatio}');
        _expectDecodableCrop(result.cards[i], portrait: true);
      }
    }

    test('saturated patterned background (mouse pad)', () async {
      await expectMiniCards(
        'saturated',
        1600,
        1200,
        [
          for (var i = 0; i < 6; i++)
            _Card.mini(
              cx: 300 + (i % 3) * 500,
              cy: 320 + (i ~/ 3) * 560,
              height: 440,
              angle: [-3.0, 2.0, 5.0, 4.0, -2.0, 0.0][i],
              photoTint: i % 3,
            ),
        ],
        background: _Background.saturated,
      );
    });

    test('two rows of white cards 0–3 px apart or slightly overlapping',
        () async {
      const height = 440.0;
      const width = height * 54 / 86;
      // Gaps to the right neighbour, per row; negative overlaps.
      const gaps = [
        [1.0, 3.0, -3.0],
        [2.0, 0.0, 3.0],
      ];
      const rowGap = 2.0;
      final cards = <_Card>[];
      for (var r = 0; r < 2; r++) {
        var left = 260.0;
        for (var c = 0; c < 4; c++) {
          cards.add(_Card.mini(
            cx: left + width / 2,
            cy: 140 + height / 2 + r * (height + rowGap),
            height: height,
            photoTint: (r + c) % 3,
          ));
          if (c < 3) left += width + gaps[r][c];
        }
      }
      await expectMiniCards('gaps', 1600, 1200, cards,
          background: _Background.textured);
    });

    test('cards in grey translucent sleeves touching on a pale desk', () async {
      await expectMiniCards(
        'sleeves',
        1600,
        900,
        [
          const _Card.mini(
              cx: 380, cy: 450, height: 500, angle: -1, sleeve: true),
          const _Card.mini(
              cx: 380 + 314 + 22,
              cy: 450,
              height: 500,
              photoTint: 1,
              sleeve: true,
              // Reaches over the neighbours' sleeves (22 px apart).
              sleeveMargin: 14),
          const _Card.mini(
              cx: 380 + 2 * (314 + 22),
              cy: 450,
              height: 500,
              angle: 2,
              photoTint: 2,
              sleeve: true),
        ],
        background: _Background.paleDesk,
      );
    });

    test('coloured marker writing on the white borders', () async {
      await expectMiniCards(
        'ink',
        1500,
        1200,
        [
          for (var i = 0; i < 4; i++)
            _Card.mini(
              cx: 420 + (i % 2) * 660,
              cy: 310 + (i ~/ 2) * 590,
              height: 480,
              angle: [-4.0, 3.0, 2.0, -1.0][i],
              photoTint: i % 3,
              ink: true,
            ),
        ],
        background: _Background.saturated,
      );
    });

    test('two backgrounds: mouse pad above, pale desk below', () async {
      await expectMiniCards(
        'split',
        1800,
        1200,
        [
          for (var i = 0; i < 6; i++)
            _Card.mini(
              cx: 330 + (i % 3) * 570,
              cy: i < 3 ? 300 : 900,
              height: 440,
              angle: [-3.0, 2.0, 0.0, 3.0, -2.0, 1.0][i],
              photoTint: i % 3,
              ink: i.isOdd,
            ),
        ],
        background: _Background.split,
      );
    });

    test('empty table reports nothing detected', () async {
      final file = await writeJpg(_render(1200, 900, const []), 'empty');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      expect(result.cards, isEmpty);
      expect(result.warnings, contains(RecordScanMultiWarning.noneDetected));
    });
  });
}

class _Card {
  final double cx;
  final double cy;
  final double width;
  final double height;
  final double angle;
  final int photoTint;

  /// instax mini border widths (4 / 7 / 17 mm on a 54 × 86 mm card)
  /// instead of the default proportions.
  final bool miniBorders;

  /// Grey translucent sleeve reaching [sleeveMargin] px past the card.
  final bool sleeve;
  final double sleeveMargin;

  /// Coloured marker writing on the white border.
  final bool ink;

  const _Card({
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
    this.angle = 0,
    this.photoTint = 0,
  })  : miniBorders = false,
        sleeve = false,
        sleeveMargin = 0,
        ink = false;

  /// instax mini of the given height, 54 : 86.
  const _Card.mini({
    required this.cx,
    required this.cy,
    required this.height,
    this.angle = 0,
    this.photoTint = 0,
    this.sleeve = false,
    this.sleeveMargin = 10,
    this.ink = false,
  })  : width = height * 54 / 86,
        miniBorders = true;

  /// TL, TR, BR, BL of the card's outer frame.
  List<math.Point<double>> get corners {
    final rad = angle * math.pi / 180;
    final c = math.cos(rad);
    final s = math.sin(rad);
    math.Point<double> at(double u, double v) =>
        math.Point(cx + u * c - v * s, cy + u * s + v * c);
    final hw = width / 2;
    final hh = height / 2;
    return [at(-hw, -hh), at(hw, -hh), at(hw, hh), at(-hw, hh)];
  }
}

enum _Background {
  textured,
  dark,
  midGray,
  light,

  /// Saturated colour blobs, like a printed mouse pad.
  saturated,

  /// [saturated] above, a pale grey desk below.
  split,

  /// Pale grey desk, close to the white of the borders.
  paleDesk,
}

List<_Card> _grid({
  required int columns,
  required int rows,
  required double canvasWidth,
  required double canvasHeight,
  required double cardWidth,
  required double cardHeight,
}) {
  return [
    for (var r = 0; r < rows; r++)
      for (var c = 0; c < columns; c++)
        _Card(
          cx: canvasWidth * (c + 0.5) / columns,
          cy: canvasHeight * (r + 0.5) / rows,
          width: cardWidth,
          height: cardHeight,
          photoTint: (r + c) % 3,
        ),
  ];
}

img.Image _render(
  int width,
  int height,
  List<_Card> cards, {
  _Background background = _Background.textured,
}) {
  final image = img.Image(width: width, height: height);
  final random = math.Random(7);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      switch (background) {
        case _Background.textured:
          if ((x + y) % 23 == 0) {
            image.setPixelRgba(x, y, 48, 42, 42, 255);
          } else {
            image.setPixelRgba(x, y, 28, 24, 24, 255);
          }
        case _Background.dark:
          final n = random.nextInt(14);
          image.setPixelRgba(x, y, 8 + n, 10 + n, 16 + n, 255);
        case _Background.midGray:
          final n = random.nextInt(10);
          image.setPixelRgba(x, y, 165 + n, 164 + n, 160 + n, 255);
        case _Background.light:
          final n = random.nextInt(6);
          image.setPixelRgba(x, y, 230 + n, 228 + n, 224 + n, 255);
        case _Background.saturated:
          final (r, g, b) = _saturatedAt(x, y);
          image.setPixelRgba(x, y, r, g, b, 255);
        case _Background.split:
          if (y < height / 2) {
            final (r, g, b) = _saturatedAt(x, y);
            image.setPixelRgba(x, y, r, g, b, 255);
          } else {
            final n = random.nextInt(6);
            image.setPixelRgba(x, y, 196 + n, 195 + n, 192 + n, 255);
          }
        case _Background.paleDesk:
          final n = random.nextInt(6);
          image.setPixelRgba(x, y, 200 + n, 199 + n, 196 + n, 255);
      }
    }
  }
  for (final card in cards) {
    if (card.sleeve) {
      _paintSleeve(image, card);
    }
    _paintCard(image, card);
  }
  return image;
}

/// Hue swirling over the canvas at high saturation, including bright
/// yellows that are as light as a white border but strongly coloured.
(int, int, int) _saturatedAt(int x, int y) {
  final hue =
      (math.sin(x / 61) + math.cos(y / 47) + math.sin((x + y) / 113)) * 120 +
          360;
  final value = 0.62 + 0.3 * math.sin(x / 29 + y / 41).abs();
  return _hsv(hue % 360, 0.85, value);
}

(int, int, int) _hsv(double h, double s, double v) {
  final c = v * s;
  final x = c * (1 - ((h / 60) % 2 - 1).abs());
  final m = v - c;
  final (r, g, b) = switch (h ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return (
    ((r + m) * 255).round(),
    ((g + m) * 255).round(),
    ((b + m) * 255).round(),
  );
}

/// Grey translucent sleeve: the card and a margin around it seen through
/// slightly milky plastic.
void _paintSleeve(img.Image image, _Card card) {
  final rad = card.angle * math.pi / 180;
  final c = math.cos(rad);
  final s = math.sin(rad);
  final hw = card.width / 2 + card.sleeveMargin;
  final hh = card.height / 2 + card.sleeveMargin;
  final reach = math.sqrt(hw * hw + hh * hh).ceil();
  for (var y = math.max(0, (card.cy - reach).floor());
      y <= math.min(image.height - 1, (card.cy + reach).ceil());
      y++) {
    for (var x = math.max(0, (card.cx - reach).floor());
        x <= math.min(image.width - 1, (card.cx + reach).ceil());
        x++) {
      final dx = x + 0.5 - card.cx;
      final dy = y + 0.5 - card.cy;
      final u = dx * c + dy * s;
      final v = -dx * s + dy * c;
      if (u.abs() >= hw || v.abs() >= hh) continue;
      final p = image.getPixel(x, y);
      image.setPixelRgba(
          x,
          y,
          (p.r * 0.78 + 150 * 0.22).round(),
          (p.g * 0.78 + 150 * 0.22).round(),
          (p.b * 0.78 + 156 * 0.22).round(),
          255);
    }
  }
}

/// Polaroid-like card: white frame (thick bottom) around a dark photo.
void _paintCard(img.Image image, _Card card) {
  final rad = card.angle * math.pi / 180;
  final c = math.cos(rad);
  final s = math.sin(rad);
  final hw = card.width / 2;
  final hh = card.height / 2;
  final side = card.width * (card.miniBorders ? 4 / 54 : 0.073);
  final top = card.height * (card.miniBorders ? 7 / 86 : 0.06);
  final bottom = card.height * (card.miniBorders ? 17 / 86 : 0.17);
  // Seen through a sleeve everything is a little greyer.
  int veil(double value, int grey) =>
      card.sleeve ? (value * 0.86 + grey * 0.14).round() : value.round();
  final corners = card.corners;
  final minX = corners.map((p) => p.x).reduce(math.min).floor();
  final maxX = corners.map((p) => p.x).reduce(math.max).ceil();
  final minY = corners.map((p) => p.y).reduce(math.min).floor();
  final maxY = corners.map((p) => p.y).reduce(math.max).ceil();
  for (var y = math.max(0, minY); y <= math.min(image.height - 1, maxY); y++) {
    for (var x = math.max(0, minX); x <= math.min(image.width - 1, maxX); x++) {
      final dx = x + 0.5 - card.cx;
      final dy = y + 0.5 - card.cy;
      final u = dx * c + dy * s;
      final v = -dx * s + dy * c;
      if (u < -hw || u >= hw || v < -hh || v >= hh) {
        continue;
      }
      final inPhoto =
          u >= -hw + side && u < hw - side && v >= -hh + top && v < hh - bottom;
      if (!inPhoto) {
        final inkColor = card.ink ? _inkAt(u + hw, v + hh, card) : null;
        final (r, g, b) = inkColor ?? (240, 238, 236);
        image.setPixelRgba(x, y, veil(r.toDouble(), 160),
            veil(g.toDouble(), 160), veil(b.toDouble(), 166), 255);
        continue;
      }
      final mix = (u + hw) / card.width;
      final shade = (v + hh) / card.height;
      final (r, g, b) = switch (card.photoTint) {
        0 => (60 + mix * 30, 78 + mix * 20, 122 + mix * 55),
        1 => (120 + mix * 40, 70 + shade * 30, 60 + mix * 20),
        _ => (50 + shade * 30, 110 + mix * 40, 70 + mix * 20),
      };
      image.setPixelRgba(x, y, veil(r, 160), veil(g, 160), veil(b, 166), 255);
    }
  }
}

/// Marker writing on the border, in card coordinates from the top-left
/// corner: a dated line and a heart in the thick bottom border, a word
/// along the top and strokes down the left side, in blue and pink.
(int, int, int)? _inkAt(double u, double v, _Card card) {
  final w = card.width;
  final h = card.height;
  final stroke = math.max(2.0, w * 0.012);
  const blue = (70, 150, 235);
  const pink = (240, 96, 176);
  // Wavy handwriting line in the bottom border.
  final baseline = h * 0.9;
  if (u > w * 0.12 && u < w * 0.86) {
    final wave = baseline + math.sin(u / (w * 0.035)) * h * 0.022;
    if ((v - wave).abs() < stroke) return blue;
    // Letters: short vertical strokes rising from the line.
    final phase = (u / (w * 0.06)) % 1;
    if (phase < 0.18 && v < wave && v > wave - h * 0.045) return blue;
  }
  // Heart-ish ring near the bottom right.
  final hx = u - w * 0.8, hy = v - h * 0.86;
  final ring = math.sqrt(hx * hx + hy * hy);
  if ((ring - w * 0.05).abs() < stroke * 0.8) return pink;
  // Word along the top border.
  if (u > w * 0.25 && u < w * 0.7 && (v - h * 0.035).abs() < stroke * 0.8) {
    return pink;
  }
  // Short strokes on the left border.
  if (u < w * 0.06 &&
      u > w * 0.02 &&
      (v / (h * 0.08)) % 1 < 0.25 &&
      v > h * 0.3 &&
      v < h * 0.6) {
    return blue;
  }
  return null;
}

img.Image _buildSyntheticPolaroid() {
  final image = img.Image(width: 1200, height: 1600);
  img.fill(image, color: img.ColorRgb8(28, 24, 24));
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      if ((x + y) % 23 == 0) {
        image.setPixelRgba(x, y, 48, 42, 42, 255);
      }
    }
  }
  for (var y = 220; y < 870; y++) {
    for (var x = 280; x < 800; x++) {
      image.setPixelRgba(x, y, 240, 238, 236, 255);
    }
  }
  for (var y = 258; y < 760; y++) {
    for (var x = 318; x < 762; x++) {
      final mix = (x - 318) / 444;
      image.setPixelRgba(x, y, (60 + mix * 30).round(), (78 + mix * 20).round(),
          (122 + mix * 55).round(), 255);
    }
  }
  for (var y = 260; y < 360; y++) {
    for (var x = 900; x < 1040; x++) {
      image.setPixelRgba(x, y, 226, 226, 226, 255);
    }
  }
  return image;
}

/// Same count as ground truth, reading order preserved, IoU ≥ 0.85 each.
void _expectMatches(RecordScanMultiResult result, List<_Card> truth) {
  final found = result.cards.map((c) => _quadPoints(c.quad)).toList();
  final ious = [
    for (var i = 0; i < math.min(found.length, truth.length); i++)
      _iou(found[i], truth[i].corners).toStringAsFixed(3),
  ];
  // ignore: avoid_print
  print('detected ${found.length}/${truth.length}, IoU in reading order: '
      '$ious, warnings: ${result.warnings.map((w) => w.name).toList()}');
  expect(found, hasLength(truth.length));
  for (var i = 0; i < truth.length; i++) {
    expect(_iou(found[i], truth[i].corners), greaterThanOrEqualTo(0.85),
        reason: 'card $i');
    expect(result.cards[i].quad.isUsable(), isTrue, reason: 'card $i quad');
    expect(result.cards[i].confidence, inInclusiveRange(0.4, 1.0));
  }
}

void _expectDecodableCrop(
  RecordScanMultiCard card, {
  required bool portrait,
  bool whiteCorners = false,
}) {
  final decoded = img.decodeJpg(Uint8List.fromList(card.bytes));
  expect(decoded, isNotNull);
  final image = decoded!;
  expect(image.height >= image.width, portrait);
  final center = image.getPixel(image.width ~/ 2, image.height ~/ 2);
  // Photo area, not frame or background.
  expect(center.r + center.g + center.b, lessThan(3 * 200));
  if (whiteCorners) {
    for (final (x, y) in [
      (12, 12),
      (image.width - 13, 12),
      (12, image.height - 13),
      (image.width - 13, image.height - 13),
    ]) {
      final pixel = image.getPixel(x, y);
      expect(pixel.r, greaterThan(170), reason: 'corner ($x,$y) $pixel');
      expect(pixel.g, greaterThan(170), reason: 'corner ($x,$y) $pixel');
    }
  }
}

List<math.Point<double>> _quadPoints(RecordScanQuad q) => [
      math.Point(q.topLeftX, q.topLeftY),
      math.Point(q.topRightX, q.topRightY),
      math.Point(q.bottomRightX, q.bottomRightY),
      math.Point(q.bottomLeftX, q.bottomLeftY),
    ];

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
