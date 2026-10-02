import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/record_scan_service.dart';
import 'package:ota_counter/pages/manual_scan_crop_page.dart';

void main() {
  group('RecordScanService', () {
    test('rejects crossed, collapsed and non-finite manual selections',
        () async {
      final bytes =
          Uint8List.fromList(img.encodeJpg(_buildSyntheticPolaroid()));
      const normal = RecordScanQuad(
        topLeftX: 280,
        topLeftY: 220,
        topRightX: 799,
        topRightY: 220,
        bottomLeftX: 280,
        bottomLeftY: 869,
        bottomRightX: 799,
        bottomRightY: 869,
      );
      expect(normal.isUsable(minimumEdge: 60), isTrue);
      for (final quad in [
        normal.copyWith(bottomLeftX: 799, bottomRightX: 280),
        normal.copyWith(topRightX: 280),
        normal.copyWith(topLeftX: double.nan),
        normal.copyWith(topLeftY: double.infinity),
        normal.copyWith(
            topLeftX: -1000,
            topRightX: -900,
            bottomLeftX: -1000,
            bottomRightX: -900),
      ]) {
        await expectLater(
          RecordScanService.createManualScan(sourceBytes: bytes, quad: quad),
          throwsFormatException,
        );
      }
    });

    test('fusion keeps clean detail from complementary glare frames', () async {
      final dir = await Directory.systemTemp.createTemp('scan_fusion_test');
      addTearDown(() => dir.delete(recursive: true));
      final first = _buildSyntheticPolaroid();
      final second = _buildSyntheticPolaroid();
      img.fillRect(first,
          x1: 410,
          y1: 390,
          x2: 510,
          y2: 490,
          color: img.ColorRgb8(255, 255, 255));
      img.fillRect(second,
          x1: 580,
          y1: 550,
          x2: 680,
          y2: 650,
          color: img.ColorRgb8(255, 255, 255));
      final files = [
        File('${dir.path}/first.jpg'),
        File('${dir.path}/second.jpg')
      ];
      await files[0].writeAsBytes(img.encodeJpg(first, quality: 94));
      await files[1].writeAsBytes(img.encodeJpg(second, quality: 94));
      final output =
          await RecordScanService.createFusionScan(sourceFiles: files);
      final result = img.decodeImage(Uint8List.fromList(output.bytes))!;
      for (final position in [(460, 440), (630, 600)]) {
        final x = ((position.$1 - 280) / 520 * result.width).round();
        final y = ((position.$2 - 220) / 650 * result.height).round();
        final pixel = result.getPixel(x, y);
        expect(pixel.r, lessThan(160));
        expect(pixel.b, greaterThan(pixel.r));
      }
    });

    test('duplicate frames keep identical alignment and apply polish once',
        () async {
      final dir = await Directory.systemTemp.createTemp('scan_duplicate_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/source.jpg');
      await file
          .writeAsBytes(img.encodeJpg(_buildSyntheticPolaroid(), quality: 94));
      final one = await RecordScanService.createFusionScan(sourceFiles: [file]);
      final two =
          await RecordScanService.createFusionScan(sourceFiles: [file, file]);
      expect(two.bytes, orderedEquals(one.bytes));
    });

    test('fusion rejects empty input and propagates unreadable image errors',
        () async {
      await expectLater(RecordScanService.createFusionScan(sourceFiles: []),
          throwsFormatException);
      await expectLater(
          RecordScanService.createManualScan(
              sourceBytes: Uint8List.fromList([1, 2, 3]),
              quad: const RecordScanQuad(
                  topLeftX: 0,
                  topLeftY: 0,
                  topRightX: 20,
                  topRightY: 0,
                  bottomLeftX: 0,
                  bottomLeftY: 20,
                  bottomRightX: 20,
                  bottomRightY: 20)),
          throwsFormatException);
    });

    test('landscape card and borderless glare fallback remain usable',
        () async {
      final dir = await Directory.systemTemp.createTemp('scan_layout_test');
      addTearDown(() => dir.delete(recursive: true));
      final landscape = img.copyRotate(_buildSyntheticPolaroid(), angle: 90);
      final file = File('${dir.path}/landscape.jpg');
      await file.writeAsBytes(img.encodeJpg(landscape, quality: 94));
      final output = await RecordScanService.createBasicScan(sourceFile: file);
      final result = img.decodeImage(Uint8List.fromList(output.bytes))!;
      expect(result.width / result.height, closeTo(1.25, 0.01));
      final center = result.getPixel(result.width ~/ 2, result.height ~/ 2);
      expect(center.b, greaterThan(center.r));
      final borderless = img.Image(width: 180, height: 220);
      img.fill(borderless, color: img.ColorRgb8(255, 255, 255));
      await file.writeAsBytes(img.encodeJpg(borderless));
      final draft =
          await RecordScanService.prepareManualDraft(sourceFile: file);
      expect(draft.usedFallback, isTrue);
      expect(draft.suggestedQuad.isUsable(), isTrue);
      final fallback = await RecordScanService.createManualScan(
          sourceBytes: draft.sourceBytes, quad: draft.suggestedQuad);
      expect(img.decodeImage(Uint8List.fromList(fallback.bytes)), isNotNull);
    });

    test(
        'EXIF rotation and large source keep manual draft coordinates consistent',
        () async {
      final dir = await Directory.systemTemp.createTemp('scan_exif_test');
      addTearDown(() => dir.delete(recursive: true));
      final enlarged =
          img.copyResize(_buildSyntheticPolaroid(), width: 2400, height: 3200);
      final cameraImage = img.copyRotate(enlarged, angle: -90);
      cameraImage.exif.imageIfd.orientation = 6;
      final file = File('${dir.path}/exif.jpg');
      await file.writeAsBytes(img.encodeJpg(cameraImage, quality: 94));
      final draft =
          await RecordScanService.prepareManualDraft(sourceFile: file);
      // Detection may deskew after EXIF normalization, expanding the canvas.
      expect(draft.imageWidth / draft.imageHeight, closeTo(0.75, 0.04));
      expect(draft.imageHeight, inInclusiveRange(1750, 1900));
      final draftImage = img.decodeImage(draft.sourceBytes)!;
      expect(draftImage.width, draft.imageWidth);
      expect(draftImage.height, draft.imageHeight);
      expect(draft.suggestedQuad.isUsable(), isTrue);
      final output = await RecordScanService.createManualScan(
          sourceBytes: draft.sourceBytes, quad: draft.suggestedQuad);
      final result = img.decodeImage(Uint8List.fromList(output.bytes))!;
      expect(result.width / result.height, closeTo(0.8, 0.01));
      final center = result.getPixel(result.width ~/ 2, result.height ~/ 2);
      expect(center.b, greaterThan(center.r));
      // The detector's approximate box can include background after deskew;
      // verify the selected source coordinate rather than assume a white edge.
      final q = draft.suggestedQuad;
      final sourceEdge = draftImage.getPixel(
          (q.topLeftX + (q.topRightX - q.topLeftX) * 24 / (result.width - 1))
              .round(),
          (q.topLeftY + (q.bottomLeftY - q.topLeftY) * 24 / (result.height - 1))
              .round());
      final outputEdge = result.getPixel(24, 24);
      expect(outputEdge.r, closeTo(sourceEdge.r, 35));
      expect(outputEdge.g, closeTo(sourceEdge.g, 35));
      expect(outputEdge.b, closeTo(sourceEdge.b, 35));
    });

    test('manual crop preserves all four coordinates on an expanded draft',
        () async {
      final dir = await Directory.systemTemp.createTemp('scan_corner_test');
      addTearDown(() => dir.delete(recursive: true));
      final enlarged =
          img.copyResize(_buildSyntheticPolaroid(), width: 2400, height: 3200);
      final file = File('${dir.path}/source.jpg');
      await file.writeAsBytes(img.encodeJpg(enlarged, quality: 94));
      final draft =
          await RecordScanService.prepareManualDraft(sourceFile: file);
      expect(draft.imageHeight, greaterThan(1800));
      final marked = img.decodeImage(draft.sourceBytes)!;
      final q = draft.suggestedQuad;
      final locations = [
        (0.08, 0.08),
        (0.92, 0.08),
        (0.08, 0.92),
        (0.92, 0.92)
      ];
      final colors = [
        img.ColorRgb8(180, 30, 30),
        img.ColorRgb8(30, 180, 30),
        img.ColorRgb8(30, 30, 180),
        img.ColorRgb8(180, 180, 30)
      ];
      for (var i = 0; i < locations.length; i++) {
        final u = locations[i].$1;
        final v = locations[i].$2;
        final x = q.topLeftX * (1 - u) * (1 - v) +
            q.topRightX * u * (1 - v) +
            q.bottomLeftX * (1 - u) * v +
            q.bottomRightX * u * v;
        final y = q.topLeftY * (1 - u) * (1 - v) +
            q.topRightY * u * (1 - v) +
            q.bottomLeftY * (1 - u) * v +
            q.bottomRightY * u * v;
        img.fillCircle(marked,
            x: x.round(), y: y.round(), radius: 8, color: colors[i]);
      }
      final output = await RecordScanService.createManualScan(
          sourceBytes: Uint8List.fromList(img.encodeJpg(marked, quality: 96)),
          quad: q);
      final result = img.decodeImage(Uint8List.fromList(output.bytes))!;
      for (var i = 0; i < locations.length; i++) {
        final pixel = result.getPixel(
            (locations[i].$1 * (result.width - 1)).round(),
            (locations[i].$2 * (result.height - 1)).round());
        expect(pixel.r, closeTo(colors[i].r, 35), reason: 'corner $i red');
        expect(pixel.g, closeTo(colors[i].g, 35), reason: 'corner $i green');
        expect(pixel.b, closeTo(colors[i].b, 35), reason: 'corner $i blue');
      }
    });

    testWidgets('manual crop disables crossed handles and reset restores them',
        (tester) async {
      final image = img.Image(width: 200, height: 250);
      img.fill(image, color: img.ColorRgb8(240, 238, 236));
      await tester.pumpWidget(MaterialApp(
          home: ManualScanCropPage(
        draft: RecordScanManualDraft(
          sourceBytes: Uint8List.fromList(img.encodeJpg(image)),
          imageWidth: 200,
          imageHeight: 250,
          usedFallback: false,
          suggestedQuad: const RecordScanQuad(
              topLeftX: 20,
              topLeftY: 20,
              topRightX: 180,
              topRightY: 20,
              bottomLeftX: 20,
              bottomLeftY: 230,
              bottomRightX: 180,
              bottomRightY: 230),
        ),
      )));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, '生成切图');
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      final handles = find.byWidgetPredicate(
          (widget) => widget is GestureDetector && widget.onPanUpdate != null);
      expect(handles, findsNWidgets(4));
      await tester.drag(handles.first, const Offset(500, 500));
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.tap(find.text('恢复自动框'));
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    test('basic scan crops synthetic polaroid into a filled frame', () async {
      final tempDir = await Directory.systemTemp.createTemp('record_scan_test');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final source = _buildSyntheticPolaroid();
      final sourceFile = File('${tempDir.path}/source.jpg');
      await sourceFile.writeAsBytes(img.encodeJpg(source, quality: 94));

      final output = await RecordScanService.createBasicScan(
        sourceFile: sourceFile,
      );
      final scanned = img.decodeJpg(Uint8List.fromList(output.bytes));

      expect(scanned, isNotNull);
      final result = scanned!;
      final aspect = result.width / result.height;
      expect(aspect, closeTo(0.8, 0.05));

      final topLeft = result.getPixel(24, 24);
      final bottomLeft = result.getPixel(24, result.height - 24);
      final center = result.getPixel(result.width ~/ 2, result.height ~/ 2);

      expect(topLeft.r, greaterThan(210));
      expect(topLeft.g, greaterThan(210));
      expect(topLeft.b, greaterThan(210));
      expect(bottomLeft.r, greaterThan(210));
      expect(bottomLeft.g, greaterThan(210));
      expect(bottomLeft.b, greaterThan(210));
      expect(center.b, greaterThan(center.r));
    });

    test('manual scan rectifies synthetic polaroid from selected quad',
        () async {
      final source = _buildSyntheticPolaroid();
      final output = await RecordScanService.createManualScan(
        sourceBytes: Uint8List.fromList(img.encodeJpg(source, quality: 94)),
        quad: const RecordScanQuad(
          topLeftX: 280,
          topLeftY: 220,
          topRightX: 799,
          topRightY: 220,
          bottomLeftX: 280,
          bottomLeftY: 869,
          bottomRightX: 799,
          bottomRightY: 869,
        ),
      );

      final scanned = img.decodeJpg(Uint8List.fromList(output.bytes));
      expect(scanned, isNotNull);
      final result = scanned!;
      final aspect = result.width / result.height;
      expect(aspect, closeTo(0.8, 0.05));

      final topLeft = result.getPixel(24, 24);
      final bottomLeft = result.getPixel(24, result.height - 24);
      final center = result.getPixel(result.width ~/ 2, result.height ~/ 2);

      expect(topLeft.r, greaterThan(210));
      expect(topLeft.g, greaterThan(210));
      expect(topLeft.b, greaterThan(210));
      expect(bottomLeft.r, greaterThan(210));
      expect(bottomLeft.g, greaterThan(210));
      expect(bottomLeft.b, greaterThan(210));
      expect(center.b, greaterThan(center.r));
    });
  });
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

  final rectX = 280;
  final rectY = 220;
  const rectWidth = 520;
  const rectHeight = 650;
  const sideBorder = 38;
  const topBorder = 38;
  const bottomBorder = 110;

  for (var y = rectY; y < rectY + rectHeight; y++) {
    for (var x = rectX; x < rectX + rectWidth; x++) {
      image.setPixelRgba(x, y, 240, 238, 236, 255);
    }
  }

  final photoLeft = rectX + sideBorder;
  final photoTop = rectY + topBorder;
  final photoWidth = rectWidth - (sideBorder * 2);
  final photoHeight = rectHeight - topBorder - bottomBorder;

  for (var y = photoTop; y < photoTop + photoHeight; y++) {
    for (var x = photoLeft; x < photoLeft + photoWidth; x++) {
      final mix = (x - photoLeft) / photoWidth;
      final red = (60 + (mix * 30)).round();
      final green = (78 + (mix * 20)).round();
      final blue = (122 + (mix * 55)).round();
      image.setPixelRgba(x, y, red, green, blue, 255);
    }
  }

  for (var y = 260; y < 360; y++) {
    for (var x = 900; x < 1040; x++) {
      image.setPixelRgba(x, y, 226, 226, 226, 255);
    }
  }

  return image;
}
