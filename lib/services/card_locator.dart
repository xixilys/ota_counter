import 'dart:math' as math;
import 'dart:typed_data';

import 'card_edge_fit.dart';

/// One whole card found by [CardLocator.locate].
class LocatedCard {
  LocatedCard({
    required this.quad,
    required this.seedIndex,
    required this.complete,
    required this.format,
    required this.score,
    required this.edges,
    required this.windows,
    required this.bands,
  });

  /// TL, TR, BR, BL in source pixels.
  final List<Pt> quad;

  /// Index of the proposal this card grew from; null when an enclosed photo
  /// window seeded it (a card the scanner missed).
  final int? seedIndex;

  /// All four paper margins and almost every window edge carry evidence.
  final bool complete;
  final String format;
  final double score;

  /// Per side (left, top, right, bottom of the fit frame): outer paper-edge
  /// support, photo-window edge support, and paper share of the margin band.
  final List<double> edges, windows, bands;
}

/// Finds whole cards around the scanner's proposals.
///
/// A proposal is only a seed: it may cover half a card, two cards, or a card
/// plus the table. Each seed is refit, in a frame rectified on the seed, to
/// an Instax mini or wide card: outer paper edges, the photo window inside at
/// the film's margins, and paper filling every margin band. Hypotheses that
/// reach past their card (an outer edge inside a margin band) or span two
/// cards (a card edge across the window) are penalised. Complete fits win
/// over overlapping weaker ones; enclosed photo windows seed cards the
/// scanner missed. A port of `locate_cards` / `fit_card` in the desktop
/// pipeline (~/.ota-counter/cheki_pipeline.py).
class CardLocator {
  CardLocator._();

  static final List<double> _shears =
      List.generate(9, (i) => -0.16 + 0.32 * i / 8);

  // Outer W x H, side margin, top margin, window height (mm), upright layout.
  static const _formats = {
    'mini': (54.0, 86.0, 4.0, 6.5, 62.0),
    'wide': (108.0, 86.0, 4.5, 7.0, 62.0),
  };

  static List<LocatedCard> locate(
      PaperSignalImage signal, List<List<Pt>> proposals) {
    if (proposals.isEmpty) return const [];
    final sizes = [for (final q in proposals) math.sqrt(_area(q).abs())]
      ..sort();
    final mid = sizes.length ~/ 2;
    final sizeHint =
        sizes.length.isOdd ? sizes[mid] : (sizes[mid - 1] + sizes[mid]) / 2;
    final fits = <_Fit>[];
    for (var i = 0; i < proposals.length; i++) {
      final fit = _fitCard(signal, proposals[i]);
      if (fit != null) fits.add(fit..seed = i);
    }
    for (final seed in windowSeeds(signal, sizeHint)) {
      final c = _centre(seed);
      if (fits.any((f) => f.complete && _inside(f.quad, c))) continue;
      final fit = _fitCard(signal, seed);
      if (fit != null && fit.complete) fits.add(fit);
    }
    fits.sort((a, b) => a.complete != b.complete
        ? (a.complete ? -1 : 1)
        : b.score.compareTo(a.score));
    final kept = <_Fit>[];
    for (final fit in fits) {
      final inFrame = fit.quad.every((p) =>
          p.x >= -2 &&
          p.y >= -2 &&
          p.x <= signal.width + 1 &&
          p.y <= signal.height + 1);
      if (!inFrame || !_convex(fit.quad)) {
        fit.complete = false;
        // A card found only by its window that runs off the photo is a
        // partial card; there is no proposal to fall back on.
        if (fit.seed == null) continue;
      }
      if (kept.any((k) => _overlapOfSmaller(fit.quad, k.quad) > 0.35)) {
        continue;
      }
      // No photo window at all is not a card (a mouse, a keyboard key).
      if (!fit.complete && fit.windows.where((w) => w >= 0.4).length < 2) {
        continue;
      }
      kept.add(fit);
    }
    // Number cards in the scanner's order. A card may have been fitted from
    // another seed (a photo window, or a neighbour's proposal) than the
    // proposal that covers it; it still takes that proposal's place, so the
    // numbering does not depend on which seed won.
    int place(_Fit fit) {
      var best = fit.seed ?? proposals.length;
      for (var i = 0; i < proposals.length && i < best; i++) {
        if (_inside(fit.quad, _centre(proposals[i]))) best = i;
      }
      return best;
    }

    final places = {for (final fit in kept) fit: place(fit)};
    final order = [for (var i = 0; i < kept.length; i++) i]..sort((a, b) {
        final c = places[kept[a]]!.compareTo(places[kept[b]]!);
        return c != 0 ? c : a.compareTo(b);
      });
    final sorted = [for (final i in order) kept[i]];
    kept
      ..clear()
      ..addAll(sorted);
    return [
      for (final fit in kept)
        LocatedCard(
          quad: !fit.complete && fit.seed != null
              ? proposals[fit.seed!]
              : _orderQuad([
                  for (final p in fit.quad)
                    math.Point(p.x.clamp(0.0, signal.width - 1.0),
                        p.y.clamp(0.0, signal.height - 1.0)),
                ]),
          seedIndex: fit.seed,
          complete: fit.complete,
          format: fit.format,
          score: fit.score,
          edges: fit.edges,
          windows: fit.windows,
          bands: fit.bands,
        ),
    ];
  }

  // ---------------------------------------------------------------- fitting

