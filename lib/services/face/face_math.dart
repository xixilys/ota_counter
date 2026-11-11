import 'dart:math' as math;
import 'dart:typed_data';

import 'face_image_ops.dart';
import 'face_models.dart';

/// Non-pixel maths of the face pipeline, ported from OpenCV 4.12:
/// FaceDetectorYNImpl::postProcess (objdetect/src/face_detect.cpp),
/// dnn::NMSBoxes (dnn/src/nms.inl.hpp), and
/// FaceRecognizerSFImpl::getSimilarityTransformMatrix
/// (objdetect/src/face_recognize.cpp). Pure Dart, unit-tested on host.
class FaceMath {
  FaceMath._();

  static const List<int> yunetStrides = [8, 16, 32];

  /// YuNet output tensor names, in the order OpenCV requests them.
  static const List<String> yunetOutputNames = [
    'cls_8', 'cls_16', 'cls_32', //
    'obj_8', 'obj_16', 'obj_32', //
    'bbox_8', 'bbox_16', 'bbox_32', //
    'kps_8', 'kps_16', 'kps_32', //
  ];

  /// FaceDetectorYNImpl::postProcess: decode every anchor of the three
  /// strides, keep `score >= scoreThreshold`, then (only when more than one
  /// face survived) NMSBoxes on int-truncated boxes.
  ///
  /// [outputs] maps the 12 [yunetOutputNames] to their flat float data.
  /// Coordinates are in the padded input frame (= the detection image,
  /// since padding is bottom/right only).
  static List<FaceDetection> decodeYunet(
    Map<String, Float32List> outputs, {
    required int padWidth,
    required int padHeight,
    double scoreThreshold = 0.6,
    double nmsThreshold = 0.3,
    int topK = 5000,
  }) {
    final rows = <List<double>>[];
    final f = FaceImageOps.toFloat32;
    // FaceDetectorYNImpl stores both thresholds as float members.
    scoreThreshold = f(scoreThreshold);
    nmsThreshold = f(nmsThreshold);
    for (final stride in yunetStrides) {
      final cols = padWidth ~/ stride;
      final rowCount = padHeight ~/ stride;
      final cls = outputs['cls_$stride']!;
      final obj = outputs['obj_$stride']!;
      final bbox = outputs['bbox_$stride']!;
      final kps = outputs['kps_$stride']!;
      if (cls.length < cols * rowCount ||
          bbox.length < cols * rowCount * 4 ||
          kps.length < cols * rowCount * 10) {
        throw StateError('YuNet stride $stride output too small for '
            '${padWidth}x$padHeight input');
      }
      for (var r = 0; r < rowCount; r++) {
        for (var c = 0; c < cols; c++) {
          final idx = r * cols + c;
          final clsScore = cls[idx].clamp(0.0, 1.0);
          final objScore = obj[idx].clamp(0.0, 1.0);
          final score = f(math.sqrt(f(clsScore * objScore)));
          if (score < scoreThreshold) continue;

          final cx = f((c + bbox[idx * 4]) * stride);
          final cy = f((r + bbox[idx * 4 + 1]) * stride);
          final w = f(math.exp(bbox[idx * 4 + 2]) * stride);
          final h = f(math.exp(bbox[idx * 4 + 3]) * stride);
          final row = List<double>.filled(15, 0);
          row[0] = f(cx - w / 2);
          row[1] = f(cy - h / 2);
          row[2] = w;
          row[3] = h;
          for (var n = 0; n < 5; n++) {
            row[4 + 2 * n] = f((kps[idx * 10 + 2 * n] + c) * stride);
            row[5 + 2 * n] = f((kps[idx * 10 + 2 * n + 1] + r) * stride);
          }
          row[14] = score;
          rows.add(row);
        }
      }
    }

    if (rows.length <= 1) {
      return [for (final row in rows) FaceDetection.fromOpenCvRow(row)];
    }
    final boxes = [
      for (final row in rows)
        // Rect2i(int(x), int(y), int(w), int(h)): C++ truncation toward 0.
        <int>[row[0].toInt(), row[1].toInt(), row[2].toInt(), row[3].toInt()],
    ];
    final keep = nmsBoxes(
      boxes,
      [for (final row in rows) row[14]],
      scoreThreshold: scoreThreshold,
      nmsThreshold: nmsThreshold,
      topK: topK,
    );
    return [for (final i in keep) FaceDetection.fromOpenCvRow(rows[i])];
  }

