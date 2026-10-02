// Run with: dart run test/record_scan_benchmark.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:ota_counter/services/record_scan_service.dart';

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('scan_benchmark');
  try {
    final image = img.Image(width: 1200, height: 1600);
    img.fill(image, color: img.ColorRgb8(28, 24, 24));
    img.fillRect(image,
        x1: 280,
        y1: 220,
        x2: 799,
        y2: 869,
        color: img.ColorRgb8(240, 238, 236));
    img.fillRect(image,
        x1: 318, y1: 258, x2: 761, y2: 759, color: img.ColorRgb8(70, 90, 145));
    final file = File('${dir.path}/source.jpg');
    await file.writeAsBytes(img.encodeJpg(image, quality: 94));
    for (final mode in ["basic", "manual", "fusion2"]) {
      for (var run = 0; run < 3; run++) {
        final watch = Stopwatch()..start();
        var ticks = 0;
        var lastTick = 0;
        var longestGap = 0;
        final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          final elapsed = watch.elapsedMilliseconds;
          final gap = elapsed - lastTick;
          if (gap > longestGap) longestGap = gap;
          lastTick = elapsed;
          ticks++;
        });
        final output = switch (mode) {
          "fusion2" =>
            await RecordScanService.createFusionScan(sourceFiles: [file, file]),
          "manual" => await RecordScanService.createManualScan(
              sourceBytes: await file.readAsBytes(),
              quad: const RecordScanQuad(
                  topLeftX: 280,
                  topLeftY: 220,
                  topRightX: 799,
                  topRightY: 220,
                  bottomLeftX: 280,
                  bottomLeftY: 869,
                  bottomRightX: 799,
                  bottomRightY: 869)),
          _ => await RecordScanService.createBasicScan(sourceFile: file),
        };
        watch.stop();
        timer.cancel();
        final endGap = watch.elapsedMilliseconds - lastTick;
        if (endGap > longestGap) longestGap = endGap;
        final result = img.decodeImage(Uint8List.fromList(output.bytes))!;
        final center = result.getPixel(result.width ~/ 2, result.height ~/ 2);
        // ignore: avoid_print
        print('$mode run=$run '
            'ms=${watch.elapsedMilliseconds} max_event_gap_ms=$longestGap '
            'ticks=$ticks size=${result.width}x${result.height} '
            'center=${center.r},${center.g},${center.b}');
      }
    }
  } finally {
    await dir.delete(recursive: true);
  }
}