  /// Global fit, then refits in the frame of the previous fit, once free
  /// and once keeping the film and layout of the global search; the result
  /// that reads best as a whole card ([verifyQuad]) wins.
  static _Fit? _fitCard(PaperSignalImage signal, List<Pt> seed) {
    final first =
        _fitOnce(signal, seed, expand: 0.65, w0: 0.3, w1: 2.4, step: 3);
    final results = <_Fit>[
      if (first != null) ...[
        first,
        ...[
          _refine(signal, first.quad, null, 3),
          _refine(signal, first.quad, (first.format, first.turns), 3),
        ].whereType<_Fit>(),
      ],
    ];
    // A seed that already reads as a whole card is refit locally in its own
    // layout too, so the global search can never end worse than its seed
    // (bright print inside the window can outscore a card in a sleeve).
    final seedRead = verifyQuad(signal, seed);
    if (seedRead.$1 >= 0.4 && seedRead.$3 != null) {
      final local = _refine(signal, seed, (seedRead.$3!, seedRead.$4), 4);
      if (local != null) results.add(local);
    }
    if (results.isEmpty) return null;
    for (final r in results) {
      r.verify = verifyQuad(signal, r.quad);
    }
    // Prefer a fit whose four window edges all show; then the layout score.
    var best = results.first;
    for (final r in results.skip(1)) {
      final a = (r.verify.$1 >= 0.4, r.verify.$2);
      final b = (best.verify.$1 >= 0.4, best.verify.$2);
      if (a.$1 != b.$1 ? a.$1 : a.$2 > b.$2) best = r;
    }
    best.complete = _complete(best);
    return best;
  }

  /// Up to passes - 1 local refits from [quad]; null if none succeeded.
  static _Fit? _refine(
      PaperSignalImage signal, List<Pt> quad, (String, int)? keep, int passes) {
    _Fit? res;
    var current = quad;
    for (var pass = 1; pass < passes; pass++) {
      final next = _fitOnce(signal, current,
          expand: 0.35, w0: 0.85, w1: 1.15, step: 1, keep: keep);
      if (next == null) break;
      var moved = 0.0;
      for (var i = 0; i < 4; i++) {
        moved = math.max(moved, (next.quad[i].x - current[i].x).abs());
        moved = math.max(moved, (next.quad[i].y - current[i].y).abs());
      }
      res = next;
      current = next.quad;
      if (moved < 0.01 * current[2].distanceTo(current[0])) break;
    }
    return res;
  }

  /// Physical side lengths (up to scale) of [quad] on a tilted table.
  ///
  /// Pixel lengths carry the camera's foreshortening (a card far up the
  /// table looks squat), so film ratios are only compared after removing it
  /// with the phone-camera prior the format meter uses.
  static (double, double) metricAxes(List<Pt> quad, int width, int height,
      {bool trustLimit = true}) {
    final h = _unitToQuad(quad);
    final focal = 0.8 * math.max(width, height);
    final cx = width / 2, cy = height / 2;
    double norm(double a, double d, double g) {
      final x = (a - cx * g) / focal, y = (d - cy * g) / focal;
      return math.sqrt(x * x + y * y + g * g);
    }

    final mx = norm(h[0], h[3], h[6]), my = norm(h[1], h[4], h[7]);
    final px = (quad[1].distanceTo(quad[0]) + quad[2].distanceTo(quad[3])) / 2;
    final py = (quad[3].distanceTo(quad[0]) + quad[2].distanceTo(quad[1])) / 2;
    // The prior only knows the camera roughly; on a quad whose sides are far
    // from parallel (a bad fit) it extrapolates wildly. Foreshortening on a
    // table photo stays within about 25 %, so a larger correction is not
    // trusted and the pixel aspect stands.
    final correction = (mx / my) / (px / py);
    if (trustLimit && !(correction >= 0.8 && correction <= 1.25)) {
      return (px, py);
    }
    return (mx, my);
  }