  /// `dnn::NMSBoxes(std::vector<Rect>, ...)` with eta = 1: candidates with
  /// `score > scoreThreshold` (strict), stable-sorted by score descending,
  /// cut to [topK] (if > 0), then greedy suppression with
  /// `keep = IoU <= nmsThreshold`. Boxes are `[x, y, w, h]` integers.
  static List<int> nmsBoxes(
    List<List<int>> boxes,
    List<double> scores, {
    required double scoreThreshold,
    required double nmsThreshold,
    int topK = 0,
  }) {
    assert(boxes.length == scores.length);
    final order = <int>[
      for (var i = 0; i < scores.length; i++)
        if (scores[i] > scoreThreshold) i,
    ];
    // List.sort is not stable; break ties by index to emulate stable_sort.
    order.sort((a, b) {
      final c = scores[b].compareTo(scores[a]);
      return c != 0 ? c : a.compareTo(b);
    });
    if (topK > 0 && topK < order.length) {
      order.removeRange(topK, order.length);
    }
    final kept = <int>[];
    for (final idx in order) {
      var keep = true;
      for (var k = 0; k < kept.length && keep; k++) {
        keep = rectOverlap(boxes[idx], boxes[kept[k]]) <= nmsThreshold;
      }
      if (keep) kept.add(idx);
    }
    return kept;
  }

  /// `1.f - (float)jaccardDistance(a, b)` for integer Rects.
  static double rectOverlap(List<int> a, List<int> b) {
    final areaA = a[2] * a[3];
    final areaB = b[2] * b[3];
    if (areaA + areaB <= 0) {
      return FaceImageOps.toFloat32(1.0); // jaccardDistance 0
    }
    final x1 = math.max(a[0], b[0]);
    final y1 = math.max(a[1], b[1]);
    final iw = math.min(a[0] + a[2], b[0] + b[2]) - x1;
    final ih = math.min(a[1] + a[3], b[1] + b[3]) - y1;
    final inter = (iw <= 0 || ih <= 0) ? 0 : iw * ih;
    final distance =
        FaceImageOps.toFloat32(1.0 - inter / (areaA + areaB - inter));
    return FaceImageOps.toFloat32(1.0 - distance);
  }

  /// Drop faces whose shorter box side is below [fraction] of the image's
  /// shorter side (app-specific; not part of OpenCV).
  static List<FaceDetection> filterSmallFaces(
    List<FaceDetection> faces,
    int imageWidth,
    int imageHeight,
    double fraction,
  ) {
    if (fraction <= 0) return faces;
    final minSide = fraction * math.min(imageWidth, imageHeight);
    return [
      for (final face in faces)
        if (math.min(face.width, face.height) >= minSide) face,
    ];
  }

  // ---------------------------------------------------------------------------
  // Alignment

  /// ArcFace 112×112 five-point template used by FaceRecognizerSF.
  static const List<List<double>> alignTemplate = [
    [38.2946, 51.6963],
    [73.5318, 51.5014],
    [56.0252, 71.7366],
    [41.5493, 92.3655],
    [70.7299, 92.2041],
  ];

