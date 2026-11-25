import 'dart:math' as math;
import 'dart:typed_data';

import 'card_format_meter.dart';

/// [CardFormatMeter.paperSignal] over a whole photo, sampled bilinearly with
/// a replicated border (OpenCV `remap` + `BORDER_REPLICATE`). Coordinates are
/// source pixels, the same frame as the scanner's quads.
class PaperSignalImage {
  PaperSignalImage(this.width, this.height, this.data);

  factory PaperSignalImage.fromRgb(Uint8List rgb, int width, int height) =>
      PaperSignalImage(
          width, height, CardFormatMeter.paperSignal(rgb, width, height));

  final int width;
  final int height;
  final Float32List data;

  double sample(double x, double y) {
    final maxX = width - 1, maxY = height - 1;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x > maxX) x = maxX.toDouble();
    if (y > maxY) y = maxY.toDouble();
    final ix = x.floor(), iy = y.floor();
    final fx = x - ix, fy = y - iy;
    final ix1 = ix < maxX ? ix + 1 : ix;
    final iy1 = iy < maxY ? iy + 1 : iy;
    final r0 = iy * width, r1 = iy1 * width;
    final top = data[r0 + ix] + (data[r0 + ix1] - data[r0 + ix]) * fx;
    final bottom = data[r1 + ix] + (data[r1 + ix1] - data[r1 + ix]) * fx;
    return top + (bottom - top) * fy;
  }
}

typedef Pt = math.Point<double>;

/// Fits each card side to the white paper edge on the source pixels, so the
/// cut neither carries background nor clips the picture. A port of the
/// desktop pipeline's `refine_quad` / `tighten_paper_edges`; every change is
/// guarded and the input quad is returned whenever the evidence is weak.
class CardEdgeFit {
  CardEdgeFit._();

  /// Re-fits all four sides near their current position (within 24 % of the
  /// shortest side), slope and offset together. Sides without a coherent
  /// paper step keep their line.
  ///
  /// [reach] is the search range as a share of the shortest side; a quad
  /// already on its paper edges ([CardLocator]) is only polished with a
  /// small one.
  static List<Pt> refineQuad(PaperSignalImage signal, List<Pt> quad,
      {double reach = 0.24}) {
    final shortest = [
      for (var i = 0; i < 4; i++) quad[i].distanceTo(quad[(i + 1) % 4])
    ].reduce(math.min);
    if (shortest < 24) return quad;
    final lines = [
      for (var i = 0; i < 4; i++)
        _fitBorder(signal, quad[i], quad[(i + 1) % 4], shortest, reach)
    ];
    final candidate = _corners(lines);
    if (candidate == null ||
        !_validInside(candidate, signal) ||
        _maxMove(candidate, quad) > 0.45 * shortest) {
      return quad;
    }
    final ratio = _signedArea(candidate) / _signedArea(quad);
    if (!(ratio >= 0.65 && ratio <= 1.3)) return quad;
    return candidate;
  }