  static _Fit? _fitOnce(PaperSignalImage signal, List<Pt> seed,
      {required double expand,
      required double w0,
      required double w1,
      required int step,
      (String, int)? keep}) {
    const longPx = 240.0, topk = 6;
    if (seed[1].distanceTo(seed[0]) < 4 || seed[3].distanceTo(seed[0]) < 4) {
      return null;
    }
    // The fitting frame is a metric rectification of the seed: its aspect
    // is the seed's physical aspect, so film ratios hold inside it.
    final (ws, hs) = metricAxes(seed, signal.width, signal.height);
    if (!(ws > 0 && hs > 0)) return null;
    final scale = longPx / math.max(ws, hs);
    final fw = ws * scale, fh = hs * scale;
    final m = expand * math.max(fw, fh);
    final wf = (fw + 2 * m).round(), hf = (fh + 2 * m).round();
    // frame (u, v) -> unit square of the seed -> source
    final h = _unitToQuad(seed);
    final s = Float32List(wf * hf);
    for (var v = 0; v < hf; v++) {
      for (var u = 0; u < wf; u++) {
        final p = _apply(h, (u - m) / fw, (v - m) / fh);
        s[v * wf + u] = (p.x < 0 ||
                p.y < 0 ||
                p.x > signal.width - 1 ||
                p.y > signal.height - 1)
            ? 0
            : signal.sample(p.x, p.y);
      }
    }
    final frame = _Frame(s, wf, hf);
    final cx = m + fw / 2, cy = m + fh / 2;
    var extent = [m, m, m + fw, m + fh];
    _Candidate? best;
    late _Profiles prof;
    for (var it = 0; it < 4; it++) {
      final previous = best;
      final previousProf = it > 0 ? prof : null;
      prof = _Profiles(frame, extent);
      best = null;
      for (final entry in _formats.entries) {
        final (W, H, side, top, winH) = entry.value;
        final upright = [side, top, side, H - winH - top]; // l, t, r, b
        for (var turns = 0; turns < 4; turns++) {
          // Refinement passes keep the film and layout the global search
          // chose; they only re-seat the edges.
          if (keep != null && (entry.key, turns) != keep) continue;
          final odd = turns.isOdd;
          final ow = odd ? H : W, oh = odd ? W : H;
          final mfrac = [
            for (var k = 0; k < 4; k++)
              upright[(k - turns) % 4] / (k.isEven ? ow : oh)
          ];
          for (final kasp in const [0.95, 1.0, 1.05]) {
            final a = ow / oh * kasp;
            // The global search tries any width; a refinement (w0 around 1)
            // re-seats a card the seed already spans, near the seed's width.
            final local = w0 >= 0.5;
            final wStart = (w0 * (local ? fw : math.min(fw, fh))).toInt();
            final wEnd = math
                .min(wf - 2.0, w1 * (local ? fw : math.max(fw, fh)))
                .toInt();
            for (var wd = wStart; wd < wEnd; wd += step) {
              final ht = wd / a;
              if (ht > hf - 2 || ht < 0.3 * math.min(fw, fh)) continue;
              final c = _bestAtWidth(
                  frame, prof, wd, ht, mfrac, cx, cy, topk, math.max(fw, fh));
              if (c == null) continue;
              if (best == null || c.score > best.score) {
                best = c
                  ..format = entry.key
                  ..turns = turns;
              }
            }
          }
        }
      }
      if (best == null) {
        if (previous == null) return null;
        best = previous;
        prof = previousProf!;
        break;
      }
      final next = [
        best.l.toDouble(),
        best.t.toDouble(),
        best.r.toDouble(),
        best.b.toDouble()
      ];
      final stable = it > 0 &&
          [for (var k = 0; k < 4; k++) (next[k] - extent[k]).abs() <= 2]
              .every((x) => x);
      if (stable) break;
      extent = next;
    }
    final c = best!;
    final pos = [c.l, c.t, c.r, c.b];
    final edges = c.edges;
    // A side hidden under another card has no paper step of its own; place
    // it from its own window edge and the film's margin instead.
    final win = [c.wl, c.wt, c.wr, c.wb];
    final dims = [
      pos[2] - pos[0],
      pos[3] - pos[1],
      pos[2] - pos[0],
      pos[3] - pos[1],
    ];
    final shearOverride = <int, double>{};
    for (var side = 0; side < 4; side++) {
      // A side with no paper step of its own has no direction either: take
      // it from its window edge, else from the opposite (parallel) side.
      if (edges[side] >= 0.5) continue;
      final opposite = (side + 2) % 4;
      if (c.windows[side] >= 0.4) {
        shearOverride[side] = prof.windowShear(side, win[side]);
      } else if (edges[opposite] >= 0.5) {
        shearOverride[side] = prof.outerShear(opposite, pos[opposite]);
      }
    }
    for (var side = 0; side < 4; side++) {
      if (edges[side] >= 0.5 || c.windows[side] < 0.6) continue;
      final raw = prof.windowRaw(side);
      final lo = math.max(0, win[side] - 6);
      final hi = math.min(raw.length, win[side] + 7);
      var at = lo;
      for (var i = lo; i < hi; i++) {
        if (raw[i] > raw[at]) at = i;
      }
      final sign = side < 2 ? -1 : 1;
      final placed = (at + sign * c.mfrac[side] * dims[side]).round();
      // Only pull a hidden side in off the neighbour, by a few percent.
      final inward = (placed - pos[side]) * -sign;
      if (inward > 0 && inward <= 0.04 * dims[side]) {
        pos[side] = placed;
        shearOverride[side] = prof.windowShear(side, at);
      }
    }
    final l = pos[0].clamp(0, wf - 1), t = pos[1].clamp(0, hf - 1);
    final r = pos[2].clamp(0, wf - 1), b = pos[3].clamp(0, hf - 1);
    final sl = shearOverride[0] ?? prof.outerShear(0, l);
    final st = shearOverride[1] ?? prof.outerShear(1, t);
    final sr = shearOverride[2] ?? prof.outerShear(2, r);
    final sb = shearOverride[3] ?? prof.outerShear(3, b);
    final xc = prof.xc, yc = prof.yc;
    Pt corner(double px, double sx, double py, double sy) {
      final x = (px + sx * (py - sy * xc - yc)) / (1 - sx * sy);
      return math.Point(x, py + sy * (x - xc));
    }

    final frameQuad = [
      corner(l.toDouble(), sl, t.toDouble(), st),
      corner(r.toDouble(), sr, t.toDouble(), st),
      corner(r.toDouble(), sr, b.toDouble(), sb),
      corner(l.toDouble(), sl, b.toDouble(), sb),
    ];
    final quad = [
      for (final p in frameQuad) _apply(h, (p.x - m) / fw, (p.y - m) / fh)
    ];
    final fit =
        _Fit(quad, c.format, c.turns, c.score, edges, c.windows, c.bands);
    return fit;
  }

