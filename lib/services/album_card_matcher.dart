import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Finds the same physical card in already deskewed, paper-frame-checked scans.
///
/// Returns a zero-based [rescanned] index (or null) for each [archived] image.
/// A scan can satisfy several attachments. Distinct plausible identities
/// cause abstention. A view with new broad glare is ineligible; confirmed
/// usable views of the same card compete on image quality.
/// Inputs are encoded images, not full camera photos on the rescanned side.
Future<List<int?>> matchAlbumCards(
  List<Uint8List> archived,
  List<Uint8List> rescanned,
) {
  if (archived.isEmpty || rescanned.isEmpty) {
    return Future.value(List<int?>.filled(archived.length, null));
  }
  return Isolate.run(() => _matchAll(archived, rescanned, _Card.decode));
}

/// File-backed equivalent of [matchAlbumCards] for a whole candidate pool.
///
/// Reads and decodes one image at a time in the matching isolate. Only
/// candidate descriptions, not their encoded or full-size decoded pixels,
/// stay resident across attachments. An I/O failure aborts the batch so
/// callers cannot inadvertently publish against a partial candidate pool.
Future<List<int?>> matchAlbumCardFiles(
  List<String> archives,
  List<String> candidates,
) {
  if (archives.isEmpty || candidates.isEmpty) {
    return Future.value(List<int?>.filled(archives.length, null));
  }
  return Isolate.run(() => _matchAll(
        archives,
        candidates,
        (path, turns) => _Card.decode(File(path).readAsBytesSync(), turns),
      ));
}

sealed class AlbumCardRecovery {
  const AlbumCardRecovery();
}

final class AlbumCardRescan extends AlbumCardRecovery {
  final int candidateIndex;
  const AlbumCardRescan(this.candidateIndex);
}

final class AlbumCardReprojection extends AlbumCardRecovery {
  /// An upright PNG made only from the archived pixels. Missing areas have
  /// zero alpha; consume it as a display derivative, not as an original.
  final Uint8List pngBytes;
  const AlbumCardReprojection(this.pngBytes);
}

/// Chooses one result per archive, in input order, from checked paper-frame
/// candidates. Use this instead of calling [matchAlbumCardFiles] first.
/// A near-complete archive may be reprojected if its unique reference is
/// rejected for new glare. Neither the archives nor the candidates change.
Future<List<AlbumCardRecovery?>> recoverAlbumCardFiles(
  List<String> archives,
  List<String> candidates,
) {
  if (archives.isEmpty || candidates.isEmpty) {
    return Future.value(List<AlbumCardRecovery?>.filled(archives.length, null));
  }
  return Isolate.run(() {
    final scans = candidates
        .map((path) => _Card.decode(File(path).readAsBytesSync(), 1))
        .toList();
    final sameView = <(int, int), bool>{};
    final results = <AlbumCardRecovery?>[];
    for (final path in archives) {
      final original = _Card.readImage(File(path).readAsBytesSync());
      if (original == null) {
        results.add(null);
        continue;
      }
      final old = _Card.describe(original, _turns);
      final choice = _pick(old, scans, sameView, recoverGlare: true);
      if (choice == null) {
        results.add(null);
      } else if (choice.projection case final transform?) {
        final png =
            _reproject(original, old.raster, scans[choice.index]!, transform);
        results.add(png == null ? null : AlbumCardReprojection(png));
      } else {
        results.add(AlbumCardRescan(choice.index));
      }
    }
    return results;
  });
}

typedef _Selection = ({int index, Float64List? projection});

List<int?> _matchAll<T>(
  List<T> archived,
  List<T> rescanned,
  _Card? Function(T input, int turns) load,
) {
  final scans = rescanned.map((candidate) => load(candidate, 1)).toList();
  final sameView = <(int, int), bool>{};
  return [
    for (final attachment in archived)
      _pick(load(attachment, _turns), scans, sameView)?.index,
  ];
}

