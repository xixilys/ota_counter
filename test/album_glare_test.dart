import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/services/album_glare_service.dart';

const _width = 96, _height = 80;

void main() {
  test('recovers recorded color towards known clean RGB in an isolate',
      () async {
    final clean = _print();
    final veiled = _overlay(clean);
    final saved = Uint8List.fromList(veiled);
    final direct = reduceAlbumGlareRgba(veiled, _width, _height);
    final fromIsolate = await Isolate.run(
      () => reduceAlbumGlareRgba(veiled, _width, _height),
    );
    expect(veiled, saved);
    expect(direct, isNot(same(veiled)));
    expect(fromIsolate, direct);

    var before = 0.0, after = 0.0;
    var chromaBefore = 0.0, chromaAfter = 0.0;
    for (var y = 0; y < _height; y++) {
      for (var x = 0; x < _width; x++) {
        final i = (y * _width + x) * 4;
        if (_opacity(x, y) == 0 ||
            clean[i + 3] != 255 ||
            (clean[i] == clean[i + 1] && clean[i] == clean[i + 2])) {
          expect(direct.sublist(i, i + 4), veiled.sublist(i, i + 4));
        }
        expect(direct[i + 3], veiled[i + 3]);
        if (x < 43 || x > 53 || y < 18 || y > 60) continue;

        // An equal-channel RGB drop can match luminance but cannot move
        // either channel difference towards the known clean appearance.
        for (var c = 0; c < 3; c++) {
          before += _sq(veiled[i + c] - clean[i + c]);
          after += _sq(direct[i + c] - clean[i + c]);
          if (c == 2) continue;
          final difference = clean[i + c] - clean[i + 2];
          chromaBefore += _sq(veiled[i + c] - veiled[i + 2] - difference);
          chromaAfter += _sq(direct[i + c] - direct[i + 2] - difference);
        }
      }
    }
    expect(after, lessThan(before * 0.26));
    expect(chromaAfter, lessThan(chromaBefore * 0.45));
  });

  test('applies a coarse veil estimate to original-resolution RGB', () {
    final clean = _print();
    final veiled = _overlay(clean);
    const scale = 4, width = _width * scale, height = _height * scale;
    final enlarged = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final input = ((y ~/ scale) * _width + x ~/ scale) * 4;
        final output = (y * width + x) * 4;
        enlarged.setRange(output, output + 4, veiled, input);
      }
    }
    final result = reduceAlbumGlareRgba(enlarged, width, height);
    expect(result, isNot(same(enlarged)));
    // Non-grid pixels should be corrected without replacing their source RGB.
    final pixel = ((39 * scale + 1) * width + 48 * scale + 1) * 4;
    final original = (39 * _width + 48) * 4;
    for (var c = 0; c < 3; c++) {
      expect(result[pixel + c], lessThan(enlarged[pixel + c]));
      expect((result[pixel + c] - clean[original + c]).abs(),
          lessThan((enlarged[pixel + c] - clean[original + c]).abs()));
    }
    expect(result.sublist(0, 4), enlarged.sublist(0, 4));
  });

  test('leaves clean paper, pale pen, white artwork and print shadows alone',
      () {
    final clean = _print();
    final copy = Uint8List.fromList(clean);
    expect(reduceAlbumGlareRgba(clean, _width, _height), same(clean));
    expect(clean, copy);
  });

  test('abstains on a bright featureless region and a clipped obstruction', () {
    final flat = _print(flat: true);
    final veiled = _overlay(flat);
    expect(veiled, isNot(equals(flat)));
    expect(reduceAlbumGlareRgba(veiled, _width, _height), same(veiled));

    final clipped = _print();
    for (var y = 10; y < 70; y++) {
      for (var x = 38; x < 58; x++) {
        final i = (y * _width + x) * 4;
        clipped.setRange(i, i + 3, const [255, 255, 255]);
      }
    }
    expect(reduceAlbumGlareRgba(clipped, _width, _height), same(clipped));
  });

  test('rejects a local brightness lift with no texture attenuation', () {
    final lifted = _overlay(_print(), additive: true);
    expect(reduceAlbumGlareRgba(lifted, _width, _height), same(lifted));
  });

  test('small images are a no-op; malformed RGBA is rejected', () {
    final small = Uint8List(8);
    expect(reduceAlbumGlareRgba(small, 1, 2), same(small));
    expect(() => reduceAlbumGlareRgba(small, 2, 2), throwsArgumentError);
  });
}

Uint8List _print({bool flat = false}) {
  final rgba = Uint8List(_width * _height * 4);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      final i = (y * _width + x) * 4;
      final paper = x < 5 || x >= 91 || y < 5 || y >= 72;
      final whitePen = y >= 13 && y <= 16 && x >= 36 && x < 76;
      final artwork = y > 48 && x > 71 && _sq(x - 81) + _sq(y - 57) < 49;
      final tone = flat ? 0 : const [-18, 5, 37, 16, -11, 29][y % 6];
      final grain = flat ? 0 : (x * 7 + y * 3) % 5 - 2;
      final fade = flat ? 0 : x ~/ 10;
      final rgb = switch ((paper, whitePen, artwork)) {
        (true, _, _) => [241, 235, 226],
        (_, true, _) => [226, 226, 226],
        (_, _, true) => [254, 253, 252],
        _ => [149 + tone + grain, 89 + tone + fade, 61 + tone - grain],
      };
      // A transparent texel within the veil must not be rewritten.
      rgba.setRange(i, i + 4, [...rgb, x == 48 && y == 35 ? 96 : 255]);
    }
  }
  return rgba;
}

double _opacity(int x, int y) {
  final radius = _sq((x - 48) / 16) + _sq((y - 39) / 31);
  return 0.28 * _sq(math.max(0.0, 1 - radius));
}

Uint8List _overlay(Uint8List clean, {bool additive = false}) {
  final rgba = Uint8List.fromList(clean);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      final opacity = _opacity(x, y);
      final i = (y * _width + x) * 4;
      if (opacity == 0 || rgba[i + 3] != 255) continue;
      for (var c = 0; c < 3; c++) {
        final code = clean[i + c] / 255;
        final light = code <= 0.04045
            ? code / 12.92
            : math.pow((code + 0.055) / 1.055, 2.4);
        final covered = additive
            ? math.min(1, light + opacity * 0.75)
            : light * (1 - opacity) + opacity;
        final observed = covered <= 0.0031308
            ? 12.92 * covered
            : 1.055 * math.pow(covered, 1 / 2.4) - 0.055;
        rgba[i + c] = (255 * observed).round();
      }
    }
  }
  return rgba;
}

double _sq(num x) => (x * x).toDouble();