  static _Candidate? _bestAtWidth(_Frame frame, _Profiles p, int wd, double ht,
      List<double> mfrac, double cx, double cy, int topk, double longSide) {
    final wf = frame.width, hf = frame.height;
    final ls = <int>[];
    for (var l = 0; l < wf - wd - 1; l++) {
      if (l < cx && l + wd > cx) ls.add(l);
    }
    final ts = <int>[];
    for (var t = 0; t < (hf - ht - 1).toInt(); t++) {
      if (t < cy && t + ht > cy) ts.add(t);
    }
    if (ls.isEmpty || ts.isEmpty) return null;
    final fx = Float64List(ls.length);
    final il = Int32List(ls.length), ir = Int32List(ls.length);
    for (var i = 0; i < ls.length; i++) {
      final l = ls[i], r = l + wd;
      il[i] = (l + mfrac[0] * wd).round();
      ir[i] = (r - mfrac[2] * wd).round();
      fx[i] = p.outer[0][l] +
          p.outer[2][r] +
          0.7 * (p.window[0][il[i]] + p.window[2][ir[i]]);
    }
    final fy = Float64List(ts.length);
    final b = Int32List(ts.length);
    final it = Int32List(ts.length), ib = Int32List(ts.length);
    for (var j = 0; j < ts.length; j++) {
      final t = ts[j];
      b[j] = (t + ht).round();
      it[j] = (t + mfrac[1] * ht).round();
      ib[j] = (b[j] - mfrac[3] * ht).round();
      fy[j] = p.outer[1][t] +
          p.outer[3][b[j]] +
          0.7 * (p.window[1][it[j]] + p.window[3][ib[j]]);
    }
    final span = (2.4 * longSide).toInt();
    _Candidate? best;
    for (final i in _topK(fx, topk)) {
      for (final j in _topK(fy, topk)) {
        final l = ls[i], r = l + wd, t = ts[j], bb = b[j];
        final wl = il[i], wr = ir[i], wt = it[j], wb = ib[j];
        if (wr - wl < 4 || wb - wt < 4) continue;
        final bands = [
          frame.box(l, wt, wl, wb) / math.max((wl - l) * (wb - wt), 1),
          frame.box(wl, t, wr, wt) / math.max((wr - wl) * (wt - t), 1),
          frame.box(wr, wt, r, wb) / math.max((r - wr) * (wb - wt), 1),
          frame.box(wl, wb, wr, bb) / math.max((wr - wl) * (bb - wb), 1),
        ];
        final edges = [
          p.outer[0][l],
          p.outer[1][t],
          p.outer[2][r],
          p.outer[3][bb]
        ];
        final windows = [
          p.window[0][wl],
          p.window[1][wt],
          p.window[2][wr],
          p.window[3][wb]
        ];
        // An outer edge inside a margin band: the fit reaches past its card.
        final inner = [
          _bandMax(p.outerMax[0], l + 7, wl - 7, 64),
          _bandMax(p.outerMax[1], t + 7, wt - 7, 64),
          _bandMax(p.outerMax[2], wr + 7, r - 7, 64),
          _bandMax(p.outerMax[3], wb + 7, bb - 7, 64),
        ];
        // A card edge across the window: two cards side by side.
        final across = [
          _bandMax(p.outerMax[0], wl + 7, wr - 7, span),
          _bandMax(p.outerMax[2], wl + 7, wr - 7, span),
          _bandMax(p.outerMax[1], wt + 7, wb - 7, span),
          _bandMax(p.outerMax[3], wt + 7, wb - 7, span),
        ].reduce(math.max);
        final acrossPenalty = 0.5 * ((across - 0.5) / 0.4).clamp(0.0, 1.0);
        final q = [
          for (var k = 0; k < 4; k++)
            0.4 * edges[k] +
                0.25 * windows[k] +
                0.35 * bands[k] -
                0.5 * ((inner[k] - 0.5) / 0.4).clamp(0.0, 1.0) -
                acrossPenalty
        ];
        final score = q.reduce((a, b) => a + b) / 4 + 0.5 * q.reduce(math.min);
        if (best == null || score > best.score) {
          best = _Candidate(
              score, l, t, r, bb, wl, wt, wr, wb, edges, windows, bands, mfrac);
        }
      }
    }
    return best;
  }

  static const _verifySize = 360;

