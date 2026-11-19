import 'dart:math' as math;
import 'dart:typed_data';

/// Attenuates a smooth neutral veil where two nearby patches independently
/// support the same underlying texture. Takes packed, sRGB RGBA8888; returns
/// [source] itself if there is no supported correction. Does not mutate it.
///
/// This deliberately abstains when flanking texture is missing, luminance is
/// clipped, or the apparent veil cannot be distinguished from the subject.
/// Pure Dart: decoding, storage, and isolate scheduling belong to the caller.
Uint8List reduceAlbumGlareRgba(Uint8List source, int width, int height) {
  if (width <= 0 || height <= 0 || source.length != width * height * 4) {
    throw ArgumentError('Expected positive dimensions and packed RGBA8888.');
  }

  // Estimate the veil on a bounded grid; invert it on the original RGB, not
  // on upsampled colors. Each grid coordinate samples an ordinary source pixel.
  final step = (math.max(width, height) + 159) ~/ 160;
  final cols = (width - 1) ~/ step + 1, rows = (height - 1) ~/ step + 1;
  const radius = 2;
  if (math.min(cols, rows) < 2 * radius + 3 ||
      math.max(cols, rows) < 2 * (7 + radius) + 3) {
    return source;
  }
  final linear = Float32List(cols * rows * 3);
  // Negative red marks pixels that cannot provide a reliable color sample.
  for (var y = 0, k = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++, k += 3) {
      final i = (y * step * width + x * step) * 4;
      final r = source[i], g = source[i + 1], b = source[i + 2];
      if (source[i + 3] != 255 || math.max(r, math.max(g, b)) >= 250) {
        linear[k] = -1;
      } else {
        linear[k] = _srgbToLinear[r];
        linear[k + 1] = _srgbToLinear[g];
        linear[k + 2] = _srgbToLinear[b];
      }
    }
  }

  final estimates = Float32List(cols * rows);
  const directions = [(1, 0), (0, 1), (1, 1), (1, -1)];
  for (var y = radius; y < rows - radius; y++) {
    for (var x = radius; x < cols - radius; x++) {
      final p = y * cols + x;
      // Prefer the closest credible reference pair in any direction.
      var amount = 0.0;
      for (final distance in const [7, 12, 20]) {
        for (final (dx, dy) in directions) {
          final sx = distance * dx, sy = distance * dy;
          if (x - sx.abs() < radius ||
              x + sx.abs() >= cols - radius ||
              y - sy.abs() < radius ||
              y + sy.abs() >= rows - radius) {
            continue;
          }
          final candidate = _fitVeil(linear, cols, p, sx + sy * cols);
          if (candidate > 0) {
            // If different reference pairs imply different backgrounds, abstain.
            if (amount > 0 && (candidate - amount).abs() > 0.06) {
              amount = 0;
              break;
            }
            amount = amount == 0 ? candidate : (amount + candidate) / 2;
          }
        }
        if (amount > 0) break;
      }
      estimates[p] = amount;
    }
  }

  // A lone patch match is insufficient. Require agreement across a
  // neighborhood and taper the correction where support starts to fall away.
  final veil = Float32List(estimates.length);
  var supported = false;
  for (var y = radius + 1; y < rows - radius - 1; y++) {
    for (var x = radius + 1; x < cols - radius - 1; x++) {
      final p = y * cols + x;
      final atCenter = estimates[p];
      if (atCenter == 0) continue;
      var sum = 0.0, count = 0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final other = estimates[p + dy * cols + dx];
          if (other > 0 && (other - atCenter).abs() <= 0.05) {
            sum += other;
            count++;
          }
        }
      }
      if (count < 5) continue;
      veil[p] = sum / count * (count - 4) / 5;
      supported = true;
    }
  }
  if (!supported) return source;

  Uint8List? result;
  for (var y = 0; y < height; y++) {
    final gy = y ~/ step, nextY = math.min(gy + 1, rows - 1);
    final fy = (y % step) / step;
    final row = gy * cols, nextRow = nextY * cols;
    for (var x = 0; x < width; x++) {
      final gx = x ~/ step, nextX = math.min(gx + 1, cols - 1);
      final fx = (x % step) / step;
      final top = veil[row + gx] * (1 - fx) + veil[row + nextX] * fx;
      final bottom = veil[nextRow + gx] * (1 - fx) + veil[nextRow + nextX] * fx;
      final amount = top * (1 - fy) + bottom * fy;
      if (amount == 0) continue;
      final i = (y * width + x) * 4;
      if (source[i + 3] != 255) continue;
      final r = source[i], g = source[i + 1], b = source[i + 2];
      final high = math.max(r, math.max(g, b));
      final low = math.min(r, math.min(g, b));
      // White ink and clipped highlights are not reliable recovery targets.
      final chroma = ((high - low - 12) / 16).clamp(0.0, 1.0);
      final headroom = ((250 - high) / 15).clamp(0.0, 1.0);
      // Also leave a margin under the fitted opacity and never create black
      // clipping if a darker feature was missed by the coarse sampling grid.
      final a = math.min(
        0.8 * amount * chroma * headroom,
        0.75 * _srgbToLinear[low],
      );
      if (a == 0) continue;
      final rr = _removeVeil(r, a),
          gg = _removeVeil(g, a),
          bb = _removeVeil(b, a);
      if (rr == r && gg == g && bb == b) continue;
      final out = result ??= Uint8List.fromList(source);
      out[i] = rr;
      out[i + 1] = gg;
      out[i + 2] = bb;
    }
  }
  return result ?? source;
}

