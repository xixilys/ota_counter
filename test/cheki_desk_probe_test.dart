// Probe: run the production multi-card cut over photos of a desk covered in
// cheki, and write every cut-out card to disk so the face stage can run on it.
//
// The photos are private and never enter the repository. Run with:
//
//   OTA_CHEKI_DIR=/path/to/desk_photos \
//     flutter test test/cheki_desk_probe_test.dart
//
// Optional: OTA_CHEKI_CROPS (default: sibling "crops" directory) for the
// cut-out cards. Every line starts with "CHEKI_PROBE" so the report is easy to
// grep. No accuracy is asserted here: the desk has no ground truth, so this
// only reports how many cards were found, at which size, and how long it took.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ota_counter/services/record_scan_service.dart';

void main() {
  final dir = Platform.environment['OTA_CHEKI_DIR'] ?? '';
  final cropsDir = Platform.environment['OTA_CHEKI_CROPS'] ??
      (dir.isEmpty ? '' : '${Directory(dir).parent.path}/crops');

  test('cut every cheki on the desk photos', () async {
    final photos = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((file) => RegExp(r'\.(jpe?g|png)$', caseSensitive: false)
            .hasMatch(file.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    if (photos.isEmpty) {
      fail('no jpg/png under $dir');
    }
    Directory(cropsDir).createSync(recursive: true);

    for (final photo in photos) {
      final name = photo.uri.pathSegments.last;
      final stopwatch = Stopwatch()..start();
      final scan = await RecordScanService.createMultiScan(sourceFile: photo);
      stopwatch.stop();

      debugPrint('CHEKI_PROBE $name '
          'src=${scan.sourceWidth}x${scan.sourceHeight} '
          'cards=${scan.cards.length} '
          'warnings=${scan.warnings.map((w) => w.name).join(',')} '
          '${stopwatch.elapsedMilliseconds}ms '
          'stages=${scan.stageMilliseconds}');

      for (var i = 0; i < scan.cards.length; i++) {
        final card = scan.cards[i];
        final image = img.decodeImage(card.bytes);
        final cropPath = '$cropsDir/${name}_card$i.${card.fileExtension}'
            .replaceAll('..', '.');
        File(cropPath).writeAsBytesSync(card.bytes);
        final quad = card.quad;
        final xs = [
          quad.topLeftX,
          quad.topRightX,
          quad.bottomLeftX,
          quad.bottomRightX,
        ];
        final ys = [
          quad.topLeftY,
          quad.topRightY,
          quad.bottomLeftY,
          quad.bottomRightY,
        ];
        final left = xs.reduce((a, b) => a < b ? a : b);
        final top = ys.reduce((a, b) => a < b ? a : b);
        final right = xs.reduce((a, b) => a > b ? a : b);
        final bottom = ys.reduce((a, b) => a > b ? a : b);
        debugPrint('CHEKI_PROBE   card$i '
            'size=${card.sizeClass.name} '
            'conf=${card.confidence.toStringAsFixed(3)} '
            'split=${card.splitFromMerged} '
            'px=${image?.width ?? -1}x${image?.height ?? -1} '
            'ar=${card.aspectRatio.toStringAsFixed(3)} '
            'bbox=(${left.toStringAsFixed(0)},${top.toStringAsFixed(0)})-'
            '(${right.toStringAsFixed(0)},${bottom.toStringAsFixed(0)}) '
            '-> $cropPath');
      }
    }
  },
      skip: dir.isEmpty ? 'set OTA_CHEKI_DIR to run' : null,
      timeout: const Timeout(Duration(minutes: 3)));
}
