import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/services/album_card_matcher.dart';

void main() {
  test('preserves per-attachment order and permits the same card twice',
      () async {
    final card = _print(7);
    final other = _print(8);
    final distorted = img.copyRectify(
      card,
      topLeft: img.Point(4, 12),
      topRight: img.Point(226, 1),
      bottomLeft: img.Point(14, 309),
      bottomRight: img.Point(218, 317),
      interpolation: img.Interpolation.linear,
      toImage: img.Image(width: 198, height: 310),
    );
    final onTable = img.Image(width: 267, height: 329)
      ..clear(img.ColorRgb8(40, 57, 77));
    img.compositeImage(onTable, distorted, dstX: 31, dstY: 9);
    final legacy = img.encodeJpg(img.copyRotate(onTable, angle: 90));
    final sharp = img.encodeJpg(card);
    final wrong = img.encodeJpg(other);
    expect(
      await matchAlbumCards(
        [legacy, Uint8List(0), wrong, sharp],
        [
          Uint8List.fromList([255, 216, 255]),
          wrong,
          sharp
        ],
      ),
      [2, null, 1, 2],
    );
  });

  test('identifies duplicate views and selects the sharper scan', () async {
    final card = _print(7);
    final old = img.encodeJpg(img.copyRotate(card, angle: 180));
    final clear = img.encodeJpg(card);
    final blurred = img.encodeJpg(img.gaussianBlur(card.clone(), radius: 3));
    expect(await matchAlbumCards([old], [blurred, clear]), [1]);
    expect(await matchAlbumCards([old], [clear, blurred]), [0]);
  });

  test('a common signature on different photo content does not match',
      () async {
    expect(
      await matchAlbumCards(
        [img.encodeJpg(_print(7))],
        [img.encodeJpg(_print(8))],
      ),
      [null],
    );
    final blank = img.encodePng(img.Image(width: 120, height: 180));
    expect(await matchAlbumCards([blank], [blank]), [null]);
    expect(await matchAlbumCards([blank], []), [null]);
    expect(await matchAlbumCards([], [blank]), isEmpty);
  });

  test('shared content in a cropped attachment cannot break an identity tie',
      () async {
    final a = _print(7);
    final b = _print(8);
    // The visible top half is the same in both prints; the rest differs.
    final top = img.copyCrop(a, x: 0, y: 0, width: 232, height: 171);
    img.compositeImage(b, top);
    final old = img.encodeJpg(top);
    final first = img.encodeJpg(a);
    final second = img.encodeJpg(b);
    expect(await matchAlbumCards([old], [first]), [0]);
    expect(await matchAlbumCards([old], [second]), [0]);
    expect(await matchAlbumCards([old], [first, second]), [null]);
  });

  test('rejects new broad glare but accepts a tone lift and a clean view',
      () async {
    final card = _print(7);
    img.drawLine(
      card,
      x1: 47,
      y1: 218,
      x2: 190,
      y2: 243,
      color: img.ColorRgb8(247, 247, 245),
    );
    final old = img.encodeJpg(img.copyRotate(card, angle: 90));
    final glare = img.fillRect(
      card.clone(),
      x1: 54,
      y1: 61,
      x2: 176,
      y2: 187,
      color: img.ColorRgb8(234, 233, 231),
    );
    final brighter = card.clone();
    for (final pixel in brighter) {
      pixel
        ..r = math.min(255, pixel.r + 44)
        ..g = math.min(255, pixel.g + 44)
        ..b = math.min(255, pixel.b + 44);
    }
    final bad = img.encodeJpg(glare);
    final lifted = img.encodeJpg(brighter);
    expect(await matchAlbumCards([old], [bad]), [null]);
    expect(await matchAlbumCards([old], [lifted]), [0]);
    expect(await matchAlbumCards([old], [bad, img.encodeJpg(card)]), [1]);
  });

  test('file-backed matching preserves indexes and fails on missing input',
      () async {
    final directory = await Directory.systemTemp.createTemp('card-matcher-');
    addTearDown(() => directory.delete(recursive: true));
    final sharp = File('${directory.path}/sharp.jpg')
      ..writeAsBytesSync(img.encodeJpg(_print(7)));
    final other = File('${directory.path}/other.jpg')
      ..writeAsBytesSync(img.encodeJpg(_print(8)));
    final invalid = File('${directory.path}/invalid.jpg')
      ..writeAsBytesSync([0x00]);
    expect(
      await matchAlbumCardFiles(
        [sharp.path, invalid.path, other.path, sharp.path],
        [invalid.path, other.path, sharp.path],
      ),
      [2, null, 1, 2],
    );
    await expectLater(
      matchAlbumCardFiles(
        [sharp.path],
        [sharp.path, '${directory.path}/missing.jpg'],
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('reprojects through glare only when the old pixels cover the frame',
      () async {
    final directory = await Directory.systemTemp.createTemp('card-recovery-');
    addTearDown(() => directory.delete(recursive: true));

    String save(String name, img.Image image) =>
        (File('${directory.path}/$name.jpg')
              ..writeAsBytesSync(img.encodeJpg(image)))
            .path;

    final card = _print(7);
    final full = save('old-full', img.copyRotate(card, angle: 90));
    final clipped = save(
      'old-clipped',
      img.copyRotate(
        img.copyCrop(card, x: 0, y: 0, width: 211, height: 320),
        angle: 90,
      ),
    );
    final clear = save('clear', card);
    final glare = save(
      'glare',
      img.fillRect(
        card.clone(),
        x1: 54,
        y1: 61,
        x2: 176,
        y2: 187,
        color: img.ColorRgb8(234, 233, 231),
      ),
    );
    final options = await recoverAlbumCardFiles([full, clipped], [glare]);
    expect(options.first, isA<AlbumCardReprojection>());
    expect(options.last, isNull);
    // Cropping did not change the identity, only the available old pixels.
    expect(await matchAlbumCardFiles([clipped], [clear]), [0]);
    final preferred = await recoverAlbumCardFiles([full], [glare, clear]);
    expect((preferred.single as AlbumCardRescan).candidateIndex, 1);
  });

}

/// Distinct textured scenes on identical paper and with identical ink.
img.Image _print(int seed) {
  final random = math.Random(seed);
  final card = img.Image(width: 232, height: 320)
    ..clear(img.ColorRgb8(231, 235, 221));
  img.fillRect(card,
      x1: 12, y1: 12, x2: 219, y2: 266, color: img.ColorRgb8(31, 31, 33));
  for (var i = 0; i < 180; i++) {
    final x = 20 + random.nextInt(191), y = 20 + random.nextInt(230);
    final gray = 55 + random.nextInt(148);
    img.fillCircle(card,
        x: x,
        y: y,
        radius: 2 + random.nextInt(9),
        color: img.ColorRgb8(gray, gray - 10, gray + 14));
  }
  for (var x = 24; x < 213; x += 13) {
    final ink = img.ColorRgb8(172, 56, 105);
    img.drawLine(card, x1: x, y1: 277, x2: x + 6, y2: 303, color: ink);
    img.drawLine(card, x1: x + 6, y1: 303, x2: x + 10, y2: 281, color: ink);
  }
  return card;
}
