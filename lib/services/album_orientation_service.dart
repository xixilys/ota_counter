import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'face/face_engine.dart';
import 'face/face_image_ops.dart';
import 'face/face_models.dart';
import 'card_orientation.dart';
import 'record_scan_service.dart';

/// Upright facial landmarks are evidence of direction, not identity.
/// Prefer the current direction when there is already an upright face.
class AlbumOrientationService {
  static bool isLandscapeCard(int width, int height) =>
      width > height && height / width >= .53;

  static Future<int?> detect(Uint8List rgba, int width, int height) async {
    final (sources, paperTurn) = await Isolate.run(() => _detectorInputs(
          img.Image.fromBytes(
            width: width,
            height: height,
            bytes: rgba.buffer,
            numChannels: 4,
          ),
        ));
    return _detect(sources, paperTurn: paperTurn);
  }

  /// Finalize scan bytes before matching faces, showing review or saving.
  /// Decode only a small preview for direction; re-encode only if turned.
  static Future<Uint8List> orientScanBytes(Uint8List bytes) async =>
      (await orientScanBytesWithAngle(bytes)).$1;

  /// [orientScanBytes] plus the clockwise angle it applied (0 if none).
  static Future<(Uint8List, int)> orientScanBytesWithAngle(
      Uint8List bytes) async {
    final codec = await ui.instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (width, height) => width >= height
          ? ui.TargetImageSize(width: math.min(384, width))
          : ui.TargetImageSize(height: math.min(384, height)),
    );
    final ui.Image preview;
    try {
      preview = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    final int? turn;
    try {
      final pixels = (await preview.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba))!;
      turn = await detect(
          pixels.buffer.asUint8List(), preview.width, preview.height);
    } finally {
      preview.dispose();
    }
    if (turn == null || turn == 0) return (bytes, 0);
    final angle = turn;
    final rotated = await Isolate.run(() {
      final decoder = img.findDecoderForData(bytes)!;
      final rotated = img.copyRotate(decoder.decode(bytes)!, angle: angle);
      return decoder is img.JpegDecoder
          ? img.encodeJpg(rotated, quality: 95)
          : img.encodePng(rotated);
    });
    return (rotated, angle);
  }

  /// Long side of the cut card handed to the face detector.
  static const int faceInputSide = 640;

  /// The face detector's input for a cut card in each of the four
  /// counter-clockwise quarter turns 0–3: the whole card, long side
  /// [faceInputSide], grey with local contrast equalized (CLAHE, clip 3,
  /// 8×8 tiles). Stage lighting often tints a cheki deep red; in colour the
  /// detector misses such upright faces and finds spurious ones, the
  /// equalized grey image holds up (same fallback as the desktop pipeline).
  static Map<int, img.Image> faceInputs(img.Image card) {
    final scale = faceInputSide / math.max(card.width, card.height);
    final small = img.copyResize(card,
        width: math.max(1, (card.width * scale).round()),
        height: math.max(1, (card.height * scale).round()),
        interpolation: img.Interpolation.average);
    final grey = clahe(small);
    return {
      for (var turn = 0; turn < 4; turn++)
        turn: turn == 0 ? grey : img.copyRotate(grey, angle: -90 * turn),
    };
  }

  /// OpenCV `createCLAHE(clipLimit, (tiles, tiles))` applied to the BT.601
  /// luma of [image]; returned as a grey RGB image.
  static img.Image clahe(img.Image image,
      {double clipLimit = 3.0, int tiles = 8}) {
    final width = image.width, height = image.height;
    final luma = Uint8List(width * height);
    var i = 0;
    for (final p in image) {
      luma[i++] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b)
          .round()
          .clamp(0, 255)
          .toInt();
    }
    // OpenCV pads to a multiple of the tile count (reflect-101).
    final tileW = (width + tiles - 1) ~/ tiles;
    final tileH = (height + tiles - 1) ~/ tiles;
    int reflect(int v, int size) {
      if (size == 1) return 0;
      while (v < 0 || v >= size) {
        v = v < 0 ? -v : 2 * size - 2 - v;
      }
      return v;
    }

    final tileArea = tileW * tileH;
    final clip = math.max(1, (clipLimit * tileArea / 256).toInt());
    final lutScale = 255.0 / tileArea;
    final luts = List.generate(tiles * tiles, (_) => Uint8List(256));
    for (var ty = 0; ty < tiles; ty++) {
      for (var tx = 0; tx < tiles; tx++) {
        final hist = Int32List(256);
        for (var y = ty * tileH; y < (ty + 1) * tileH; y++) {
          final row = reflect(y, height) * width;
          for (var x = tx * tileW; x < (tx + 1) * tileW; x++) {
            hist[luma[row + reflect(x, width)]]++;
          }
        }
        var clipped = 0;
        for (var k = 0; k < 256; k++) {
          if (hist[k] > clip) {
            clipped += hist[k] - clip;
            hist[k] = clip;
          }
        }
        final batch = clipped ~/ 256;
        final residual = clipped - batch * 256;
        for (var k = 0; k < 256; k++) {
          hist[k] += batch;
        }
        if (residual != 0) {
          final step = math.max(256 ~/ residual, 1);
          for (var k = 0, left = residual; k < 256 && left > 0; k += step) {
            hist[k]++;
            left--;
          }
        }
        final lut = luts[ty * tiles + tx];
        var sum = 0;
        for (var k = 0; k < 256; k++) {
          sum += hist[k];
          lut[k] = (sum * lutScale).round().clamp(0, 255).toInt();
        }
      }
    }
    final out = img.Image(width: width, height: height);
    final invW = 1.0 / tileW, invH = 1.0 / tileH;
    for (var y = 0; y < height; y++) {
      final tyf = y * invH - 0.5;
      var ty1 = tyf.floor();
      var ty2 = ty1 + 1;
      final ya = tyf - ty1;
      ty1 = math.max(ty1, 0);
      ty2 = math.min(ty2, tiles - 1);
      for (var x = 0; x < width; x++) {
        final txf = x * invW - 0.5;
        var tx1 = txf.floor();
        var tx2 = tx1 + 1;
        final xa = txf - tx1;
        tx1 = math.max(tx1, 0);
        tx2 = math.min(tx2, tiles - 1);
        final v = luma[y * width + x];
        final top = luts[ty1 * tiles + tx1][v] * (1 - xa) +
            luts[ty1 * tiles + tx2][v] * xa;
        final bottom = luts[ty2 * tiles + tx1][v] * (1 - xa) +
            luts[ty2 * tiles + tx2][v] * xa;
        final g = (top * (1 - ya) + bottom * ya).round().clamp(0, 255).toInt();
        out.setPixelRgb(x, y, g, g, g);
      }
    }
    return out;
  }

  /// Upright-face score of each turn's input → the face direction.
  static int? faceTurnsFromDetections(Map<int, List<FaceDetection>> faces,
          {int? layoutTurns}) =>
      CardOrientationDecider.faceTurns(
          {for (final e in faces.entries) e.key: uprightScore(e.value)},
          layoutTurns: layoutTurns);

  /// Orient a cut card whose film format is settled: the thick border
  /// ([layoutTurns], see [RecordScanMultiCard.layoutTurns]) and the faces
  /// decide together (see [CardOrientationDecider]).
  static Future<(Uint8List, CardOrientation)> orientCardBytes(
    Uint8List bytes, {
    required int layoutTurns,
  }) async {
    final (width, height, windows) = await Isolate.run(() {
      final card = img.decodeImage(bytes)!;
      return (
        card.width,
        card.height,
        {
          for (final e in faceInputs(card).entries)
            e.key: FaceImageOps.bgrFromImage(e.value),
        },
      );
    });
    int? faceTurns;
    try {
      final faces = <int, List<FaceDetection>>{};
      for (final e in windows.entries) {
        faces[e.key] = (await FaceEngine.detect(
          e.value,
          options: const FaceDetectorOptions(
            maxDetectSide: faceInputSide,
            minDetectSide: faceInputSide,
          ),
        ))
            .faces;
      }
      faceTurns = faceTurnsFromDetections(faces, layoutTurns: layoutTurns);
    } on MissingPluginException {
      faceTurns = null;
    } on PlatformException {
      faceTurns = null;
    }
    final orientation = CardOrientationDecider.decide(
      width: width,
      height: height,
      layoutTurns: layoutTurns,
      faceTurns: faceTurns,
    );
    if (orientation.turns == 0) return (bytes, orientation);
    final angle = orientation.clockwiseDegrees;
    final rotated = await Isolate.run(() {
      final decoder = img.findDecoderForData(bytes)!;
      final turned = img.copyRotate(decoder.decode(bytes)!, angle: angle);
      return decoder is img.JpegDecoder
          ? img.encodeJpg(turned, quality: 95)
          : img.encodePng(turned);
    });
    return (rotated, orientation);
  }

  static (Map<int, BgrImage>, int?) _detectorInputs(img.Image image) {
    final longest = math.max(image.width, image.height);
    final small = longest > 384
        ? img.copyResize(image,
            width: image.width * 384 ~/ longest,
            height: image.height * 384 ~/ longest)
        : image;
    final landscape = isLandscapeCard(small.width, small.height);
    final aspect = small.width / small.height;
    final portrait = aspect >= .54 && aspect <= .86;
    if (!landscape && !portrait) return (const {}, null);
    final checkInverted =
        portrait && RecordScanService.mayBeInvertedPortrait(small);
    return (
      {
        0: FaceImageOps.bgrFromImage(small),
        for (final angle in [-90, 90, if (landscape || checkInverted) 180])
          angle: FaceImageOps.bgrFromImage(img.copyRotate(small, angle: angle)),
      },
      landscape ? RecordScanService.sidewaysPrintHint(small) : null
    );
  }

  static Future<int?> _detect(Map<int, BgrImage> sources,
      {required int? paperTurn}) async {
    if (sources.isEmpty) return 0;
    final portrait = sources[0]!.height > sources[0]!.width;
    try {
      Future<double> score(int angle, int side) async {
        final result = await FaceEngine.detect(
          sources[angle]!,
          options: FaceDetectorOptions(
            maxDetectSide: side,
            minDetectSide: side,
            scoreThreshold: .55,
          ),
        );
        return uprightScore(result.faces);
      }

      final baseline = await score(0, 384);
      if (baseline >= .70) return 0;
      final alternatives = sources.keys.skip(1);
      final turn = await choose(
          (angle) async => angle == 0 ? baseline : score(angle, 384),
          alternatives: alternatives);
      if (portrait && turn == 180) return turn;

      if (portrait || turn == 180) {
        // Require two scales for sideways exposure within portrait paper
        // and for a half-turn of a landscape print.
        if (turn == 0) return 0;
        return await choose((angle) => score(angle, 640),
                    alternatives: alternatives) ==
                turn
            ? turn
            : 0;
      }
      if (turn != 0) return turn;
      final second = <int, double>{};
      Future<double> scoreAt640(int angle) async =>
          second[angle] ??= await score(angle, 640);
      final retry = await choose(scoreAt640, alternatives: alternatives);
      if (retry == 180) return 0;
      if (retry != 0) return retry;
      // Glare may leave weak facial landmarks. The physical signature
      // margin can corroborate their direction, but cannot turn a card alone.
      if (paperTurn == null || second[0]! >= .70) return 0;
      final candidate = second[paperTurn]!;
      return candidate >= .68 &&
              candidate -
                      math.max(second[180]!,
                          math.max(second[0]!, second[-paperTurn]!)) >=
                  .12
          ? paperTurn
          : 0;
    } on MissingPluginException {
      // These portraits already kept their geometry on platforms without
      // the detector. Do not make the new quarter-turn check a prerequisite
      // for that path; existing undecided scans still remain retryable.
      return portrait && !sources.containsKey(180) ? 0 : null;
    } on PlatformException {
      return null;
    }
  }

  static double uprightScore(List<FaceDetection> faces) {
    var score = 0.0;
    for (final face in faces) {
      final [eyeL, eyeR, nose, mouthL, mouthR] = face.landmarks;
      final eyeWidth = eyeR.x - eyeL.x;
      if (eyeWidth <= 0 ||
          (eyeL.y - eyeR.y).abs() > eyeWidth * .45 ||
          nose.y <= (eyeL.y + eyeR.y) / 2 ||
          math.min(mouthL.y, mouthR.y) <= nose.y) {
        continue;
      }
      score = math.max(score, face.score);
    }
    return score;
  }

  static Future<int> choose(
    Future<double> Function(int) score, {
    Iterable<int> alternatives = const [-90, 90],
  }) async {
    final native = await score(0);
    if (native >= .70) return 0;
    var bestAngle = 0;
    var best = native;
    var runnerUp = 0.0;
    for (final angle in alternatives) {
      final candidate = await score(angle);
      if (candidate > best) {
        runnerUp = best;
        best = candidate;
        bestAngle = angle;
      } else {
        runnerUp = math.max(runnerUp, candidate);
      }
    }
    return best >= .80 && best - runnerUp >= .12 ? bestAngle : 0;
  }
}