_Selection? _pick(
  _Card? old,
  List<_Card?> scans,
  Map<(int, int), bool> sameView, {
  bool recoverGlare = false,
}) {
  if (old == null) return null;
  final matches = <(int, _Evidence)>[];
  for (final (i, scan) in scans.indexed) {
    if (scan == null) continue;
    final evidence = _compare(scan, old, recoverGlare: recoverGlare);
    if (evidence != null) matches.add((i, evidence));
  }
  final ordinary = matches.where((m) => m.$2.isMatch).toList();
  ordinary.sort((a, b) {
    if (a.$2.losesHighlights != b.$2.losesHighlights) {
      return a.$2.losesHighlights ? 1 : -1;
    }
    return b.$2.agreement.compareTo(a.$2.agreement);
  });
  bool sameCard(int anchor, int other) =>
      sameView.putIfAbsent((anchor, other), () {
        final view = scans[anchor]!;
        final evidence = _compare(
          scans[other]!,
          _Card(view.raster, _turns, view.sourceSize),
        );
        // A small shared crop cannot make two views interchangeable.
        return evidence != null &&
            evidence.agreement >= .76 &&
            evidence.overlap >= .83 &&
            evidence.conflict <= .16;
      });

  if (ordinary.isNotEmpty && !ordinary.first.$2.losesHighlights) {
    final anchor = ordinary.first.$1;
    var best = anchor;
    for (final (i, candidate) in ordinary.skip(1)) {
      if (!sameCard(anchor, i)) return null;
      if (!candidate.losesHighlights &&
          scans[i]!.quality > scans[best]!.quality) {
        best = i;
      }
    }
    return (index: best, projection: null);
  }
  if (!recoverGlare) return null;
  final supported = matches.where((m) => m.$2.projection != null).toList()
    ..sort((a, b) => b.$2.agreement.compareTo(a.$2.agreement));
  if (supported.isEmpty) return null;
  final (anchor, evidence) = supported.first;
  for (final (i, _) in matches) {
    if (i != anchor && !sameCard(anchor, i)) return null;
  }
  return (index: anchor, projection: evidence.projection);
}

const _turns = 8;
const _side = 360;
const _descriptorWords = 4;
const _radius = 11;

class _Card {
  final _Raster raster;
  final List<_Feature> features;
  late final double quality = raster.detail;
  late final index = _DescriptorIndex(features);

  final ({int width, int height}) sourceSize;
  _Card(this.raster, int turns, this.sourceSize)
      : features = _features(raster, turns);

  static _Card? decode(Uint8List bytes, int turns) {
    final image = readImage(bytes);
    return image == null ? null : describe(image, turns);
  }

  static img.Image? readImage(Uint8List bytes) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } on img.ImageException {
      return null;
    } on RangeError {
      return null;
    }
    if (decoded == null || math.min(decoded.width, decoded.height) < 40) {
      return null;
    }
    final orientation = decoded.exif.imageIfd.orientation;
    return orientation != null && orientation != 1
        ? img.bakeOrientation(decoded)
        : decoded;
  }

  static _Card describe(img.Image image, int turns) {
    final scale = math.min(1.0, _side / math.max(image.width, image.height));
    final w = (image.width * scale).round();
    final h = (image.height * scale).round();
    final sampled = scale == 1
        ? image
        : img.copyResize(image,
            width: w, height: h, interpolation: img.Interpolation.average);
    final gray = Float32List(w * h);
    for (final p in sampled) {
      gray[p.y * w + p.x] = p.luminance.toDouble();
    }
    return _Card(
      _Raster(w, h, gray),
      turns,
      (width: image.width, height: image.height),
    );
  }
}

class _Raster {
  final int w, h;
  final Float32List gray;

  _Raster(this.w, this.h, this.gray);

  double sample(double x, double y) {
    final ix = x.floor(), iy = y.floor();
    final dx = x - ix, dy = y - iy;
    final i = iy * w + ix;
    return (gray[i] * (1 - dx) + gray[i + 1] * dx) * (1 - dy) +
        (gray[i + w] * (1 - dx) + gray[i + w + 1] * dx) * dy;
  }