/// Fits observed = reference * (1 - a) + a, in linear light. The two
/// flanks must agree on structure, and the fit must beat a plain neutral
/// offset: even a darkenable area is not evidence of a veil by itself.
double _fitVeil(Float32List rgb, int cols, int center, int offset) {
  var samples = 0;
  var amount = 0.0, amountSquared = 0.0;
  var flankError = 0.0, offsetError = 0.0, veilError = 0.0;
  var chroma = 0.0, minLuma = 1.0, maxLuma = 0.0;
  for (var y = -2; y <= 2; y++) {
    for (var x = -2; x <= 2; x++) {
      final c = (center + y * cols + x) * 3;
      final l = c - offset * 3, r = c + offset * 3;
      if (rgb[c] < 0 || rgb[l] < 0 || rgb[r] < 0) continue;
      samples++;
      final red = (rgb[l] + rgb[r]) / 2;
      final green = (rgb[l + 1] + rgb[r + 1]) / 2;
      final blue = (rgb[l + 2] + rgb[r + 2]) / 2;
      final luma = 0.213 * red + 0.715 * green + 0.072 * blue;
      minLuma = math.min(minLuma, luma);
      maxLuma = math.max(maxLuma, luma);
      chroma += math.max(red, math.max(green, blue)) -
          math.min(red, math.min(green, blue));

      var lift = 0.0, liftSquared = 0.0, roomSquared = 0.0, cross = 0.0;
      for (var channel = 0; channel < 3; channel++) {
        final left = rgb[l + channel], right = rgb[r + channel];
        final difference = left - right;
        flankError += difference * difference;
        if (flankError > 75 * 0.025 * 0.025) return 0;
        final reference = (left + right) / 2;
        final d = rgb[c + channel] - reference;
        final h = 1 - reference;
        lift += d;
        liftSquared += d * d;
        roomSquared += h * h;
        cross += d * h;
      }

      final tapAmount = cross / roomSquared;
      amount += tapAmount;
      amountSquared += tapAmount * tapAmount;
      // Compare pixel by pixel, so gradients in the veil itself do not count
      // as color evidence. Neither model gets credit simply for darkening.
      offsetError += liftSquared - lift * lift / 3;
      veilError += liftSquared - tapAmount * cross;
    }
  }
  if (samples < 22 || maxLuma - minLuma < 0.09 || chroma / samples < 0.14) {
    return 0;
  }
  final a = amount / samples;
  if (a < 0.055 ||
      a > 0.36 ||
      amountSquared / samples - a * a > 0.033 * 0.033 ||
      offsetError < 3 * samples * 0.008 * 0.008 ||
      veilError > offsetError * 0.45 ||
      veilError > 3 * samples * 0.014 * 0.014) {
    return 0;
  }
  return a;
}

final _srgbToLinear = List<double>.generate(256, (value) {
  final c = value / 255;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}, growable: false);

int _removeVeil(int value, double amount) {
  final c = (_srgbToLinear[value] - amount) / (1 - amount);
  final srgb =
      c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
  return (srgb * 255).round();
}
