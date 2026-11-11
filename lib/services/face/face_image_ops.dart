import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'face_models.dart';

/// Pixel-level steps of the face pipeline, each a port of the OpenCV
/// function named in its doc comment (OpenCV 4.12 sources). Pure Dart, no
/// Flutter imports, safe to run inside `Isolate.run`.
class FaceImageOps {
  FaceImageOps._();

  static const int yunetDivisor = 32;
  static const int sfaceInputSize = 112;

  // ---------------------------------------------------------------------------
  // Conversions

  /// RGBA bytes (e.g. from `ui.Image.toByteData(rawStraightRgba)`) to BGR,
  /// alpha dropped like `cv::imread(IMREAD_COLOR)`.
  static BgrImage bgrFromRgba(Uint8List rgba, int width, int height) {
    final out = Uint8List(width * height * 3);
    for (var i = 0, o = 0; o < out.length; i += 4, o += 3) {
      out[o] = rgba[i + 2];
      out[o + 1] = rgba[i + 1];
      out[o + 2] = rgba[i];
    }
    return BgrImage(width, height, out);
  }

  /// `package:image` image to BGR. Applies EXIF orientation (as `imread`
  /// does), expands grey to three equal channels, drops alpha.
  static BgrImage bgrFromImage(img.Image source) {
    var image = source.exif.imageIfd.hasOrientation &&
            source.exif.imageIfd.orientation != 1
        ? img.bakeOrientation(source)
        : source;
    if (image.format != img.Format.uint8 ||
        image.hasPalette ||
        image.numChannels != 3) {
      image = image.convert(format: img.Format.uint8, numChannels: 3);
    }
    final bytes = image.getBytes(order: img.ChannelOrder.bgr);
    return BgrImage(image.width, image.height, Uint8List.fromList(bytes));
  }

  // ---------------------------------------------------------------------------
  // Detection input

  /// Size a photo is shrunk to before detection: longest side becomes
  /// [maxSide], aspect kept, rounded half up. Unchanged when already small.
  static ({int width, int height}) detectionSize(
    int width,
    int height,
    int maxSide,
  ) {
    final longSide = math.max(width, height);
    if (maxSide <= 0 || longSide <= maxSide) {
      return (width: width, height: height);
    }
    int fit(int v) => math.max(1, (v * maxSide + longSide ~/ 2) ~/ longSide);
    return (width: fit(width), height: fit(height));
  }

  /// Size a small photo is enlarged to before detection: longest side
  /// becomes [minSide], aspect kept. Unchanged when already big enough.
  static ({int width, int height}) enlargeSize(
    int width,
    int height,
    int minSide,
  ) {
    final longSide = math.max(width, height);
    if (minSide <= 0 || longSide >= minSide) {
      return (width: width, height: height);
    }
    int fit(int v) => math.max(1, (v * minSide + longSide ~/ 2) ~/ longSide);
    return (width: fit(width), height: fit(height));
  }

  /// Bilinear resize with `cv::resize(INTER_LINEAR)` geometry (half-pixel
  /// centres, edge pixels replicated). Rounds in floating point, so values
  /// may differ from OpenCV's fixed-point result by 1. Used to enlarge.
  static BgrImage resizeLinear(BgrImage src, int dstWidth, int dstHeight) {
    if (dstWidth == src.width && dstHeight == src.height) return src;
    final out = Uint8List(dstWidth * dstHeight * 3);
    final sx = src.width / dstWidth, sy = src.height / dstHeight;
    final x0 = Int32List(dstWidth), x1 = Int32List(dstWidth);
    final fx = Float64List(dstWidth);
    for (var x = 0; x < dstWidth; x++) {
      final f = (x + 0.5) * sx - 0.5;
      final i = f.floor();
      fx[x] = f - i;
      x0[x] = i.clamp(0, src.width - 1) * 3;
      x1[x] = (i + 1).clamp(0, src.width - 1) * 3;
    }
    final data = src.data, stride = src.stride;
    var o = 0;
    for (var y = 0; y < dstHeight; y++) {
      final f = (y + 0.5) * sy - 0.5;
      final i = f.floor();
      final wy = f - i;
      final r0 = i.clamp(0, src.height - 1) * stride;
      final r1 = (i + 1).clamp(0, src.height - 1) * stride;
      for (var x = 0; x < dstWidth; x++) {
        final wx = fx[x], a = x0[x], b = x1[x];
        for (var c = 0; c < 3; c++) {
          final top =
              data[r0 + a + c] + (data[r0 + b + c] - data[r0 + a + c]) * wx;
          final bottom =
              data[r1 + a + c] + (data[r1 + b + c] - data[r1 + a + c]) * wx;
          out[o++] = (top + (bottom - top) * wy).round().clamp(0, 255);
        }
      }
    }
    return BgrImage(dstWidth, dstHeight, out);
  }