  double get detail {
    // Work at the same display scale across candidates. Count midtone edge
    // detail, not grain or blown-out white borders.
    var total = 0.0;
    var n = 0;
    for (var y = h ~/ 8; y < h * 7 ~/ 8; y += 2) {
      for (var x = w ~/ 8; x < w * 7 ~/ 8; x += 2) {
        final i = y * w + x;
        final center = gray[i];
        if (center > 12 && center < 243) {
          total += math.min(
            30,
            (gray[i - 1] + gray[i + 1] + gray[i - w] + gray[i + w] - 4 * center)
                .abs(),
          );
        }
        n++;
      }
    }
    return total / n;
  }
}

class _Feature {
  // Coordinates in units of [_side], centered in the image.
  final double x, y;
  final Uint32List bits;
  _Feature(this.x, this.y, this.bits);
}

// Fixed, rotation-indexed binary comparisons over a smoothed local patch.
final _patterns = () {
  final random = math.Random(42);
  final points = List.generate(_descriptorWords * 32 * 2, (_) {
    final angle = random.nextDouble() * 2 * math.pi;
    final radius = (1 - random.nextDouble() * random.nextDouble()) * 10;
    return (math.cos(angle) * radius, math.sin(angle) * radius);
  });
  return List.generate(_turns, (turn) {
    final angle = turn * 2 * math.pi / _turns;
    final c = math.cos(angle), s = math.sin(angle);
    return [
      for (final (x, y) in points)
        ((c * x - s * y).round(), (s * x + c * y).round()),
    ];
  });
}();

List<_Feature> _features(_Raster raster, int turns) {
  final features = <_Feature>[];
  final base = raster;
  for (final reduction in [1.0, 1.42, 2.0, 2.82, 4.0]) {
    final w = (base.w / reduction).round();
    final h = (base.h / reduction).round();
    if (math.min(w, h) < 50) break;
    final xs = base.w / w, ys = base.h / h;
    final gray = Float32List(w * h);
    // Area-like 2x2 sampling keeps the pyramid and its comparisons stable
    // under scale changes, and suppresses JPEG ringing.
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final x0 = (x - .4) * xs, x1 = (x + .4) * xs;
        final y0 = (y - .4) * ys, y1 = (y + .4) * ys;
        gray[y * w + x] = (base.sample(x0, y0) +
                base.sample(x1, y0) +
                base.sample(x0, y1) +
                base.sample(x1, y1)) *
            .25;
      }
    }
    final corners = Float32List(w * h);
    for (var y = _radius; y < h - _radius; y++) {
      for (var x = _radius; x < w - _radius; x++) {
        var xx = 0.0, yy = 0.0, xy = 0.0;
        for (var dy = -1; dy <= 1; dy++) {
          final row = (y + dy) * w + x;
          for (var i = row - 1; i <= row + 1; i++) {
            final gx = gray[i + 1] - gray[i - 1];
            final gy = gray[i + w] - gray[i - w];
            xx += gx * gx;
            yy += gy * gy;
            xy += gx * gy;
          }
        }
        // Harmonic mean of the gradient eigenvalues: rejects straight edges.
        final trace = xx + yy;
        if (trace > 160) corners[y * w + x] = (xx * yy - xy * xy) / trace;
      }
    }
    final cells = List.generate(36, (_) => <int>[]);
    for (var y = _radius; y < h - _radius; y++) {
      for (var x = _radius; x < w - _radius; x++) {
        final i = y * w + x;
        final score = corners[i];
        if (score < 130 ||
            score <= corners[i - 1] ||
            score <= corners[i + 1] ||
            score <= corners[i - w] ||
            score <= corners[i + w] ||
            score <= corners[i - w - 1] ||
            score <= corners[i - w + 1] ||
            score <= corners[i + w - 1] ||
            score <= corners[i + w + 1]) {
          continue;
        }
        cells[(y * 6 ~/ h) * 6 + x * 6 ~/ w].add(i);
      }
    }
    for (final cell in cells) {
      cell.sort((a, b) => corners[b].compareTo(corners[a]));
      final chosen = <(int, int)>[];
      for (final i in cell) {
        final x = i % w, y = i ~/ w;
        if (chosen.any(
            (p) => (p.$1 - x) * (p.$1 - x) + (p.$2 - y) * (p.$2 - y) < 25)) {
          continue;
        }
        chosen.add((x, y));
        final bits = Uint32List(turns * _descriptorWords);
        for (var turn = 0; turn < turns; turn++) {
          final pattern = _patterns[turn];
          for (var k = 0; k < _descriptorWords; k++) {
            var word = 0;
            for (var b = 0; b < 32; b++) {
              final j = 2 * (k * 32 + b);
              final (ax, ay) = pattern[j];
              final (bx, by) = pattern[j + 1];
              if (gray[i + ay * w + ax] < gray[i + by * w + bx]) {
                word |= 1 << b;
              }
            }
            bits[turn * _descriptorWords + k] = word;
          }
        }
        features.add(
            _Feature((x - w / 2) * xs / _side, (y - h / 2) * ys / _side, bits));
        if (chosen.length == 4) break;
      }
    }
  }
  return features;
}

