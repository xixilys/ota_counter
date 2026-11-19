import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import 'face/face_engine.dart';
import 'face/face_image_ops.dart';
import 'face/face_models.dart';
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
  static Future<Uint8List> orientScanBytes(Uint8List bytes) async {
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
    if (turn == null || turn == 0) return bytes;
    final angle = turn;
    return Isolate.run(() {
      final decoder = img.findDecoderForData(bytes)!;
      final rotated = img.copyRotate(decoder.decode(bytes)!, angle: angle);
      return decoder is img.JpegDecoder
          ? img.encodeJpg(rotated, quality: 95)
          : img.encodePng(rotated);
    });
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
