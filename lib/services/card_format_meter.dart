import 'dart:math' as math;
import 'dart:typed_data';

/// instax film formats, outer card and picture window in mm, in the
/// manufacturer's upright layout (thick border at the bottom).
enum FilmFormat {
  mini(54, 86, 46, 62),
  wide(108, 86, 99, 62),
  square(72, 86, 62, 62);

  const FilmFormat(this.width, this.height, this.printWidth, this.printHeight);
  final double width;
  final double height;
  final double printWidth;
  final double printHeight;

  double get longSide => math.max(width, height);
}

/// One format, in one of four turns, fitted to a rectified card.
class FilmFormatCandidate {
  const FilmFormatCandidate({
    required this.format,
    required this.turns,
    required this.score,
    required this.error,
    required this.margins,
    required this.strengths,
    required this.windowRatio,
  });

  final FilmFormat format;

  /// Quarter turns of the upright layout that match the card as it lies in
  /// the quad (TL→TR is the card's width).
  final int turns;
  final double score;

  /// |log| deviation of outer and window ratios from the format.
  final double error;

  /// Window margins as fractions of the card: top, right, bottom, left.
  final List<double> margins;

  /// Paper-to-print step strength on each side (0..1).
  final List<double> strengths;

  /// Window long side over short side.
  final double windowRatio;

  FilmFormatCandidate penalized(double amount) => FilmFormatCandidate(
        format: format,
        turns: turns,
        score: score - amount,
        error: error,
        margins: margins,
        strengths: strengths,
        windowRatio: windowRatio,
      );
}

/// What one card's pixels say about its format.
class CardMeasurement {
  const CardMeasurement({
    required this.axisWidth,
    required this.axisHeight,
    required this.relativeSize,
    required this.candidates,
  });

  /// Card width (along TL→TR) and height (TL→BL) on the photographed plane,
  /// foreshortening removed (arbitrary common scale).
  final double axisWidth;
  final double axisHeight;

  /// Long side over camera distance: compares card sizes within one photo.
  final double relativeSize;
  final List<FilmFormatCandidate> candidates;
}

/// The size a card is cut to.
class CardFormatDecision {
  const CardFormatDecision({
    required this.format,
    required this.width,
    required this.height,
    required this.confidence,
    required this.outerRatio,
    required this.windowRatio,
    required this.best,
  });

  /// Null when the evidence does not settle a film format: the card is then
  /// cut to its measured proportions instead of being forced into one.
  final FilmFormat? format;

  /// Output proportions in the quad's frame (TL→TR is [width]).
  final double width;
  final double height;
  final double confidence;

  /// Measured outer and window long/short ratios (for diagnostics).
  final double outerRatio;
  final double windowRatio;

  /// The winning fit (after the peer-scale vote), matched or not.
  final FilmFormatCandidate best;

  /// Quarter turns counter-clockwise that bring the card, as it lies in the
  /// quad, into the manufacturer's upright layout (thick border at the
  /// bottom); null without a settled format.
  int? get layoutTurns => format == null ? null : best.turns;

  /// Short over long side of the output.
  double get aspectRatio => math.min(width, height) / math.max(width, height);
  bool get portrait => height >= width;
}

/// Decides each card's film format from the card itself rather than from
/// its outline alone:
///
/// * the outline is measured on the photographed plane (a phone-camera
///   prior removes foreshortening, so a slanted card is not read as a
///   different format);
/// * all four picture-window margins are fitted together for instax mini
///   (window 1.35), WIDE (1.60) and SQUARE (1.0) in every turn; the outer
///   and window ratios must both agree;
/// * cards whose evidence is strong set a scale for their neighbours in the
///   same photo (a weaker, size-based vote);
/// * without enough evidence the card keeps its measured proportions.
class CardFormatMeter {
  CardFormatMeter._();

  /// Side of the square, rectified preview the window margins are read on.
  static const int previewSize = 360;

  /// [homography]: unit square → quad in source pixels, 8 coefficients
  /// (a, b, c, d, e, f, g, h; the ninth is 1). [preview]: the quad
  /// rectified to [previewSize]² packed RGB.
  static CardMeasurement measure({
    required List<double> homography,
    required int imageWidth,
    required int imageHeight,
    required Uint8List preview,
  }) {
    final (axisWidth, axisHeight, relativeSize) =
        projectedDimensions(homography, imageWidth, imageHeight);
    final signal = paperSignal(preview, previewSize);
    final (offsets, profiles) = windowProfiles(signal, previewSize);
    return CardMeasurement(
      axisWidth: axisWidth,
      axisHeight: axisHeight,
      relativeSize: relativeSize,
      candidates: measureFormats(offsets, profiles, [axisWidth, axisHeight]),
    );
  }