int _pop(int word) {
  word -= (word >>> 1) & 0x55555555;
  word = (word & 0x33333333) + ((word >>> 2) & 0x33333333);
  word = (word + (word >>> 4)) & 0x0f0f0f0f;
  return (word + (word >>> 8) + (word >>> 16) + (word >>> 24)) & 63;
}

class _Pair {
  final _Feature scan, old;
  final int distance;
  _Pair(this.scan, this.old, this.distance);
}

// Shortlist binary descriptors that share an exact byte in at least one
// band. Linked buckets use bounded typed storage, rather than one object
// per hash entry. Full Hamming distance still ranks the shortlisted points.
class _DescriptorIndex {
  static const bands = _descriptorWords * 4;
  final heads = Uint16List(bands * 256);
  final Uint16List next;

  _DescriptorIndex(List<_Feature> features)
      : next = Uint16List(features.length * bands) {
    for (final (i, feature) in features.indexed) {
      for (var band = 0; band < bands; band++) {
        final byte = (feature.bits[band ~/ 4] >>> ((band % 4) * 8)) & 255;
        final slot = band * 256 + byte;
        next[i * bands + band] = heads[slot];
        heads[slot] = i + 1;
      }
    }
  }
}

List<_Pair> _correspondences(_Card scan, _Card old) {
  final targets = scan.features;
  final index = scan.index;
  const bands = _DescriptorIndex.bands;
  final distances = Uint8List(targets.length);
  final visited = Uint32List(targets.length);
  var stamp = 0;
  final unique = <int, _Pair>{};
  for (final q in old.features) {
    var minDistance = 129, best = 0;
    distances.fillRange(0, distances.length, 129);
    final qb = q.bits;
    for (var k = 0; k < qb.length; k += _descriptorWords) {
      stamp++;
      final a = qb[k], b = qb[k + 1], c = qb[k + 2], d = qb[k + 3];
      for (var band = 0; band < bands; band++) {
        final byte = (qb[k + band ~/ 4] >>> ((band % 4) * 8)) & 255;
        var j = index.heads[band * 256 + byte] - 1;
        for (; j >= 0; j = index.next[j * bands + band] - 1) {
          if (visited[j] == stamp) continue;
          visited[j] = stamp;
          final tb = targets[j].bits;
          final v = _pop(a ^ tb[0]) +
              _pop(b ^ tb[1]) +
              _pop(c ^ tb[2]) +
              _pop(d ^ tb[3]);
          if (v < distances[j]) distances[j] = v;
          if (v < minDistance) {
            minDistance = v;
            best = j;
          }
        }
      }
    }
    if (minDistance > 38) continue;
    final p = targets[best];
    var distinct = true;
    for (var j = 0; j < targets.length; j++) {
      if (distances[j] * .86 > minDistance) continue;
      final dx = p.x - targets[j].x, dy = p.y - targets[j].y;
      if (dx * dx + dy * dy > .028 * .028) {
        distinct = false;
        break;
      }
    }
    if (distinct && minDistance < (unique[best]?.distance ?? 129)) {
      unique[best] = _Pair(p, q, minDistance);
    }
  }
  return unique.values.toList()..sort((a, b) => a.distance - b.distance);
}