  static (Pt, Pt) _fitBorder(
      PaperSignalImage signal, Pt start, Pt end, double shortSide,
      [double reachShare = 0.24]) {
    final dx = end.x - start.x, dy = end.y - start.y;
    final length = math.sqrt(dx * dx + dy * dy);
    final ax = dx / length, ay = dy / length; // along
    final nx = -ay, ny = ax; // inward for a clockwise (screen) quad
    final mx = (start.x + end.x) / 2, my = (start.y + end.y) / 2;
    const count = 81;
    final distance = Float64List(count);
    for (var j = 0; j < count; j++) {
      distance[j] = (-0.41 + 0.82 * j / (count - 1)) * length;
    }
    final reach = reachShare * shortSide;
    // The move penalty keeps the full search's scale: a narrow polish must
    // still settle on the paper step, not stay where it started.
    final penaltyScale = 0.24 * shortSide;
    final depth = (shortSide * 0.01).clamp(2.0, 5.0);

    // Scores of every offset at one slope: paper-to-background step support
    // minus a small pull towards the current line.
    (Float64List, Float64List) evaluate(
        double slope, List<double> offsets, double sampleDepth) {
      final scores = Float64List(offsets.length);
      final supports = Float64List(offsets.length);
      for (var o = 0; o < offsets.length; o++) {
        var support = 0.0, moved = 0.0;
        for (var j = 0; j < count; j++) {
          final d = distance[j];
          final disp = offsets[o] + slope * d;
          final px = mx + d * ax + disp * nx, py = my + d * ay + disp * ny;
          final inside =
              signal.sample(px + sampleDepth * nx, py + sampleDepth * ny);
          final outside =
              signal.sample(px - sampleDepth * nx, py - sampleDepth * ny);
          support += ((inside - outside - 3) / 22).clamp(0.0, 1.0) *
              ((inside - 110) / 70).clamp(0.0, 1.0);
          moved += disp.abs();
        }
        support /= count;
        supports[o] = support;
        scores[o] = support - 0.12 * (moved / count) / penaltyScale;
      }
      return (scores, supports);
    }

    List<double> linspace(double a, double b, int n) =>
        [for (var i = 0; i < n; i++) a + (b - a) * i / (n - 1)];

    // Python tuple comparison: score, then offset, then slope.
    bool better(
            double s, double o, double sl, double bs, double bo, double bsl) =>
        s > bs || (s == bs && (o > bo || (o == bo && sl > bsl)));

    var bestScore = -1.0, center = 0.0, angle = 0.0;
    final coarse = linspace(-reach, reach, 101);
    for (final slope in linspace(-0.26, 0.26, 53)) {
      final (scores, _) = evaluate(slope, coarse, depth);
      final i = _argmax(scores);
      if (better(scores[i], coarse[i], slope, bestScore, center, angle)) {
        (bestScore, center, angle) = (scores[i], coarse[i], slope);
      }
    }
    // A narrower contrast band locates the transition instead of a broad
    // plateau where both samples already land on opposite sides of it.
    bestScore = -1.0;
    var offset = 0.0, slope = 0.0, support = 0.0;
    final fine = linspace(center - depth, center + depth, 17);
    for (final s in linspace(angle - 0.012, angle + 0.012, 9)) {
      final (scores, supports) = evaluate(s, fine, math.max(1.5, depth * 0.55));
      final i = _argmax(scores);
      if (better(scores[i], fine[i], s, bestScore, offset, slope)) {
        (bestScore, offset, slope, support) =
            (scores[i], fine[i], s, supports[i]);
      }
    }
    if (support < 0.31) return (start, end);
    final o0 = offset - slope * length / 2, o1 = offset + slope * length / 2;
    return (
      math.Point(start.x + o0 * nx, start.y + o0 * ny),
      math.Point(end.x + o1 * nx, end.y + o1 * ny),
    );
  }