  /// `cv::resize(src, dst, Size(w, h), 0, 0, INTER_AREA)` for 8UC3,
  /// downscaling only (both scale factors >= 1).
  static BgrImage resizeArea(BgrImage src, int dstWidth, int dstHeight) {
    if (dstWidth == src.width && dstHeight == src.height) return src;
    // cv::resize: inv_scale = dsize / ssize; hal::resize: scale = 1 / inv.
    final scaleX = 1.0 / (dstWidth / src.width);
    final scaleY = 1.0 / (dstHeight / src.height);
    if (scaleX < 1 || scaleY < 1) {
      throw ArgumentError('resizeArea only downscales '
          '(${src.width}x${src.height} -> ${dstWidth}x$dstHeight)');
    }
    final iScaleX = cvRound(scaleX);
    final iScaleY = cvRound(scaleY);
    const dblEpsilon = 2.220446049250313e-16;
    final isAreaFast = (scaleX - iScaleX).abs() < dblEpsilon &&
        (scaleY - iScaleY).abs() < dblEpsilon;
    if (isAreaFast) {
      return _resizeAreaFast(src, dstWidth, dstHeight, iScaleX, iScaleY);
    }
    return _resizeAreaGeneric(src, dstWidth, dstHeight, scaleX, scaleY);
  }

  /// `resizeAreaFast_Invoker<uchar,int>` + ResizeAreaFastVec (2×2 path uses
  /// `(sum + 2) >> 2`, other integer factors `cvRound(sum * (1.f/area))`).
  static BgrImage _resizeAreaFast(
    BgrImage src,
    int dw,
    int dh,
    int sx,
    int sy,
  ) {
    final out = Uint8List(dw * dh * 3);
    final s = src.data;
    final stride = src.stride;
    final area = sx * sy;
    final invArea = toFloat32(1.0 / area);
    final twoByTwo = sx == 2 && sy == 2;
    for (var dy = 0; dy < dh; dy++) {
      final row0 = dy * sy;
      for (var dx = 0; dx < dw; dx++) {
        final col0 = dx * sx;
        for (var c = 0; c < 3; c++) {
          var sum = 0;
          for (var ky = 0; ky < sy; ky++) {
            final base = (row0 + ky) * stride + col0 * 3 + c;
            for (var kx = 0; kx < sx; kx++) {
              sum += s[base + kx * 3];
            }
          }
          out[(dy * dw + dx) * 3 + c] = twoByTwo
              ? (sum + 2) >> 2
              : saturateU8(cvRound(toFloat32(sum * invArea)));
        }
      }
    }
    return BgrImage(dw, dh, out);
  }

  /// computeResizeAreaTab + `ResizeArea_Invoker<uchar,float>`.
  static BgrImage _resizeAreaGeneric(
    BgrImage src,
    int dw,
    int dh,
    double scaleX,
    double scaleY,
  ) {
    final xtab = _areaTab(src.width, dw, scaleX);
    final ytab = _areaTab(src.height, dh, scaleY);
    final out = Uint8List(dw * dh * 3);
    final rowLen = dw * 3;
    final buf = Float32List(rowLen);
    final sum = Float32List(rowLen);
    final s = src.data;
    final stride = src.stride;

    void store(int dy) {
      final o = dy * rowLen;
      for (var i = 0; i < rowLen; i++) {
        out[o + i] = saturateU8(cvRound(sum[i]));
      }
    }

    var prevDy = ytab.isEmpty ? 0 : ytab[0].di;
    for (var j = 0; j < ytab.length; j++) {
      final beta = ytab[j].alpha;
      final dy = ytab[j].di;
      final rowBase = ytab[j].si * stride;
      buf.fillRange(0, rowLen, 0);
      for (final t in xtab) {
        final si = rowBase + t.si * 3;
        final di = t.di * 3;
        final a = t.alpha;
        buf[di] = buf[di] + toFloat32(s[si] * a);
        buf[di + 1] = buf[di + 1] + toFloat32(s[si + 1] * a);
        buf[di + 2] = buf[di + 2] + toFloat32(s[si + 2] * a);
      }
      if (dy != prevDy) {
        store(prevDy);
        for (var i = 0; i < rowLen; i++) {
          sum[i] = buf[i] * beta;
        }
        prevDy = dy;
      } else {
        for (var i = 0; i < rowLen; i++) {
          sum[i] = sum[i] + toFloat32(buf[i] * beta);
        }
      }
    }
    store(prevDy);
    return BgrImage(dw, dh, out);
  }