class _Evidence {
  final double agreement;
  final double overlap;
  final double conflict;
  final bool losesHighlights;
  final bool isMatch;
  final Float64List? projection;
  _Evidence(
    this.agreement,
    this.overlap,
    this.conflict,
    this.losesHighlights,
    this.isMatch,
    this.projection,
  );
}

_Evidence? _compare(_Card scan, _Card old, {bool recoverGlare = false}) {
  final pairs = _correspondences(scan, old);
  if (pairs.length < 10) return null;
  final random = math.Random(0);
  var inliers = <_Pair>[];
  for (var i = 0; i < 360; i++) {
    // Prefer better descriptor matches first, then sample the whole pool.
    final n = math.min(pairs.length, 14 + i ~/ 4);
    final sample = <int>{};
    while (sample.length < 4) {
      sample.add(random.nextInt(n));
    }
    final fit = _fit(sample.map((j) => pairs[j]));
    if (fit == null) continue;
    final support = pairs.where((p) => _fits(fit, p)).toList();
    if (support.length > inliers.length) {
      inliers = support;
      if (inliers.length >= pairs.length * .75) break;
    }
  }
  if (inliers.length < 10 || inliers.length * 4 < pairs.length) return null;
  final fit = _fit(inliers);
  if (fit == null) return null;
  var canProject = false;
  if (recoverGlare &&
      inliers.length >= 24 &&
      inliers.length >= pairs.length * .4) {
    final xs = inliers.map((p) => p.scan.x);
    final ys = inliers.map((p) => p.scan.y);
    // An accepted patch fit is not necessarily a reliable full-frame fit.
    canProject = xs.reduce(math.max) - xs.reduce(math.min) >=
            .75 * scan.raster.w / _side &&
        ys.reduce(math.max) - ys.reduce(math.min) >=
            .75 * scan.raster.h / _side &&
        inliers.where((p) => _fits(fit, p, tolerance: .006)).length >=
            inliers.length * .75;
  }
  return _verifyPixels(scan.raster, old.raster, fit, canProject: canProject);
}

// Least-squares homography from rectified card to the legacy image. Fix the
// final homogeneous coefficient at 1 (the center of the candidate card).
Float64List? _fit(Iterable<_Pair> pairs) {
  final m = List.generate(8, (_) => Float64List(9));
  void add(List<double> row, double value) {
    for (var i = 0; i < 8; i++) {
      for (var j = i; j < 8; j++) {
        m[i][j] += row[i] * row[j];
      }
      m[i][8] += row[i] * value;
    }
  }

  for (final p in pairs) {
    final x = p.scan.x, y = p.scan.y, u = p.old.x, v = p.old.y;
    add([x, y, 1, 0, 0, 0, -x * u, -y * u], u);
    add([0, 0, 0, x, y, 1, -x * v, -y * v], v);
  }
  for (var i = 1; i < 8; i++) {
    for (var j = 0; j < i; j++) {
      m[i][j] = m[j][i];
    }
  }
  for (var col = 0; col < 8; col++) {
    var pivot = col;
    for (var r = col + 1; r < 8; r++) {
      if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
    }
    final row = m[pivot];
    if (row[col].abs() < 1e-9) return null;
    m[pivot] = m[col];
    m[col] = row;
    final d = row[col];
    for (var j = col; j <= 8; j++) {
      row[j] /= d;
    }
    for (var r = 0; r < 8; r++) {
      if (r == col) continue;
      final factor = m[r][col];
      for (var j = col; j <= 8; j++) {
        m[r][j] -= factor * row[j];
      }
    }
  }
  return Float64List.fromList([for (final row in m) row[8]]);
}

