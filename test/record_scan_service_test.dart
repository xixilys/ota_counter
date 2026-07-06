import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/record_scan_service.dart';

void main() {
  group('RecordScanService', () {
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