  /// Card axes on the photographed plane and its relative size.
  ///
  /// Photos forwarded through chat rarely keep focal-length metadata, so a
  /// phone-camera prior (focal = 0.8 × the long image side) is used.
  static (double, double, double) projectedDimensions(
      List<double> h, int imageWidth, int imageHeight) {
    final focal = 0.8 * math.max(imageWidth, imageHeight);
    final cx = imageWidth / 2, cy = imageHeight / 2;
    // Columns of the 3×3 homography, then K⁻¹ applied to each.
    List<double> column(double x, double y, double z) =>
        [(x - cx * z) / focal, (y - cy * z) / focal, z];
    final c0 = column(h[0], h[3], h[6]);
    final c1 = column(h[1], h[4], h[7]);
    final c2 = column(h[2], h[5], 1);
    double norm(List<double> v) =>
        math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    final a0 = norm(c0), a1 = norm(c1);
    final normal = [
      c0[1] * c1[2] - c0[2] * c1[1],
      c0[2] * c1[0] - c0[0] * c1[2],
      c0[0] * c1[1] - c0[1] * c1[0],
    ];
    final n = norm(normal);
    final distance = n <= 0
        ? 0.0
        : (normal[0] * c2[0] + normal[1] * c2[1] + normal[2] * c2[2]).abs() / n;
    return (a0, a1, math.max(a0, a1) / math.max(distance, 1e-6));
  }

  /// Paper evidence per pixel: CIE L* (0–255 scale) minus 1.6 × chroma,
  /// Gaussian-smoothed (5×5). White paper scores high, print and coloured
  /// ink low.
  static Float32List paperSignal(Uint8List rgb, int width, [int? height]) {
    final rows = height ?? width;
    final raw = Float32List(width * rows);
    double linear(int c) {
      final v = c / 255.0;
      return v <= 0.04045
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4) as double;
    }