  /// getSimilarityTransformMatrix: least-squares similarity (Umeyama) from
  /// the 5 landmarks to [alignTemplate]; returns the 2×3 matrix row-major.
  ///
  /// OpenCV builds the 2×2 cross-covariance A, takes its SVD and forms
  /// `T = U·diag(1, d)·Vᵀ`, `scale = (s0 + d·s1) / var`, with d = -1 when
  /// det(A) < 0. For 2×2 that is always the rotation closest to A, so
  /// `scale·T = [[a+d, b-c], [c-b, a+d]] / var` exactly (both branches,
  /// rank-1 included). Means/demeans are float like the C++ code.
  static List<double> similarityTransform(List<FacePoint> landmarks) {
    if (landmarks.length != 5) {
      throw ArgumentError('need 5 landmarks, got ${landmarks.length}');
    }
    final f = FaceImageOps.toFloat32;
    final src = [
      for (final p in landmarks) [f(p.x), f(p.y)],
    ];
    final dst = [
      for (final p in alignTemplate) [f(p[0]), f(p[1])],
    ];
    // float avg = (s0 + s1 + s2 + s3 + s4) / 5, accumulated in float.
    double floatMean(int axis) {
      var acc = src[0][axis];
      for (var i = 1; i < 5; i++) {
        acc = f(acc + src[i][axis]);
      }
      return f(acc / 5);
    }

    final srcMean = [floatMean(0), floatMean(1)];
    final dstMean = [f(56.0262), f(71.9008)];
    final srcDemean = [
      for (final p in src) [f(p[0] - srcMean[0]), f(p[1] - srcMean[1])],
    ];
    final dstDemean = [
      for (final p in dst) [f(p[0] - dstMean[0]), f(p[1] - dstMean[1])],
    ];

    double cross(int i, int j) {
      var acc = 0.0;
      for (var k = 0; k < 5; k++) {
        acc += f(dstDemean[k][i] * srcDemean[k][j]);
      }
      return acc / 5;
    }

    final a00 = cross(0, 0), a01 = cross(0, 1);
    final a10 = cross(1, 0), a11 = cross(1, 1);

    var var1 = 0.0, var2 = 0.0;
    for (var k = 0; k < 5; k++) {
      var1 += f(srcDemean[k][0] * srcDemean[k][0]);
      var2 += f(srcDemean[k][1] * srcDemean[k][1]);
    }
    final variance = var1 / 5 + var2 / 5;
    if (variance == 0) {
      return [0, 0, dstMean[0], 0, 0, dstMean[1]];
    }

    final p = a00 + a11; // = n·cosθ
    final q = a10 - a01; // = n·sinθ
    final t00 = p / variance, t01 = -q / variance;
    final t10 = q / variance, t11 = p / variance;
    return [
      t00,
      t01,
      dstMean[0] - (t00 * srcMean[0] + t01 * srcMean[1]),
      t10,
      t11,
      dstMean[1] - (t10 * srcMean[0] + t11 * srcMean[1]),
    ];
  }

  /// FaceRecognizerSF::alignCrop: similarity transform + 112×112 warp.
  static BgrImage alignCrop(BgrImage image, FaceDetection face) {
    return FaceImageOps.warpAffine(
      image,
      similarityTransform(face.landmarks),
      FaceImageOps.sfaceInputSize,
      FaceImageOps.sfaceInputSize,
    );
  }

  // ---------------------------------------------------------------------------
  // Embeddings

  /// L2-normalise (cv::normalize default NORM_L2) into a new list.
  static Float32List l2Normalize(List<double> v) {
    var sumSq = 0.0;
    for (final x in v) {
      sumSq += x * x;
    }
    final norm = math.sqrt(sumSq);
    final out = Float32List(v.length);
    if (norm == 0) return out;
    for (var i = 0; i < v.length; i++) {
      out[i] = v[i] / norm;
    }
    return out;
  }

  /// Cosine similarity, = FaceRecognizerSF::match(FR_COSINE). Inputs need not
  /// be normalised. OpenCV Zoo's same-person threshold for SFace is 0.363.
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) {
      throw ArgumentError('length mismatch: ${a.length} vs ${b.length}');
    }
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / math.sqrt(na * nb);
  }

  /// IoU of two float boxes (used to compare detections, not by NMS).
  static double boxIou(FaceDetection a, FaceDetection b) {
    final x1 = math.max(a.x, b.x);
    final y1 = math.max(a.y, b.y);
    final x2 = math.min(a.x + a.width, b.x + b.width);
    final y2 = math.min(a.y + a.height, b.y + b.height);
    final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
    final union = a.width * a.height + b.width * b.height - inter;
    return union <= 0 ? 0 : inter / union;
  }
}
