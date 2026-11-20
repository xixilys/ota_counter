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

  group('automatic quad geometry (manual path stays available)', () {
    test('keeps rotation and moderate perspective', () {
      final rotated =
          _Card.mini(cx: 500, cy: 500, height: 500, angle: 38).corners;
      final quads = [
        // Complete card against the image edge uses pixel-edge coordinates.
        const RecordScanQuad(
          topLeftX: 600,
          topLeftY: 400,
          topRightX: 1000,
          topRightY: 400,
          bottomRightX: 1000,
          bottomRightY: 1000,
          bottomLeftX: 600,
          bottomLeftY: 1000,
        ),
        _fromPoints(rotated),
        const RecordScanQuad(
          topLeftX: 220,
          topLeftY: 170,
          topRightX: 490,
          topRightY: 220,
          bottomRightX: 550,
          bottomRightY: 680,
          bottomLeftX: 150,
          bottomLeftY: 700,
        ),
      ];
      for (final quad in quads) {
        expect(quad.isSafeForAutomaticCrop(imageWidth: 1000, imageHeight: 1000),
            isTrue);
      }
    });

    test('rejects severe shear, taper, crossed corners and out-of-bounds', () {
      const rect = RecordScanQuad(
        topLeftX: 100,
        topLeftY: 100,
        topRightX: 400,
        topRightY: 100,
        bottomRightX: 400,
        bottomRightY: 600,
        bottomLeftX: 100,
        bottomLeftY: 600,
      );
      for (final quad in [
        rect.copyWith(
            bottomLeftX: 700,
            bottomLeftY: 300,
            bottomRightX: 1000,
            bottomRightY: 300),
        rect.copyWith(topLeftX: 240, topRightX: 260),
        rect.copyWith(bottomLeftX: 400, bottomRightX: 100),
        rect.copyWith(topLeftX: -10),
        rect.copyWith(topLeftX: double.nan),
      ]) {
        expect(quad.isSafeForAutomaticCrop(imageWidth: 1200, imageHeight: 900),
            isFalse);
      }
      // A strong but deliberate perspective remains a valid manual selection.
      expect(rect.copyWith(topLeftX: 240, topRightX: 260).isUsable(), isTrue);
    });
  });

  group('RecordScanService.createMultiScan', () {
    test('an already-cut card that fills the frame stays one card', () async {
      // A mini cut lying sideways, as the app or a chat sends it: paper border
      // to the image edge, ink on the border, a dark picture window inside.
      final source = img.Image(width: 1360, height: 854);
      img.fill(source, color: img.ColorRgb8(214, 210, 205));
      img.fillRect(source,
          x1: 180, y1: 60, x2: 1300, y2: 794, color: img.ColorRgb8(40, 26, 30));
      img.fillRect(source,
          x1: 560,
          y1: 260,
          x2: 760,
          y2: 520,
          color: img.ColorRgb8(170, 60, 60));
      img.drawLine(source,
          x1: 40,
          y1: 120,
          x2: 120,
          y2: 700,
          thickness: 14,
          color: img.ColorRgb8(205, 60, 80));
      final file = await writeJpg(source, 'already-cut');
      final batch = await RecordScanService.createMultiScan(sourceFile: file);
      expect(batch.cards, hasLength(1));
      expect(batch.cards.single.sizeClass, RecordScanCardSize.mini);
      expect(
          batch.warnings,
          isNot(anyOf(contains(RecordScanMultiWarning.noneDetected),
              contains(RecordScanMultiWarning.unsafeGeometry))));
    });

    test('a frame-filling photo without a paper border is not a card',
        () async {
      final source = img.Image(width: 1360, height: 854);
      img.fill(source, color: img.ColorRgb8(40, 26, 30));
      img.fillRect(source,
          x1: 560,
          y1: 260,
          x2: 760,
          y2: 520,
          color: img.ColorRgb8(170, 60, 60));
      final file = await writeJpg(source, 'no-border');
      final batch = await RecordScanService.createMultiScan(sourceFile: file);
      expect(batch.cards, isEmpty);
    });

    test('a cool card attached to a light hand is cut before review', () async {
      final source = img.Image(width: 680, height: 850);
      img.fill(source, color: img.ColorRgb8(32, 29, 30));
      // Warm hand touches the upper and left edges and joins the bright
      // component to the image edge. The paper itself has a cool cast.
      img.fillRect(source,
          x1: 0,
          y1: 122,
          x2: 360,
          y2: 430,
          color: img.ColorRgb8(211, 178, 159));
      const paper = (x: 90, y: 165, right: 590, bottom: 711);
      img.fillRect(source,
          x1: paper.x,
          y1: paper.y,
          x2: paper.right,
          y2: paper.bottom,
          color: img.ColorRgb8(180, 218, 222));
      img.fillRect(source,
          x1: 127, y1: 218, x2: 553, y2: 618, color: img.ColorRgb8(24, 30, 33));
      // Ink crosses from the border into the photo, interrupting the mask.
      img.drawLine(source,
          x1: 170,
          y1: 177,
          x2: 204,
          y2: 253,
          thickness: 9,
          color: img.ColorRgb8(225, 121, 161));
      final file = await writeJpg(source, 'cool-paper');
      final legacy = RecordScanService.rectifyDominantCardPreview(source,
          alreadyProcessed: true);
      expect(legacy, isNotNull);
      final batch = await RecordScanService.createMultiScan(sourceFile: file);
      expect(batch.cards, hasLength(1));
      final image = img.decodeJpg(batch.cards.single.bytes)!;
      expect(math.max(image.width, image.height), 1360);
      expect(batch.cards.single.quad.topLeftX, closeTo(paper.x, 20));
      expect(batch.cards.single.quad.topLeftY, closeTo(paper.y, 20));
      expect(batch.cards.single.quad.bottomRightX, closeTo(paper.right, 20));
      expect(batch.cards.single.quad.bottomRightY, closeTo(paper.bottom, 20));
      final basic = await RecordScanService.createBasicScan(sourceFile: file);
      expect(batch.cards.single.bytes, basic.bytes);
    });

    test('a cool sheet without a photo window is not a card', () {
      final source = img.Image(width: 400, height: 500);
      img.fillRect(source,
          x1: 30,
          y1: 45,
          x2: 365,
          y2: 445,
          color: img.ColorRgb8(181, 223, 230));
      expect(
          RecordScanService.rectifyDominantCardPreview(source,
              alreadyProcessed: true),
          isNull);
    });

    test('perspective landscape mini keeps signed paper edges on desk and crop',
        () async {
      // Relocate the same projected film; the detector receives pixels only.
      for (final shift in [
        const math.Point(0.0, 0.0),
        const math.Point(230.0, 90.0)
      ]) {
        const neighbour = _Card.mini(cx: 1390, cy: 650, height: 400);
        final image =
            _render(1800, 1150, [neighbour], background: _Background.saturated);
        final quad = _paintPerspectiveLandscape(image, shift);
        final file = await writeJpg(image, 'perspective_${shift.x}');
        final result =
            await RecordScanService.createMultiScan(sourceFile: file);
        expect(result.cards, hasLength(2));
        final card = result.cards.reduce((a, b) =>
            _iou(_quadPoints(a.quad), quad) > _iou(_quadPoints(b.quad), quad)
                ? a
                : b);
        expect(_iou(_quadPoints(card.quad), quad), greaterThan(0.94));
        _expectLandscapeSignature(img.decodeJpg(card.bytes)!);

        final left = quad.map((p) => p.x).reduce(math.min).floor() - 22;
        final top = quad.map((p) => p.y).reduce(math.min).floor() - 22;
        final right = quad.map((p) => p.x).reduce(math.max).ceil() + 22;
        final bottom = quad.map((p) => p.y).reduce(math.max).ceil() + 22;
        final crop = img.copyCrop(image,
            x: left, y: top, width: right - left, height: bottom - top);
        final cropped = await RecordScanService.createMultiScan(
            sourceFile: await writeJpg(crop, 'crop_${shift.x}'));
        expect(cropped.cards, hasLength(1));
        _expectLandscapeSignature(img.decodeJpg(cropped.cards.single.bytes)!);
      }
    });

    test(
        'unresolved low-contrast edge keeps signatures in whole-image fallback',
        () async {
      final image = _render(1200, 900, const []);
      img.fillRect(image,
          x1: 100,
          y1: 630,
          x2: 870,
          y2: 770,
          color: img.ColorRgb8(221, 219, 217));
      _paintPerspectiveLandscape(image, const math.Point(0.0, 0.0));
      final file = await writeJpg(image, 'pale_edge');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      // This is a retained counterexample, not a promised weak-edge recall:
      // no reliable outer quad. Exercise the same full-image manual fallback
      // used by BatchImportService, retaining the desk and all signed edges.
      expect(result.cards, isEmpty);
      expect(result.warnings, contains(RecordScanMultiWarning.unsafeGeometry));
      final output = await RecordScanService.createManualScan(
        sourceBytes: await file.readAsBytes(),
        quad: RecordScanQuad(
          topLeftX: 0,
          topLeftY: 0,
          topRightX: image.width - 1.0,
          topRightY: 0,
          bottomRightX: image.width - 1.0,
          bottomRightY: image.height - 1.0,
          bottomLeftX: 0,
          bottomLeftY: image.height - 1.0,
        ),
      );
      final safe = img.decodeJpg(Uint8List.fromList(output.bytes))!;
      expect(safe.width, 1360);
      expect(safe.height, 1020); // Original 4:3 canvas, no card-ratio stretch.
      for (final (u, v, red) in [
        (820 / 860, 100 / 540, true),
        (820 / 860, 440 / 540, false),
        (330 / 860, 16 / 540, true),
        (400 / 860, 524 / 540, false),
      ]) {
        final z = 1 + .08 * u + .03 * v;
        final cx = ((650 * u - 60 * v + 220) / z * 1360 / 1200).round();
        final cy = ((40 * u + 400 * v + 280) / z * 1020 / 900).round();
        var strongest = 0.0;
        for (var y = cy - 14; y <= cy + 14; y++) {
          for (var x = cx - 14; x <= cx + 14; x++) {
            final p = safe.getPixel(x, y);
            strongest = math.max(strongest,
                red ? (p.r - p.g).toDouble() : (p.g - p.r).toDouble());
          }
        }
        expect(strongest, greaterThan(70), reason: 'fallback ink at $u,$v');
      }
    });

    test('whole-image manual fallback does not stretch a finished mini crop',
        () async {
      final image = _landscapeMini();
      final output = await RecordScanService.createManualScan(
        sourceBytes: Uint8List.fromList(img.encodeJpg(image, quality: 96)),
        quad: RecordScanQuad(
          topLeftX: 0,
          topLeftY: 0,
          topRightX: image.width - 1.0,
          topRightY: 0,
          bottomRightX: image.width - 1.0,
          bottomRightY: image.height - 1.0,
          bottomLeftX: 0,
          bottomLeftY: image.height - 1.0,
        ),
      );
      _expectLandscapeSignature(
          img.decodeJpg(Uint8List.fromList(output.bytes))!);
    });

    test('whole-image fallback keeps the last source row and column', () async {
      final image = img.Image(width: 1360, height: 854);
      img.fill(image, color: img.ColorRgb8(90, 90, 90));
      for (var x = 100; x < 500; x++) {
        image.setPixelRgb(x, 853, 230, 10, 10);
      }
      for (var y = 100; y < 500; y++) {
        image.setPixelRgb(1359, y, 10, 220, 10);
      }
      final output = await RecordScanService.createManualScan(
        sourceBytes: Uint8List.fromList(img.encodePng(image)),
        quad: const RecordScanQuad(
          topLeftX: 0,
          topLeftY: 0,
          topRightX: 1360,
          topRightY: 0,
          bottomRightX: 1360,
          bottomRightY: 854,
          bottomLeftX: 0,
          bottomLeftY: 854,
        ),
      );
      final safe = img.decodeJpg(Uint8List.fromList(output.bytes))!;
      expect(safe.width, 1360);
      expect(safe.height, 854);
      final bottom = safe.getPixel(300, 853);
      final right = safe.getPixel(1359, 300);
      expect(bottom.r - bottom.g, greaterThan(100));
      expect(right.g - right.r, greaterThan(100));
    });

    test('texture, dark rectangles and white flecks are not extra cards',
        () async {
      final image =
          _render(1200, 900, const [], background: _Background.saturated);
      for (var i = 0; i < 5; i++) {
        img.fillRect(image,
            x1: 30 + i * 230,
            y1: 250,
            x2: 210 + i * 230,
            y2: 530,
            color: img.ColorRgb8(22, 20, 28));
      }
      final random = math.Random(41);
      for (var i = 0; i < 800; i++) {
        final x = random.nextInt(1196), y = random.nextInt(896);
        img.fillRect(image,
            x1: x,
            y1: y,
            x2: x + 3,
            y2: y + 3,
            color: img.ColorRgb8(238, 238, 238));
      }
      final result = await RecordScanService.createMultiScan(
          sourceFile: await writeJpg(image, 'rectangle_noise'));
      expect(result.cards, isEmpty);
      expect(result.warnings, contains(RecordScanMultiWarning.noneDetected));
    });

    test('partial edge card does not discard a clear neighbouring card',
        () async {
      const clear = _Card.mini(cx: 850, cy: 450, height: 500, angle: -8);
      final file = await writeJpg(
          _render(1200, 900, [
            const _Card.mini(cx: 210, cy: 450, height: 500, angle: 20),
            clear,
          ]),
          'partial_edge');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      expect(result.cards, hasLength(1));
      expect(_iou(_quadPoints(result.cards.single.quad), clear.corners),
          greaterThanOrEqualTo(0.85));
      expect(result.warnings, contains(RecordScanMultiWarning.unsafeGeometry));
    });

    test('one mini has the same proportions in single and batch scan',
        () async {
      const card = _Card.mini(cx: 600, cy: 450, height: 500, angle: 12);
      final file = await writeJpg(_render(1200, 900, [card]), 'single_mini');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, [card]);
      final crop = img.decodeJpg(result.cards.single.bytes)!;
      expect(crop.width / crop.height, closeTo(54 / 86, 0.01));
      expect(math.max(crop.width, crop.height), 1360,
          reason: 'one-card archive quality stays unchanged');
      final single = await RecordScanService.createBasicScan(sourceFile: file);
      expect(single.bytes, orderedEquals(result.cards.single.bytes));
    });

    test('single scan with no trustworthy paper does not crop or stretch',
        () async {
      final source = img.Image(width: 302, height: 197)
        ..clear(img.ColorRgb8(21, 30, 29));
      img.fillRect(source,
          x1: 0, y1: 0, x2: 24, y2: 24, color: img.ColorRgb8(144, 55, 35));
      final file = await writeJpg(source, 'unknown-proportions');
      final output = await RecordScanService.createBasicScan(sourceFile: file);
      final archived = img.decodeImage(Uint8List.fromList(output.bytes))!;
      expect((archived.width, archived.height), (source.width, source.height));
      expect(archived.getPixel(12, 12).r,
          greaterThan(archived.getPixel(30, 30).r + 40));
    });

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

    test('desk-photo crops are enlarged to the standard 1360 frame', () async {
      final cards = _grid(
        columns: 3,
        rows: 3,
        canvasWidth: 2400,
        canvasHeight: 1800,
        cardWidth: 400,
        cardHeight: 500,
      );
      final file = await writeJpg(_render(2400, 1800, cards), 'desk2400');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      expect(result.cards.length, 9);
      for (final card in result.cards) {
        final decoded = img.decodeJpg(card.bytes)!;
        expect(math.max(decoded.width, decoded.height), 1360,
            reason: 'multi-crop should match a close-up scan frame');
        expect(decoded.width / decoded.height, closeTo(0.8, 0.01));
      }
    });

    test('multi-card archive frame preserves landscape and portrait geometry',
        () async {
      const cards = [
        _Card(cx: 450, cy: 500, width: 500, height: 400),
        _Card(cx: 1350, cy: 500, width: 400, height: 500),
      ];
      final file = await writeJpg(_render(1800, 1000, cards), 'orientations');
      final result = await RecordScanService.createMultiScan(sourceFile: file);
      _expectMatches(result, cards);
      _expectDecodableCrop(result.cards.first,
          portrait: false, whiteCorners: true);
      _expectDecodableCrop(result.cards.last,
          portrait: true, whiteCorners: true);
      final landscape = img.decodeJpg(result.cards.first.bytes)!;
      final portrait = img.decodeJpg(result.cards.last.bytes)!;
      expect(landscape.width, 1360);
      expect(landscape.height, (1360 * 86 / 108).round());
      expect(portrait.width, (1360 * 86 / 108).round());
      expect(portrait.height, 1360);
    });

    test('3×2 grid with 五寸 and 三寸 rows, timing printed', () async {
      const wideWidth = 360.0;
      const wideHeight = 450.0;
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
          _Card.mini(
            cx: 330 + i * 570,
            cy: 990,
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

img.Image _landscapeMini() {
  final card = img.Image(width: 860, height: 540);
  img.fill(card, color: img.ColorRgb8(240, 238, 236));
  img.fillRect(card,
      x1: 70, y1: 40, x2: 689, y2: 499, color: img.ColorRgb8(50, 70, 110));
  // The right-side thick border carries asymmetric signatures; edge markers
  // catch both an inner-window crop and a cyclic/180-degree corner shift.
  img.fillCircle(card,
      x: 820, y: 100, radius: 15, color: img.ColorRgb8(190, 30, 40));
  img.fillCircle(card,
      x: 820, y: 440, radius: 15, color: img.ColorRgb8(30, 160, 45));
  img.fillCircle(card,
      x: 330, y: 16, radius: 8, color: img.ColorRgb8(190, 30, 40));
  img.fillCircle(card,
      x: 400, y: 524, radius: 8, color: img.ColorRgb8(30, 160, 45));
  return card;
}

void _expectLandscapeSignature(img.Image image) {
  expect(image.width, 1360);
  expect(image.height, 854);
  for (final (x, y, red) in [
    (820 / 860, 100 / 540, true),
    (820 / 860, 440 / 540, false),
    (330 / 860, 16 / 540, true),
    (400 / 860, 524 / 540, false),
  ]) {
    var strongest = 0.0;
    final cx = (x * image.width).round(), cy = (y * image.height).round();
    for (var yy = math.max(0, cy - 18);
        yy < math.min(image.height, cy + 19);
        yy++) {
      for (var xx = math.max(0, cx - 18);
          xx < math.min(image.width, cx + 19);
          xx++) {
        final pixel = image.getPixel(xx, yy);
        strongest = math.max(
            strongest,
            red
                ? (pixel.r - pixel.g).toDouble()
                : (pixel.g - pixel.r).toDouble());
      }
    }
    expect(strongest, greaterThan(70), reason: 'signature at $x,$y');
  }
}

List<math.Point<double>> _paintPerspectiveLandscape(
    img.Image image, math.Point<double> shift) {
  final card = _landscapeMini();
  // One genuine projective transform, not a bilinear quadrilateral mapping.
  math.Point<double> project(double u, double v) {
    final z = 1 + .08 * u + .03 * v;
    return math.Point((650 * u - 60 * v + 220) / z + shift.x,
        (40 * u + 400 * v + 280) / z + shift.y);
  }

  final q = [project(0, 0), project(1, 0), project(1, 1), project(0, 1)];
  final x0 = q.map((p) => p.x).reduce(math.min).floor();
  final x1 = q.map((p) => p.x).reduce(math.max).ceil();
  final y0 = q.map((p) => p.y).reduce(math.min).floor();
  final y1 = q.map((p) => p.y).reduce(math.max).ceil();
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      final px = x + .5 - shift.x, py = y + .5 - shift.y;
      final a = 650 - .08 * px, b = -60 - .03 * px, c = px - 220;
      final d = 40 - .08 * py, e = 400 - .03 * py, f = py - 280;
      final det = a * e - b * d;
      final u = (c * e - b * f) / det, v = (a * f - c * d) / det;
      if (u < 0 || u >= 1 || v < 0 || v >= 1) continue;
      image.setPixel(x, y,
          card.getPixel((u * card.width).floor(), (v * card.height).floor()));
    }
  }
  return q;
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
  // Real instax layouts. A WIDE (108 × 86 mm, window 99 × 62) has its thick
  // border along a long side: below the picture when it lies landscape, at
  // the right when it stands upright.
  late final double left, right, top, bottom;
  if (card.miniBorders) {
    left = right = card.width * 4 / 54;
    top = card.height * 7 / 86;
    bottom = card.height * 17 / 86;
  } else if (card.width >= card.height) {
    left = right = top = card.width * 4.5 / 108;
    bottom = card.height - card.height * 62 / 86 - top;
  } else {
    top = bottom = left = card.height * 4.5 / 108;
    right = card.width - card.width * 62 / 86 - left;
  }
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
      final inPhoto = u >= -hw + left &&
          u < hw - right &&
          v >= -hh + top &&
          v < hh - bottom;
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
  expect(math.max(image.width, image.height), 1360,
      reason: 'every multi-crop retains the archive frame');
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

RecordScanQuad _fromPoints(List<math.Point<double>> p) => RecordScanQuad(
      topLeftX: p[0].x,
      topLeftY: p[0].y,
      topRightX: p[1].x,
      topRightY: p[1].y,
      bottomRightX: p[2].x,
      bottomRightY: p[2].y,
      bottomLeftX: p[3].x,
      bottomLeftY: p[3].y,
    );