    final table =
        Float64List.fromList([for (var i = 0; i < 256; i++) linear(i)]);
    double f(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3) as double : 7.787 * t + 16 / 116;
    for (var i = 0, j = 0; i < raw.length; i++, j += 3) {
      final r = table[rgb[j]], g = table[rgb[j + 1]], b = table[rgb[j + 2]];
      final x = (0.412453 * r + 0.357580 * g + 0.180423 * b) / 0.950456;
      final y = 0.212671 * r + 0.715160 * g + 0.072169 * b;
      final z = (0.019334 * r + 0.119193 * g + 0.950227 * b) / 1.088754;
      final fy = f(y);
      final l = y > 0.008856 ? 116 * fy - 16 : 903.3 * y;
      final a = 500 * (f(x) - fy);
      final bb = 200 * (fy - f(z));
      // OpenCV's 8-bit Lab: each channel rounded to an integer first.
      final l8 = (l * 255 / 100).round().clamp(0, 255);
      final a8 = (a.round() + 128).clamp(0, 255) - 128;
      final b8 = (bb.round() + 128).clamp(0, 255) - 128;
      raw[i] = l8 - 1.6 * math.sqrt(a8 * a8 + b8 * b8);
    }
    return _gaussian5(raw, width, rows);
  }

  static Float32List _gaussian5(Float32List src, int width, int height) {
    // OpenCV's kernel for ksize 5 and sigma 0 (σ = 1.1), reflect-101 border.
    const sigma = 1.1;
    final k = [
      for (var i = -2; i <= 2; i++) math.exp(-(i * i) / (2 * sigma * sigma))
    ];
    final sum = k.reduce((a, b) => a + b);
    for (var i = 0; i < 5; i++) {
      k[i] /= sum;
    }
    int reflect(int i, int size) =>
        i < 0 ? -i : (i >= size ? 2 * size - 2 - i : i);
    final tmp = Float32List(width * height);
    for (var y = 0; y < height; y++) {
      final row = y * width;
      for (var x = 0; x < width; x++) {
        var acc = 0.0;
        if (x >= 2 && x < width - 2) {
          for (var t = -2; t <= 2; t++) {
            acc += k[t + 2] * src[row + x + t];
          }
        } else {
          for (var t = -2; t <= 2; t++) {
            acc += k[t + 2] * src[row + reflect(x + t, width)];
          }
        }
        tmp[row + x] = acc;
      }
    }
    final out = Float32List(width * height);
    for (var y = 0; y < height; y++) {
      final rows = [
        for (var t = -2; t <= 2; t++) reflect(y + t, height) * width
      ];
      for (var x = 0; x < width; x++) {
        var acc = 0.0;
        for (var t = 0; t < 5; t++) {
          acc += k[t] * tmp[rows[t] + x];
        }
        out[y * width + x] = acc;
      }
    }
    return out;
  }

  /// For each side (top, right, bottom, left) and each inset from that
  /// edge, how strongly white paper outside steps down into print inside,
  /// averaged over the middle 62 % of the side.
  static (List<double>, List<List<double>>) windowProfiles(
      Float32List signal, int size) {
    final first = (size * 0.018).round();
    final last = (size * 0.25).round();
    final from = (size * 0.19).round(), to = (size * 0.81).round();
    // Value at inset d from a side, position p along it.
    double at(int side, int d, int p) => switch (side) {
          0 => signal[d * size + p],
          1 => signal[p * size + (size - 1 - d)],
          2 => signal[(size - 1 - d) * size + p],
          _ => signal[p * size + d],
        };
    final offsets = <double>[];
    final profiles = List.generate(4, (_) => <double>[]);
    for (var d = first; d < last; d++) {
      offsets.add(d / (size - 1));
      for (var side = 0; side < 4; side++) {
        var acc = 0.0;
        for (var p = from; p < to; p++) {
          // Along the right and left sides the reading runs bottom-up and
          // top-down respectively; the average does not depend on it.
          final paper = at(side, d - 4, p);
          final printed = at(side, d + 4, p);
          acc += ((paper - printed - 5) / 35).clamp(0.0, 1.0) *
              ((paper - 110) / 85).clamp(0.0, 1.0);
        }
        profiles[side].add(acc / (to - from));
      }
    }
    return (offsets, profiles);
  }

  static List<FilmFormatCandidate> measureFormats(
      List<double> offsets, List<List<double>> profiles, List<double> axes) {
    final candidates = <FilmFormatCandidate>[];
    for (final format in FilmFormat.values) {
      final xGap = (1 - format.printWidth / format.width) / 2;
      final yGap = 1 - format.printHeight / format.height;
      // The top margin is about as wide as either side; the extra white
      // belongs at the bottom. All four window edges are fitted together.
      final standard = [xGap, xGap, yGap - xGap, xGap];
      for (var turns = 0; turns < 4; turns++) {
        final margins = <double>[];
        final strengths = <double>[];
        var fitSum = 0.0;
        for (var side = 0; side < 4; side++) {
          final expected = standard[(side - turns) % 4];
          var best = double.negativeInfinity;
          var bestIndex = 0;
          for (var k = 0; k < offsets.length; k++) {
            final dev = (offsets[k] - expected).abs() / 0.05;
            final fit = profiles[side][k] - 0.48 * dev * dev;
            if (fit > best) {
              best = fit;
              bestIndex = k;
            }
          }
          margins.add(offsets[bestIndex]);
          strengths.add(profiles[side][bestIndex]);
          fitSum += best;
        }
        final windowW = axes[0] * (1 - margins[1] - margins[3]);
        final windowH = axes[1] * (1 - margins[0] - margins[2]);
        final outerRatio = turns.isEven ? axes[0] / axes[1] : axes[1] / axes[0];
        final innerRatio = turns.isEven ? windowW / windowH : windowH / windowW;
        final error = (math.log(outerRatio / (format.width / format.height)))
                .abs() +
            (math.log(innerRatio / (format.printWidth / format.printHeight)))
                .abs();
        candidates.add(FilmFormatCandidate(
          format: format,
          turns: turns,
          score: fitSum / 4 - 1.4 * error,
          error: error,
          margins: margins,
          strengths: strengths,
          windowRatio: math.max(innerRatio, 1 / innerRatio),
        ));
      }
    }
    return candidates;
  }

  /// Settles the cards of one photo together (peer scale).
  static List<CardFormatDecision> decide(List<CardMeasurement> cards) {
    FilmFormatCandidate best(List<FilmFormatCandidate> c) =>
        c.reduce((a, b) => b.score > a.score ? b : a);
    final scales = <double>[];
    for (final card in cards) {
      final top = best(card.candidates);
      if (top.strengths.reduce(math.min) > 0.4 && top.error < 0.12) {
        scales.add(card.relativeSize / top.format.longSide);
      }
    }
    double? peerScale;
    if (scales.length >= 2) {
      scales.sort();
      final mid = scales.length ~/ 2;
      peerScale = scales.length.isOdd
          ? scales[mid]
          : (scales[mid - 1] + scales[mid]) / 2;
    }
    return [
      for (final card in cards) _decideOne(card, peerScale, best),
    ];
  }

  static CardFormatDecision _decideOne(
    CardMeasurement card,
    double? peerScale,
    FilmFormatCandidate Function(List<FilmFormatCandidate>) bestOf,
  ) {
    var candidates = card.candidates;
    if (peerScale != null) {
      candidates = [
        for (final c in candidates)
          c.penalized(0.18 *
              math.min(
                  (math.log(
                          card.relativeSize / (c.format.longSide * peerScale)))
                      .abs(),
                  0.5)),
      ];
    }
    final best = bestOf(candidates);
    final runnerUp = candidates
        .where((c) => c.format != best.format)
        .map((c) => c.score)
        .reduce(math.max);
    final separation = best.score - runnerUp;
    final meanStrength = best.strengths.reduce((a, b) => a + b) / 4;
    final confidence = meanStrength *
        math.max(0, 1 - best.error / 0.4) *
        math.min(1, separation / 0.14);
    final matched = best.strengths.reduce(math.min) >= 0.21 &&
        best.error <= 0.24 &&
        separation >= 0.045;
    var width = card.axisWidth, height = card.axisHeight;
    if (matched) {
      width = best.format.width;
      height = best.format.height;
      if (best.turns.isOdd) (width, height) = (height, width);
    }
    return CardFormatDecision(
      format: matched ? best.format : null,
      width: width,
      height: height,
      confidence: confidence.toDouble(),
      outerRatio: math.max(card.axisWidth, card.axisHeight) /
          math.min(card.axisWidth, card.axisHeight),
      windowRatio: best.windowRatio,
      best: best,
    );
  }
}