  /// How well [quad] rectified looks like a whole mini / wide card.
  ///
  /// The paper signal is rectified to a square preview and the four
  /// photo-window edges are read at every inset; each film layout is scored
  /// on window edges at its margins and on outer and window ratios. Returns
  /// (weakest window edge, score, film, turns) of the best layout.
  static (double, double, String?, int) verifyQuad(
      PaperSignalImage signal, List<Pt> quad) {
    const size = _verifySize;
    final h = _unitToQuad(quad);
    final preview = Float64List(size * size);
    for (var i = 0; i < size; i++) {
      for (var j = 0; j < size; j++) {
        final p = _apply(h, j / (size - 1), i / (size - 1));
        preview[i * size + j] = signal.sample(p.x, p.y);
      }
    }
    final lo = (size * 0.018).round(), hi = (size * 0.25).round();
    final m0 = (size * 0.19).round(), m1 = (size * 0.81).round();
    final n = hi - lo;
    // Profile k reads inward from the top, right, bottom and left edge
    // (preview, preview.T[::-1], preview[::-1], preview.T in the desktop
    // pipeline).
    double at(int side, int row, int col) => switch (side) {
          0 => preview[row * size + col],
          1 => preview[col * size + (size - 1 - row)],
          2 => preview[(size - 1 - row) * size + col],
          _ => preview[col * size + row],
        };
    final profiles = List.generate(4, (_) => Float64List(n));
    for (var side = 0; side < 4; side++) {
      for (var k = 0; k < n; k++) {
        final o = lo + k;
        var sum = 0.0;
        for (var c = m0; c < m1; c++) {
          final paper = at(side, o - 4, c), printed = at(side, o + 4, c);
          sum += ((paper - printed - 5) / 35).clamp(0.0, 1.0) *
              ((paper - 110) / 85).clamp(0.0, 1.0);
        }
        profiles[side][k] = sum / (m1 - m0);
      }
    }
    final (ax, ay) = metricAxes(quad, signal.width, signal.height);
    final axes = [ax, ay];
    (double, double, String?, int) best =
        (-1.0, double.negativeInfinity, null, 0);
    for (final MapEntry(key: fmt, value: (W, H, side, _, winH))
        in _formats.entries) {
      final printW = W - 2 * side;
      final xGap = (1 - printW / W) / 2;
      final yGap = 1 - winH / H;
      final standard = [xGap, xGap, yGap - xGap, xGap];
      for (var turns = 0; turns < 4; turns++) {
        final margins = <double>[], strengths = <double>[];
        var fitSum = 0.0;
        for (var s = 0; s < 4; s++) {
          final expected = standard[(s - turns) % 4];
          var bi = 0, bv = double.negativeInfinity;
          for (var k = 0; k < n; k++) {
            final off = (lo + k) / (size - 1);
            final d = (off - expected).abs() / 0.05;
            final v = profiles[s][k] - 0.48 * d * d;
            if (v > bv) {
              bv = v;
              bi = k;
            }
          }
          margins.add((lo + bi) / (size - 1));
          strengths.add(profiles[s][bi]);
          fitSum += bv;
        }
        // margins are top, right, bottom, left (the profile order above).
        final window = [
          axes[0] * (1 - margins[1] - margins[3]),
          axes[1] * (1 - margins[0] - margins[2]),
        ];
        final outer = axes[turns % 2] / axes[1 - turns % 2];
        final inner = window[turns % 2] / window[1 - turns % 2];
        final error = (math.log(outer / (W / H))).abs() +
            (math.log(inner / (printW / winH))).abs();
        final score = fitSum / 4 - 1.4 * error;
        if (score > best.$2) {
          best = (strengths.reduce(math.min), score, fmt, turns);
        }
      }
    }
    return best;
  }

  /// Every paper margin and almost every window edge carries evidence, and
  /// the rectified fit reads as a whole card ([verifyQuad]). A fit that
  /// fails keeps the scanner's proposal and is flagged for review instead
  /// of cutting into the card.
  static bool _complete(_Fit f) =>
      f.edges.where((e) => e >= 0.5).length >= 3 &&
      f.edges.reduce(math.min) >= 0.25 &&
      f.windows.where((w) => w >= 0.4).length >= 3 &&
      f.bands.reduce(math.min) >= 0.45 &&
      f.verify.$1 >= 0.4;

  /// max(profile[start : min(stop, start + span)]) with indices clamped to
  /// the profile, 0 for an empty range (numpy's take + where in the desktop
  /// pipeline).
  static double _bandMax(_RangeMax profile, int start, int stop, int span) {
    final end = math.min(stop, start + span);
    if (end <= start) return 0;
    final n = profile.length;
    final v = profile.max(start.clamp(0, n - 1), (end - 1).clamp(0, n - 1));
    return v > 0 ? v : 0;
  }

  /// Indices of the k largest values (ties keep the later index, as argsort).
  static List<int> _topK(Float64List values, int k) {
    // Ascending by value (index breaks ties), as the tail of an argsort.
    final top = <int>[];
    bool less(int a, int b) =>
        values[a] < values[b] || (values[a] == values[b] && a < b);
    for (var i = 0; i < values.length; i++) {
      if (top.length == k && !less(top[0], i)) continue;
      if (top.length == k) top.removeAt(0);
      var at = top.length;
      while (at > 0 && less(i, top[at - 1])) {
        at--;
      }
      top.insert(at, i);
    }
    return top;
  }

  // ------------------------------------------------------------ window seeds