  static List<_AreaTab> _areaTab(int ssize, int dsize, double scale) {
    final tab = <_AreaTab>[];
    for (var dx = 0; dx < dsize; dx++) {
      final fsx1 = dx * scale;
      final fsx2 = fsx1 + scale;
      final cellWidth = math.min(scale, ssize - fsx1);
      var sx1 = fsx1.ceil();
      var sx2 = fsx2.floor();
      sx2 = math.min(sx2, ssize - 1);
      sx1 = math.min(sx1, sx2);
      if (sx1 - fsx1 > 1e-3) {
        tab.add(_AreaTab(dx, sx1 - 1, toFloat32((sx1 - fsx1) / cellWidth)));
      }
      for (var sx = sx1; sx < sx2; sx++) {
        tab.add(_AreaTab(dx, sx, toFloat32(1.0 / cellWidth)));
      }
      if (fsx2 - sx2 > 1e-3) {
        tab.add(_AreaTab(
          dx,
          sx2,
          toFloat32(math.min(math.min(fsx2 - sx2, 1.0), cellWidth) / cellWidth),
        ));
      }
    }
    return tab;
  }

  /// YuNet input: `copyMakeBorder` bottom/right with zeros up to a multiple
  /// of 32, then `dnn::blobFromImage(pad)` with defaults (scale 1, no mean,
  /// no swapRB) — i.e. NCHW float32, BGR, raw 0..255.
  static ({Float32List tensor, int padWidth, int padHeight}) yunetInput(
    BgrImage image,
  ) {
    final padW = padToDivisor(image.width);
    final padH = padToDivisor(image.height);
    final plane = padW * padH;
    final tensor = Float32List(3 * plane);
    final s = image.data;
    for (var y = 0; y < image.height; y++) {
      final srcRow = y * image.stride;
      final dstRow = y * padW;
      for (var x = 0; x < image.width; x++) {
        final si = srcRow + x * 3;
        final di = dstRow + x;
        tensor[di] = s[si].toDouble();
        tensor[plane + di] = s[si + 1].toDouble();
        tensor[2 * plane + di] = s[si + 2].toDouble();
      }
    }
    return (tensor: tensor, padWidth: padW, padHeight: padH);
  }

  /// `((v - 1) / 32 + 1) * 32`, as in FaceDetectorYNImpl::setInputSize.
  static int padToDivisor(int v) =>
      ((v - 1) ~/ yunetDivisor + 1) * yunetDivisor;

  // ---------------------------------------------------------------------------
  // Alignment & recognition input

