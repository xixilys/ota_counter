import 'dart:typed_data';

/// 8-bit BGR image, rows packed without padding (`stride == width * 3`).
///
/// BGR on purpose: OpenCV's `imread` returns BGR and both YuNet and the
/// SFace preprocessing are defined relative to that order.
class BgrImage {
  final int width;
  final int height;
  final Uint8List data;

  BgrImage(this.width, this.height, this.data)
      : assert(width > 0 && height > 0),
        assert(data.length == width * height * 3);

  int get stride => width * 3;
}

class FacePoint {
  final double x;
  final double y;

  const FacePoint(this.x, this.y);

  Map<String, dynamic> toMap() => {'x': x, 'y': y};

  factory FacePoint.fromMap(Map<String, dynamic> map) => FacePoint(
        (map['x'] as num).toDouble(),
        (map['y'] as num).toDouble(),
      );

  @override
  String toString() => '(${x.toStringAsFixed(1)}, ${y.toStringAsFixed(1)})';
}

/// One detected face, in the same layout as a row of OpenCV
/// `FaceDetectorYN::detect` output.
class FaceDetection {
  /// Top-left corner and size of the face box.
  final double x;
  final double y;
  final double width;
  final double height;

  /// Right eye, left eye, nose tip, right mouth corner, left mouth corner
  /// (OpenCV order; "right" is the subject's right, i.e. image left).
  final List<FacePoint> landmarks;

  /// sqrt(cls * obj), 0..1.
  final double score;

  const FaceDetection({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.landmarks,
    required this.score,
  });

  /// Same 15 numbers as an OpenCV face row:
  /// x, y, w, h, 5 × (lx, ly), score.
  List<double> toOpenCvRow() => [
        x,
        y,
        width,
        height,
        for (final p in landmarks) ...[p.x, p.y],
        score,
      ];

  factory FaceDetection.fromOpenCvRow(List<double> row) {
    assert(row.length >= 15);
    return FaceDetection(
      x: row[0],
      y: row[1],
      width: row[2],
      height: row[3],
      landmarks: [
        for (var i = 0; i < 5; i++) FacePoint(row[4 + 2 * i], row[5 + 2 * i]),
      ],
      score: row[14],
    );
  }

  FaceDetection scaled(double sx, double sy) => FaceDetection(
        x: x * sx,
        y: y * sy,
        width: width * sx,
        height: height * sy,
        landmarks: [for (final p in landmarks) FacePoint(p.x * sx, p.y * sy)],
        score: score,
      );

  Map<String, dynamic> toMap() => {
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'landmarks': [for (final p in landmarks) p.toMap()],
        'score': score,
      };

  factory FaceDetection.fromMap(Map<String, dynamic> map) => FaceDetection(
        x: (map['x'] as num).toDouble(),
        y: (map['y'] as num).toDouble(),
        width: (map['width'] as num).toDouble(),
        height: (map['height'] as num).toDouble(),
        landmarks: [
          for (final p in map['landmarks'] as List)
            FacePoint.fromMap(Map<String, dynamic>.from(p as Map)),
        ],
        score: (map['score'] as num).toDouble(),
      );

  @override
  String toString() => 'FaceDetection(${x.toStringAsFixed(1)}, '
      '${y.toStringAsFixed(1)}, ${width.toStringAsFixed(1)}×'
      '${height.toStringAsFixed(1)}, score ${score.toStringAsFixed(3)})';
}

/// Detection parameters. Defaults follow the OpenCV Zoo YuNet demo
/// (score 0.6, NMS 0.3) plus two app-specific steps OpenCV leaves to the
/// caller: shrinking big photos before detection and dropping tiny faces.
class FaceDetectorOptions {
  final double scoreThreshold;
  final double nmsThreshold;

  /// Same meaning as OpenCV `top_k`: max candidates kept before NMS.
  final int topK;

  /// Longest side fed to YuNet. Bigger photos are shrunk (INTER_AREA);
  /// smaller ones are used as-is. <= 0 disables shrinking.
  final int maxDetectSide;

  /// Longest side below which a photo is enlarged (bilinear) before
  /// detection. A cheki cut from a desk shot is ~150×240 px and its faces
  /// ~25 px, too small for YuNet's finest anchors; enlarging to 480 found
  /// faces on 16 of 19 real cuts instead of 14. <= 0 disables enlarging.
  final int minDetectSide;

  /// Drop faces whose shorter box side is below this fraction of the
  /// image's shorter side. 0 keeps everything (pure OpenCV behaviour).
  final double minFaceFraction;

  const FaceDetectorOptions({
    this.scoreThreshold = 0.6,
    this.nmsThreshold = 0.3,
    this.topK = 5000,
    this.maxDetectSide = 1280,
    this.minDetectSide = 480,
    this.minFaceFraction = 0.04,
  });
}

/// Result of [FaceEngine.detect].
class FaceDetectionResult {
  /// Size of the image passed in; [faces] use these coordinates.
  final int imageWidth;
  final int imageHeight;

  /// Faces in original-image coordinates, highest score first.
  final List<FaceDetection> faces;

  /// The (possibly shrunk) image YuNet actually saw, and the faces in its
  /// coordinates. Alignment for embeddings uses these, like an OpenCV
  /// pipeline that calls `alignCrop` on the image it detected on.
  final BgrImage detectionImage;
  final List<FaceDetection> detectionFaces;

  const FaceDetectionResult({
    required this.imageWidth,
    required this.imageHeight,
    required this.faces,
    required this.detectionImage,
    required this.detectionFaces,
  });
}

/// A detected face together with its L2-normalised 128-d SFace embedding.
class FaceAnalysis {
  final FaceDetection face;
  final Float32List embedding;

  const FaceAnalysis({required this.face, required this.embedding});
}