bool _fits(Float64List h, _Pair p, {double tolerance = .011}) {
  final x = p.scan.x, y = p.scan.y;
  final d = h[6] * x + h[7] * y + 1;
  final dx = (h[0] * x + h[1] * y + h[2]) / d - p.old.x;
  final dy = (h[3] * x + h[4] * y + h[5]) / d - p.old.y;
  return dx * dx + dy * dy < tolerance * tolerance;
}

_Evidence? _verifyPixels(
  _Raster scan,
  _Raster old,
  Float64List h, {
  required bool canProject,
}) {
  // Reject mirrors, collapse and transforms with poles through the card.
  final area = (h[0] - h[2] * h[6]) * (h[4] - h[5] * h[7]) -
      (h[1] - h[2] * h[7]) * (h[3] - h[5] * h[6]);
  final slope = (h[6].abs() * scan.w + h[7].abs() * scan.h) / (2 * _side);
  if (area < .035 || area > 5 || slope > .7) return null;

  // Local contrast-normalized agreement on disjoint tiles, not just the
  // matched corners. A name/date or similar silhouette alone cannot supply
  // agreement through the interior of the photograph.
  const cols = 7, rows = 9, samples = 9;
  var good = 0, visible = 0, interior = 0;
  var regions = 0, covered = 0;
  var comparable = 0, conflicting = 0;
  final highlightLoss = Uint8List(rows * cols);
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      var a = 0.0, b = 0.0, aa = 0.0, bb = 0.0, ab = 0.0;
      var n = 0, newBright = 0;
      for (var dy = 0; dy < samples; dy++) {
        final y = (row + (dy + .5) / samples) * (scan.h - 1) / rows;
        final v = (y - scan.h / 2) / _side;
        for (var dx = 0; dx < samples; dx++) {
          final x = (col + (dx + .5) / samples) * (scan.w - 1) / cols;
          final u = (x - scan.w / 2) / _side;
          final d = h[6] * u + h[7] * v + 1;
          final ox = (h[0] * u + h[1] * v + h[2]) / d * _side + old.w / 2;
          final oy = (h[3] * u + h[4] * v + h[5]) / d * _side + old.h / 2;
          if (ox < 0 || ox >= old.w - 1 || oy < 0 || oy >= old.h - 1) {
            continue;
          }
          final s = scan.sample(x, y), t = old.sample(ox, oy);
          if (s >= 215 && s - t >= 34) newBright++;
          a += s;
          b += t;
          aa += s * s;
          bb += t * t;
          ab += s * t;
          n++;
        }
      }
      if (n < 62) continue;
      covered++;
      final varA = aa - a * a / n, varB = bb - b * b / n;
      final inner = row > 0 && row < rows - 1 && col > 0 && col < cols - 1;
      // A diffuse reflection need not reach white. Compared at corresponding
      // pixels, it both lifts a substantial area and flattens existing detail.
      // A thin bright signature or a lift that retains contrast does neither.
      if (inner && newBright * 2 >= n && varB >= n * 144 && varA < varB * .28) {
        highlightLoss[row * cols + col] = 1;
        continue;
      }
      if (varA < n * 100) continue;
      visible++;
      if (varB < n * 49) continue;
      final corr = (ab - a * b / n) / math.sqrt(varA * varB);
      if (inner) {
        comparable++;
        if (corr < .45) conflicting++;
      }
      if (corr < .74) continue;
      good++;
      if (inner) {
        interior++;
        regions |= 1 << ((row * 3 ~/ rows) * 2 + col * 2 ~/ cols);
      }
    }
  }
  final agreement = visible == 0 ? 0.0 : good / visible;
  final isMatch =
      good >= 15 && interior >= 9 && _pop(regions) >= 4 && agreement >= .51;
  if (!isMatch && !canProject) return null;
  final overlap = covered / (cols * rows);
  // A tiny crop can cover itself fully but only part of the other view.
  // Measure mutual coverage before comparing the quality of duplicate views.
  final halfW = scan.w / (2 * _side), halfH = scan.h / (2 * _side);
  final projected = [
    for (final (x, y) in [
      (-halfW, -halfH),
      (halfW, -halfH),
      (halfW, halfH),
      (-halfW, halfH),
    ])
      (
        (h[0] * x + h[1] * y + h[2]) / (1 + h[6] * x + h[7] * y),
        (h[3] * x + h[4] * y + h[5]) / (1 + h[6] * x + h[7] * y),
      ),
  ];
  var twiceArea = 0.0;
  for (var i = 0; i < projected.length; i++) {
    final (x, y) = projected[i];
    final (nx, ny) = projected[(i + 1) % projected.length];
    twiceArea += x * ny - y * nx;
  }
  final oldArea = old.w * old.h / (_side * _side);
  // At least three side-connected interior tiles: a contiguous loss of
  // detail, not one local tone/registration discrepancy.
  var losesHighlights = false;
  for (var i = cols + 1; i < (rows - 1) * cols - 1; i++) {
    if (highlightLoss[i] == 1 &&
        highlightLoss[i - 1] +
                highlightLoss[i + 1] +
                highlightLoss[i - cols] +
                highlightLoss[i + cols] >=
            2) {
      losesHighlights = true;
      break;
    }
  }
  // Glare can remove a region of dense agreement. To use the geometry
  // without accepting the rescan pixels, require tighter feature support
  // above and stronger agreement throughout the remaining visible content.
  final projection = canProject &&
          losesHighlights &&
          good >= 21 &&
          interior >= 11 &&
          _pop(regions) >= 3 &&
          agreement >= .67
      ? h
      : null;
  if (!isMatch && projection == null) return null;
  return _Evidence(
    agreement,
    overlap * math.min(1, twiceArea / (2 * oldArea)),
    conflicting / comparable,
    losesHighlights,
    isMatch,
    projection,
  );
}