  /// `cv::warpAffine(src, dst, M, Size(w, h), INTER_LINEAR)` (forward map,
  /// BORDER_CONSTANT 0) for 8UC3, reproducing the fixed-point path:
  /// coordinates in 1/1024 px snapped to a 32×32 sub-pixel table, weights
  /// scaled by 2^15 (hal::warpAffine → warpAffineBlockline → remapBilinear).
  static BgrImage warpAffine(
    BgrImage src,
    List<double> matrix,
    int dstWidth,
    int dstHeight,
  ) {
    assert(matrix.length == 6);
    // Invert (no WARP_INVERSE_MAP flag): same arithmetic as cv::warpAffine.
    final m = List<double>.of(matrix);
    var d = m[0] * m[4] - m[1] * m[3];
    d = d != 0 ? 1.0 / d : 0.0;
    final a11 = m[4] * d, a22 = m[0] * d;
    m[0] = a11;
    m[1] *= -d;
    m[3] *= -d;
    m[4] = a22;
    final b1 = -m[0] * m[2] - m[1] * m[5];
    final b2 = -m[3] * m[2] - m[4] * m[5];
    m[2] = b1;
    m[5] = b2;

    const abBits = 10, abScale = 1 << abBits;
    const interBits = 5, interTabSize = 1 << interBits;
    const roundDelta = abScale ~/ interTabSize ~/ 2;
    const shift = abBits - interBits;
    const coefBits = 15;

    final adelta = Int32List(dstWidth);
    final bdelta = Int32List(dstWidth);
    for (var x = 0; x < dstWidth; x++) {
      adelta[x] = saturateI32(cvRound(m[0] * x * abScale));
      bdelta[x] = saturateI32(cvRound(m[3] * x * abScale));
    }

    final out = Uint8List(dstWidth * dstHeight * 3);
    final s = src.data;
    final sw = src.width, sh = src.height, stride = src.stride;
    for (var y = 0; y < dstHeight; y++) {
      final x0 = saturateI32(cvRound((m[1] * y + m[2]) * abScale)) + roundDelta;
      final y0 = saturateI32(cvRound((m[4] * y + m[5]) * abScale)) + roundDelta;
      for (var x = 0; x < dstWidth; x++) {
        final xx = (x0 + adelta[x]) >> shift;
        final yy = (y0 + bdelta[x]) >> shift;
        // saturate_cast<short> in warpAffineBlockline.
        final sx = _saturateI16(xx >> interBits);
        final sy = _saturateI16(yy >> interBits);
        final fx = xx & (interTabSize - 1);
        final fy = yy & (interTabSize - 1);
        // BilinearTab_i: products of (1 - k/32, k/32) are exact in float, so
        // the 2^15-scaled table is exactly these integers (sum 32768).
        final w00 = (interTabSize - fy) * (interTabSize - fx) * 32;
        final w01 = (interTabSize - fy) * fx * 32;
        final w10 = fy * (interTabSize - fx) * 32;
        final w11 = fy * fx * 32;
        final o = (y * dstWidth + x) * 3;
        if (sx >= sw || sx + 1 < 0 || sy >= sh || sy + 1 < 0) {
          continue; // fully outside: border value 0 (already zero).
        }
        final in0 = sy >= 0 && sy < sh;
        final in1 = sy + 1 >= 0 && sy + 1 < sh;
        final inX0 = sx >= 0 && sx < sw;
        final inX1 = sx + 1 >= 0 && sx + 1 < sw;
        final r0 = sy * stride, r1 = (sy + 1) * stride;
        for (var c = 0; c < 3; c++) {
          final v00 = in0 && inX0 ? s[r0 + sx * 3 + c] : 0;
          final v01 = in0 && inX1 ? s[r0 + (sx + 1) * 3 + c] : 0;
          final v10 = in1 && inX0 ? s[r1 + sx * 3 + c] : 0;
          final v11 = in1 && inX1 ? s[r1 + (sx + 1) * 3 + c] : 0;
          final acc = v00 * w00 + v01 * w01 + v10 * w10 + v11 * w11;
          out[o + c] = saturateU8((acc + (1 << (coefBits - 1))) >> coefBits);
        }
      }
    }
    return BgrImage(dstWidth, dstHeight, out);
  }

  /// SFace input: `dnn::blobFromImage(aligned, 1, Size(112,112),
  /// Scalar(0,0,0), swapRB=true, crop=false)` — NCHW float32, **RGB**,
  /// raw 0..255. [aligned] must already be 112×112 (alignCrop output).
  static Float32List sfaceInput(BgrImage aligned) {
    if (aligned.width != sfaceInputSize || aligned.height != sfaceInputSize) {
      throw ArgumentError('SFace expects 112x112, got '
          '${aligned.width}x${aligned.height}');
    }
    const plane = sfaceInputSize * sfaceInputSize;
    final tensor = Float32List(3 * plane);
    final s = aligned.data;
    for (var i = 0; i < plane; i++) {
      tensor[i] = s[i * 3 + 2].toDouble(); // R
      tensor[plane + i] = s[i * 3 + 1].toDouble(); // G
      tensor[2 * plane + i] = s[i * 3].toDouble(); // B
    }
    return tensor;
  }

  // ---------------------------------------------------------------------------
  // Numeric helpers matching OpenCV's saturate_cast / cvRound semantics.

  static final Float32List _f32 = Float32List(1);

  /// Round a double to the nearest float32 (C++ `(float)x`).
  static double toFloat32(double v) {
    _f32[0] = v;
    return _f32[0];
  }

  /// `cvRound`: round half to even (lrint in the default FP mode).
  static int cvRound(double v) {
    final f = v.floorToDouble();
    final diff = v - f;
    if (diff < 0.5) return f.toInt();
    if (diff > 0.5) return f.toInt() + 1;
    final fi = f.toInt();
    return fi.isEven ? fi : fi + 1;
  }

  static int saturateU8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

  static int saturateI32(int v) =>
      v < -0x80000000 ? -0x80000000 : (v > 0x7fffffff ? 0x7fffffff : v);

  static int _saturateI16(int v) =>
      v < -32768 ? -32768 : (v > 32767 ? 32767 : v);
}

class _AreaTab {
  final int di;
  final int si;
  final double alpha;

  const _AreaTab(this.di, this.si, this.alpha);
}