  /// Photo windows are non-paper holes enclosed by a white paper border.
  /// They seed cards the scanner missed; pen strokes are closed over first.
  static List<List<Pt>> windowSeeds(PaperSignalImage signal, double? sizeHint) {
    final scale = 1600 / math.max(signal.width, signal.height);
    final w = (signal.width * scale).round(),
        h = (signal.height * scale).round();
    final paper = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      final y0 = (y / scale).floor(),
          y1 = math.max(y0 + 1, ((y + 1) / scale).floor());
      for (var x = 0; x < w; x++) {
        final x0 = (x / scale).floor(),
            x1 = math.max(x0 + 1, ((x + 1) / scale).floor());
        var sum = 0.0, n = 0;
        for (var yy = y0; yy < y1 && yy < signal.height; yy++) {
          final row = yy * signal.width;
          for (var xx = x0; xx < x1 && xx < signal.width; xx++) {
            sum += signal.data[row + xx];
            n++;
          }
        }
        paper[y * w + x] = n > 0 && sum / n > 140 ? 1 : 0;
      }
    }
    final closed = _erode(_dilate(paper, w, h), w, h);
    // 4-connected components of non-paper that do not touch the border.
    final label = Int32List(w * h)..fillRange(0, w * h, -1);
    final seeds = <List<Pt>>[];
    final stack = <int>[];
    for (var start = 0; start < w * h; start++) {
      if (closed[start] == 1 || label[start] >= 0) continue;
      label[start] = start;
      stack
        ..clear()
        ..add(start);
      var area = 0;
      var touches = false;
      var minX = w, minY = h, maxX = 0, maxY = 0;
      final boundary = <Pt>[];
      while (stack.isNotEmpty) {
        final idx = stack.removeLast();
        area++;
        final x = idx % w, y = idx ~/ w;
        if (x == 0 || y == 0 || x == w - 1 || y == h - 1) touches = true;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
        var edge = false;
        for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final n = ny * w + nx;
          if (closed[n] == 1) {
            edge = true;
          } else if (label[n] < 0) {
            label[n] = start;
            stack.add(n);
          }
        }
        if (edge) boundary.add(math.Point(x.toDouble(), y.toDouble()));
      }
      if (touches) continue;
      if (sizeHint != null) {
        final expected = math.pow(sizeHint * scale, 2) * 0.45;
        if (area < 0.2 * expected || area > 2.5 * expected) continue;
      } else if (area < 0.002 * w * h) {
        continue;
      }
      final rect = _minAreaRect(boundary);
      if (rect == null) continue;
      final (centre, rw, rh, ux, uy) = rect;
      if (math.min(rw, rh) < 12 ||
          area / (rw * rh) < 0.45 ||
          math.max(rw, rh) / math.min(rw, rh) > 2.2) {
        continue;
      }
      final hw = rw * 1.3 / 2, hh = rh * 1.3 / 2;
      final vx = -uy, vy = ux;
      seeds.add(_orderQuad([
        for (final (a, b) in const [(-1, -1), (1, -1), (1, 1), (-1, 1)])
          math.Point((centre.x + a * hw * ux + b * hh * vx) / scale,
              (centre.y + a * hw * uy + b * hh * vy) / scale),
      ]));
    }
    return seeds;
  }

  // 9x9 ellipse, as cv2.getStructuringElement(MORPH_ELLIPSE, (9, 9)).
  static final List<(int, int)> _ellipse = () {
    final out = <(int, int)>[];
    for (var dy = -4; dy <= 4; dy++) {
      final half = (4 * math.sqrt(math.max(0, (16 - dy * dy) / 16))).round();
      for (var dx = -half; dx <= half; dx++) {
        out.add((dx, dy));
      }
    }
    return out;
  }();

  static Uint8List _dilate(Uint8List src, int w, int h) =>
      _morph(src, w, h, dilate: true);
  static Uint8List _erode(Uint8List src, int w, int h) =>
      _morph(src, w, h, dilate: false);

  /// Binary dilation / erosion by [_ellipse]: each kernel row is a run of
  /// half-width hx, so a 1D run test per row (prefix sums) and an OR / AND
  /// over the kernel rows. Out-of-frame pixels are neutral (OpenCV default).
  static Uint8List _morph(Uint8List src, int w, int h, {required bool dilate}) {
    final target = dilate ? 1 : 0;
    // prefix[y][x]: count of `target` pixels in row y before x.
    final prefix = Int32List(h * (w + 1));
    for (var y = 0; y < h; y++) {
      var run = 0;
      for (var x = 0; x < w; x++) {
        prefix[y * (w + 1) + x] = run;
        if (src[y * w + x] == target) run++;
      }
      prefix[y * (w + 1) + w] = run;
    }
    final halves = <int, int>{};
    for (final (dx, dy) in _ellipse) {
      halves[dy] = math.max(halves[dy] ?? 0, dx);
    }
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var hit = false;
        for (final MapEntry(key: dy, value: hx) in halves.entries) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          final lo = math.max(0, x - hx), hi = math.min(w, x + hx + 1);
          final row = yy * (w + 1);
          if (prefix[row + hi] - prefix[row + lo] > 0) {
            hit = true;
            break;
          }
        }
        out[y * w + x] = hit ? target : 1 - target;
      }
    }
    return out;
  }

  /// Centre, side lengths along u and its normal, and the unit u.
  static (Pt, double, double, double, double)? _minAreaRect(List<Pt> points) {
    final hull = _convexHull(points);
    if (hull.length < 3) return null;
    (Pt, double, double, double, double)? best;
    var bestArea = double.infinity;
    for (var i = 0; i < hull.length; i++) {
      final a = hull[i], b = hull[(i + 1) % hull.length];
      final len = a.distanceTo(b);
      if (len == 0) continue;
      final ux = (b.x - a.x) / len, uy = (b.y - a.y) / len;
      var minU = double.infinity, maxU = -double.infinity;
      var minV = double.infinity, maxV = -double.infinity;
      for (final p in hull) {
        final pu = p.x * ux + p.y * uy, pv = -p.x * uy + p.y * ux;
        minU = math.min(minU, pu);
        maxU = math.max(maxU, pu);
        minV = math.min(minV, pv);
        maxV = math.max(maxV, pv);
      }
      final rw = maxU - minU, rh = maxV - minV;
      if (rw * rh < bestArea) {
        bestArea = rw * rh;
        final cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;
        best =
            (math.Point(cu * ux - cv * uy, cu * uy + cv * ux), rw, rh, ux, uy);
      }
    }
    return best;
  }

  static List<Pt> _convexHull(List<Pt> points) {
    final pts = [...points]
      ..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
    if (pts.length < 3) return pts;
    double cross(Pt o, Pt a, Pt b) =>
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    final lower = <Pt>[], upper = <Pt>[];
    for (final p in pts) {
      while (lower.length >= 2 &&
          cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    for (final p in pts.reversed) {
      while (upper.length >= 2 &&
          cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    return [...lower..removeLast(), ...upper..removeLast()];
  }

  // -------------------------------------------------------------- geometry

  /// Clockwise from the corner nearest the image's top-left.
  static List<Pt> _orderQuad(List<Pt> quad) {
    final c = _centre(quad);
    final sorted = [...quad]..sort((a, b) => math
        .atan2(a.y - c.y, a.x - c.x)
        .compareTo(math.atan2(b.y - c.y, b.x - c.x)));
    var start = 0;
    for (var i = 1; i < 4; i++) {
      if (sorted[i].x + sorted[i].y < sorted[start].x + sorted[start].y) {
        start = i;
      }
    }
    return [for (var i = 0; i < 4; i++) sorted[(start + i) % 4]];
  }

  static Pt _centre(List<Pt> q) => math.Point(
      q.map((p) => p.x).reduce((a, b) => a + b) / q.length,
      q.map((p) => p.y).reduce((a, b) => a + b) / q.length);

  static double _area(List<Pt> q) {
    var area = 0.0;
    for (var i = 0; i < q.length; i++) {
      final a = q[i], b = q[(i + 1) % q.length];
      area += a.x * b.y - b.x * a.y;
    }
    return area / 2;
  }

  static bool _convex(List<Pt> q) {
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
      final s =
          ((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)).sign.toInt();
      if (s == 0) return false;
      if (sign == 0) sign = s;
      if (s != sign) return false;
    }
    return true;
  }

  static bool _inside(List<Pt> q, Pt p) {
    var sign = 0;
    for (var i = 0; i < q.length; i++) {
      final a = q[i], b = q[(i + 1) % q.length];
      final s =
          ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)).sign.toInt();
      if (s == 0) continue;
      if (sign == 0) sign = s;
      if (s != sign) return false;
    }
    return true;
  }

  /// Intersection area over the smaller quad's area (both convex).
  static double _overlapOfSmaller(List<Pt> a, List<Pt> b) {
    var poly = _ccw(a);
    final clip = _ccw(b);
    for (var i = 0; i < clip.length && poly.isNotEmpty; i++) {
      final c0 = clip[i], c1 = clip[(i + 1) % clip.length];
      double side(Pt p) =>
          (c1.x - c0.x) * (p.y - c0.y) - (c1.y - c0.y) * (p.x - c0.x);
      final out = <Pt>[];
      for (var j = 0; j < poly.length; j++) {
        final p = poly[j], q = poly[(j + 1) % poly.length];
        final sp = side(p), sq = side(q);
        if (sp >= 0) out.add(p);
        if ((sp >= 0) != (sq >= 0)) {
          final t = sp / (sp - sq);
          out.add(math.Point(p.x + t * (q.x - p.x), p.y + t * (q.y - p.y)));
        }
      }
      poly = out;
    }
    final inter = poly.length < 3 ? 0.0 : _area(poly).abs();
    final small = math.min(_area(a).abs(), _area(b).abs());
    return inter / math.max(small, 1e-6);
  }

  static List<Pt> _ccw(List<Pt> q) => _area(q) >= 0 ? q : q.reversed.toList();

  /// Unit square (TL, TR, BR, BL) → [q]; handles points outside the square.
  static List<double> _unitToQuad(List<Pt> q) {
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

class _Fit {
  _Fit(this.quad, this.format, this.turns, this.score, this.edges, this.windows,
      this.bands);
  final List<Pt> quad;
  final String format;
  final int turns;
  (double, double, String?, int) verify =
      (-1, double.negativeInfinity, null, 0);
  final double score;
  final List<double> edges, windows, bands;
  bool complete = false;
  int? seed;
}

class _Candidate {
  _Candidate(this.score, this.l, this.t, this.r, this.b, this.wl, this.wt,
      this.wr, this.wb, this.edges, this.windows, this.bands, this.mfrac);
  final double score;
  final int l, t, r, b, wl, wt, wr, wb;
  final List<double> edges, windows, bands, mfrac;
  String format = 'mini';
  int turns = 0;
}

/// The paper signal resampled into a seed's rectified frame, with an
/// integral image of paper-ness for margin-band sums.
class _Frame {
  _Frame(this.data, this.width, this.height)
      : integral = Float64List((width + 1) * (height + 1)) {
    for (var y = 0; y < height; y++) {
      var row = 0.0;
      for (var x = 0; x < width; x++) {
        row += ((data[y * width + x] - 110) / 70).clamp(0.0, 1.0);
        integral[(y + 1) * (width + 1) + x + 1] =
            integral[y * (width + 1) + x + 1] + row;
      }
    }
  }
  final Float32List data;
  final int width, height;
  final Float64List integral;

  double box(int l, int t, int r, int b) {
    final w = width + 1;
    return integral[b * w + r] -
        integral[t * w + r] -
        integral[b * w + l] +
        integral[t * w + l];
  }
}

/// Per-side 1D edge evidence in a frame, max over a small set of shears.
///
/// outer[k]: paper on the card side of a line at each position (k = left,
/// top, right, bottom). A window edge has paper on the outside, which is the
/// opposite side's outer response; window[k] adds a few pixels of slack.
class _Profiles {
  _Profiles(_Frame f, List<double> extent) {
    const d = 2;
    final x0 = extent[0], y0 = extent[1], x1 = extent[2], y1 = extent[3];
    var sy0 = (y0 + 0.12 * (y1 - y0)).toInt();
    var sy1 = (y1 - 0.12 * (y1 - y0)).toInt();
    var sx0 = (x0 + 0.12 * (x1 - x0)).toInt();
    var sx1 = (x1 - 0.12 * (x1 - x0)).toInt();
    sy0 = math.max(0, sy0);
    sy1 = math.min(f.height, math.max(sy1, sy0 + 4));
    sx0 = math.max(0, sx0);
    sx1 = math.min(f.width, math.max(sx1, sx0 + 4));
    xc = (x0 + x1) / 2;
    yc = (y0 + y1) / 2;
    final n = CardLocator._shears.length;
    // per shear: left/right (x positions), top/bottom (y positions)
    final lr =
        List.generate(n, (_) => [Float64List(f.width), Float64List(f.width)]);
    final tb =
        List.generate(n, (_) => [Float64List(f.height), Float64List(f.height)]);
    for (var si = 0; si < n; si++) {
      final sh = CardLocator._shears[si];
      // Sheared images sampled once per pixel, then differenced with a
      // wrap-around shift as numpy's roll.
      final rows = sy1 - sy0, cols = sx1 - sx0;
      // A row's shear is a constant horizontal shift, so each sheared row
      // is a 1D linear interpolation of the frame row (zero outside).
      final sx = Float64List(rows * f.width);
      for (var y = sy0; y < sy1; y++) {
        final shift = sh * (y - yc);
        final whole = shift.floor();
        final frac = shift - whole;
        final base = y * f.width, out = (y - sy0) * f.width;
        for (var x = 0; x < f.width; x++) {
          final x0 = x + whole, x1 = x0 + 1;
          final v0 = x0 >= 0 && x0 < f.width ? f.data[base + x0] : 0.0;
          final v1 = x1 >= 0 && x1 < f.width ? f.data[base + x1] : 0.0;
          sx[out + x] = v0 + (v1 - v0) * frac;
        }
      }
      final sy = Float64List(f.height * cols);
      for (var x = sx0; x < sx1; x++) {
        final shift = sh * (x - xc);
        final whole = shift.floor();
        final frac = shift - whole;
        for (var y = 0; y < f.height; y++) {
          final y0 = y + whole, y1 = y0 + 1;
          final v0 = y0 >= 0 && y0 < f.height ? f.data[y0 * f.width + x] : 0.0;
          final v1 = y1 >= 0 && y1 < f.height ? f.data[y1 * f.width + x] : 0.0;
          sy[y * cols + x - sx0] = v0 + (v1 - v0) * frac;
        }
      }
      for (var x = 0; x < f.width; x++) {
        final xn = (x + d) % f.width, xp = (x - d + f.width) % f.width;
        var left = 0.0, right = 0.0;
        for (var r = 0; r < rows; r++) {
          final nxt = sx[r * f.width + xn], prv = sx[r * f.width + xp];
          left += _response(nxt, prv);
          right += _response(prv, nxt);
        }
        lr[si][0][x] = left / rows;
        lr[si][1][x] = right / rows;
      }
      for (var y = 0; y < f.height; y++) {
        final yn = (y + d) % f.height, yp = (y - d + f.height) % f.height;
        var top = 0.0, bottom = 0.0;
        for (var c = 0; c < cols; c++) {
          final nxt = sy[yn * cols + c], prv = sy[yp * cols + c];
          top += _response(nxt, prv);
          bottom += _response(prv, nxt);
        }
        tb[si][0][y] = top / cols;
        tb[si][1][y] = bottom / cols;
      }
    }
    for (var k = 0; k < 4; k++) {
      final len = k.isEven ? f.width : f.height;
      final best = Float64List(len);
      final arg = Int32List(len);
      for (var i = 0; i < len; i++) {
        var b = -1.0, a = 0;
        for (var si = 0; si < n; si++) {
          final v = (k.isEven ? lr[si][k ~/ 2] : tb[si][k ~/ 2])[i];
          if (v > b) {
            b = v;
            a = si;
          }
        }
        best[i] = b;
        arg[i] = a;
      }
      outer.add(best);
      _argShear.add(arg);
    }
    for (var k = 0; k < 4; k++) {
      final raw = outer[(k + 2) % 4];
      final len = raw.length;
      final slack = Float64List(len);
      for (var i = 0; i < len; i++) {
        var b = raw[i];
        for (var s = -4; s <= 4; s++) {
          final v = raw[((i - s) % len + len) % len];
          if (v > b) b = v;
        }
        slack[i] = b;
      }
      window.add(slack);
    }
  }

  late final double xc, yc;
  final outer = <Float64List>[];
  late final outerMax = [for (final o in outer) _RangeMax(o)];
  final window = <Float64List>[];
  final _argShear = <Int32List>[];

  Float64List windowRaw(int side) => outer[(side + 2) % 4];
  double windowShear(int side, int at) =>
      CardLocator._shears[_argShear[(side + 2) % 4][at]];
  double outerShear(int side, int at) =>
      CardLocator._shears[_argShear[side][at]];

  static double _response(double inside, double outside) =>
      ((inside - outside - 3) / 22).clamp(0.0, 1.0) *
      ((inside - 110) / 70).clamp(0.0, 1.0);
}

/// Sparse table: max over any index range in O(1).
class _RangeMax {
  _RangeMax(Float64List values) : length = values.length {
    _levels.add(values);
    for (var k = 1; (1 << k) <= length; k++) {
      final prev = _levels[k - 1], half = 1 << (k - 1);
      final next = Float64List(length - (1 << k) + 1);
      for (var i = 0; i < next.length; i++) {
        next[i] = math.max(prev[i], prev[i + half]);
      }
      _levels.add(next);
    }
  }
  final int length;
  final _levels = <Float64List>[];

  /// Inclusive range [lo, hi].
  double max(int lo, int hi) {
    if (hi < lo) return 0;
    var k = 0;
    while ((2 << k) <= hi - lo + 1) {
      k++;
    }
    return math.max(_levels[k][lo], _levels[k][hi - (1 << k) + 1]);
  }
}