Uint8List? _reproject(
  img.Image original,
  _Raster old,
  _Card scan,
  Float64List transform,
) {
  ({double x, double y}) sourcePoint(double u, double v) {
    final x = (u - .5) * scan.raster.w / _side;
    final y = (v - .5) * scan.raster.h / _side;
    final d = 1 + transform[6] * x + transform[7] * y;
    return (
      x: ((transform[0] * x + transform[1] * y + transform[2]) / d * _side +
              old.w / 2) *
          original.width /
          old.w,
      y: ((transform[3] * x + transform[4] * y + transform[5]) / d * _side +
              old.h / 2) *
          original.height /
          old.h,
    );
  }

  double span(({double x, double y}) a, ({double x, double y}) b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
  final tl = sourcePoint(0, 0), tr = sourcePoint(1, 0);
  final bl = sourcePoint(0, 1), br = sourcePoint(1, 1);
  final size = scan.sourceSize;
  // The reference sets aspect, not resolution. Use the smaller opposing
  // spans so stretching the legacy frame cannot invent output detail.
  final scale = math.min(
    math.min(span(tl, tr), span(bl, br)) / size.width,
    math.min(span(tl, bl), span(tr, br)) / size.height,
  );
  final w = (size.width * scale).floor(), h = (size.height * scale).floor();
  if (w < 2 || h < 2) return null;
  final output = img.Image(width: w, height: h, numChannels: 4);
  var covered = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = sourcePoint((x + .5) / w, (y + .5) / h);
      if (p.x < 0 ||
          p.y < 0 ||
          p.x > original.width - 1 ||
          p.y > original.height - 1) {
        continue;
      }
      final color = original.getPixelInterpolate(p.x, p.y,
          interpolation: img.Interpolation.linear);
      if (color.aNormalized < 1) continue;
      output.setPixelRgba(x, y, color.rNormalized * 255,
          color.gNormalized * 255, color.bNormalized * 255, 255);
      covered++;
    }
  }
  if (covered < .97 * w * h) return null;
  return img.encodePng(output);
}