  /// Moves only sides with coherent evidence that the cut still includes
  /// background beyond the paper (a visible sliver along most of the side),
  /// by at most a few pixels. Returns [quad] itself when nothing changed.
  static List<Pt> tightenPaperEdges(PaperSignalImage signal, List<Pt> quad) {
    final h = _homography(quad);
    const unit = [
      math.Point(0.0, 0.0),
      math.Point(1.0, 0.0),
      math.Point(1.0, 1.0),
      math.Point(0.0, 1.0),
    ];
    const columns = 100;
    final t = [
      for (var i = 0; i < columns; i++) 0.065 + 0.87 * i / (columns - 1)
    ];
    final offsets = [for (var i = 0; i < 65; i++) -8.0 + 0.25 * i];
    final lines = <(Pt, Pt)>[];
    var changed = false;
    for (var i = 0; i < 4; i++) {
      final j = (i + 1) % 4, k = (i + 2) % 4, l = (i + 3) % 4;
      final thickness =
          (quad[l].distanceTo(quad[i]) + quad[k].distanceTo(quad[j])) / 2;
      final inX = unit[l].x - unit[i].x, inY = unit[l].y - unit[i].y;
      final samples =
          List.generate(offsets.length, (_) => Float64List(columns));
      for (var r = 0; r < offsets.length; r++) {
        final o = offsets[r] / thickness;
        for (var c = 0; c < columns; c++) {
          final u = unit[i].x + t[c] * (unit[j].x - unit[i].x) + o * inX;
          final v = unit[i].y + t[c] * (unit[j].y - unit[i].y) + o * inY;
          final p = _apply(h, u, v);
          samples[r][c] = signal.sample(p.x, p.y);
        }
      }
      final edges = Float64List(columns);
      final valid = List<bool>.filled(columns, false);
      for (var c = 0; c < columns; c++) {
        var peak = 0;
        var best = double.negativeInfinity;
        for (var r = 0; r + 5 < offsets.length; r++) {
          final contrast = samples[r + 5][c] - samples[r][c];
          if (contrast > best) {
            best = contrast;
            peak = r;
          }
        }
        edges[c] = offsets[peak] + 0.625;
        valid[c] = best > 7 && samples[peak + 5][c] > 115 && edges[c].abs() < 7;
      }
      var a = quad[i], b = quad[j];
      final validIdx = [
        for (var c = 0; c < columns; c++)
          if (valid[c]) c
      ];
      final minSliver = math.max(2.0, 0.0035 * thickness);
      final slivers = validIdx.where((c) => edges[c] > minSliver).length;
      // 0.35 % of the distance to the opposite side is well below a mm on
      // film. Require a sliver on a substantial part of the side, not an
      // isolated pen stroke, a rounded corner or interpolation.
      if (validIdx.length >= 60 &&
          slivers >= 18 &&
          t[validIdx.last] - t[validIdx.first] > 0.6) {
        final fit = _huberLine([
          for (final c in validIdx) math.Point(40 * t[c], edges[c]),
        ]);
        if (fit != null && fit.$1.abs() >= 0.5) {
          final (vx, vy, x0, y0) = fit;
          double line(double x) => y0 + (x - x0) * vy / vx;
          final residuals = [
            for (final c in validIdx) (edges[c] - line(40 * t[c])).abs()
          ]..sort();
          final median = residuals.length.isOdd
              ? residuals[residuals.length ~/ 2]
              : (residuals[residuals.length ~/ 2 - 1] +
                      residuals[residuals.length ~/ 2]) /
                  2;
          final close = residuals.where((r) => r < 1.8).length;
          if (median < 1.2 && close >= 0.68 * residuals.length) {
            // Subpixel inward allowance for interpolation at the transition.
            final e0 = (line(0) + 0.6).clamp(-7.0, 7.0) / thickness;
            final e1 = (line(40) + 0.6).clamp(-7.0, 7.0) / thickness;
            a = _apply(h, unit[i].x + e0 * inX, unit[i].y + e0 * inY);
            b = _apply(h, unit[j].x + e1 * inX, unit[j].y + e1 * inY);
            changed = true;
          }
        }
      }
      lines.add((a, b));
    }
    if (!changed) return quad;
    final updated = _corners(lines);
    if (updated == null ||
        !_validInside(updated, signal) ||
        _maxMove(updated, quad) > 10) {
      return quad;
    }
    return updated;
  }

  /// cv2.fitLine(DIST_HUBER): reweighted least squares, C = 1.345.
  /// Returns (vx, vy, x0, y0) or null for degenerate input.
  static (double, double, double, double)? _huberLine(List<Pt> points) {
    if (points.length < 2) return null;
    final weights = List<double>.filled(points.length, 1);
    (double, double, double, double)? fit;
    for (var iteration = 0; iteration < 30; iteration++) {
      var sw = 0.0, sx = 0.0, sy = 0.0;
      for (var i = 0; i < points.length; i++) {
        sw += weights[i];
        sx += weights[i] * points[i].x;
        sy += weights[i] * points[i].y;
      }
      if (sw <= 0) return fit;
      final x0 = sx / sw, y0 = sy / sw;
      var xx = 0.0, xy = 0.0, yy = 0.0;
      for (var i = 0; i < points.length; i++) {
        final dx = points[i].x - x0, dy = points[i].y - y0;
        xx += weights[i] * dx * dx;
        xy += weights[i] * dx * dy;
        yy += weights[i] * dy * dy;
      }
      final theta = 0.5 * math.atan2(2 * xy, xx - yy);
      final next = (math.cos(theta), math.sin(theta), x0, y0);
      if (fit != null &&
          (next.$3 - fit.$3).abs() + (next.$4 - fit.$4).abs() < 0.01 &&
          (next.$1 * fit.$2 - next.$2 * fit.$1).abs() < 0.01) {
        return next;
      }
      fit = next;
      for (var i = 0; i < points.length; i++) {
        final d =
            ((points[i].x - x0) * next.$2 - (points[i].y - y0) * next.$1).abs();
        weights[i] = d < 1.345 ? 1 : 1.345 / d;
      }
    }
    return fit;
  }

  static int _argmax(Float64List values) {
    var best = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] > values[best]) best = i;
    }
    return best;
  }

  /// Corner i is where side i-1 meets side i.
  static List<Pt>? _corners(List<(Pt, Pt)> lines) {
    final corners = <Pt>[];
    for (var i = 0; i < 4; i++) {
      final (a, b) = lines[(i + 3) % 4];
      final (c, d) = lines[i];
      final m00 = b.x - a.x, m01 = c.x - d.x;
      final m10 = b.y - a.y, m11 = c.y - d.y;
      final det = m00 * m11 - m01 * m10;
      if (det.abs() < 1e-12) return null;
      final rx = c.x - a.x, ry = c.y - a.y;
      final t = (rx * m11 - m01 * ry) / det;
      final p = math.Point(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y));
      if (!p.x.isFinite || !p.y.isFinite) return null;
      corners.add(p);
    }
    return corners;
  }

  static bool _validInside(List<Pt> q, PaperSignalImage signal) {
    for (final p in q) {
      if (p.x < 0 ||
          p.y < 0 ||
          p.x > signal.width - 1 ||
          p.y > signal.height - 1) {
        return false;
      }
    }
    // cv2.isContourConvex: every turn has the same sign.
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
      final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
      final s = cross.sign.toInt();
      if (s == 0) return false;
      if (sign == 0) sign = s;
      if (s != sign) return false;
    }
    return true;
  }

  static double _maxMove(List<Pt> a, List<Pt> b) =>
      [for (var i = 0; i < 4; i++) a[i].distanceTo(b[i])].reduce(math.max);

  static double _signedArea(List<Pt> q) {
    var area = 0.0;
    for (var i = 0; i < q.length; i++) {
      final a = q[i], b = q[(i + 1) % q.length];
      area += a.x * b.y - b.x * a.y;
    }
    return area / 2;
  }

  /// Unit square (TL, TR, BR, BL) → [q]: a b c / d e f / g h 1.
  static List<double> _homography(List<Pt> q) {
    final x0 = q[0].x, y0 = q[0].y;
    final x1 = q[1].x, y1 = q[1].y;
    final x2 = q[2].x, y2 = q[2].y;
    final x3 = q[3].x, y3 = q[3].y;
    final sx = x0 - x1 + x2 - x3;
    final sy = y0 - y1 + y2 - y3;
    if (sx.abs() < 1e-9 && sy.abs() < 1e-9) {
      return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0, 0];
    }
    final dx1 = x1 - x2, dx2 = x3 - x2;
    final dy1 = y1 - y2, dy2 = y3 - y2;
    final den = dx1 * dy2 - dx2 * dy1;
    final g = (sx * dy2 - dx2 * sy) / den;
    final hh = (dx1 * sy - sx * dy1) / den;
    return [
      x1 - x0 + g * x1,
      x3 - x0 + hh * x3,
      x0,
      y1 - y0 + g * y1,
      y3 - y0 + hh * y3,
      y0,
      g,
      hh,
    ];
  }

  static Pt _apply(List<double> h, double u, double v) {
    final w = h[6] * u + h[7] * v + 1;
    return math.Point(
        (h[0] * u + h[1] * v + h[2]) / w, (h[3] * u + h[4] * v + h[5]) / w);
  }
}
