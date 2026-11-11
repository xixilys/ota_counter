import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'face_image_ops.dart';
import 'face_math.dart';
import 'face_models.dart';

/// On-device face detection (YuNet 2023mar) and embedding (SFace int8) on
/// onnxruntime, numerically mirroring OpenCV `FaceDetectorYN` +
/// `FaceRecognizerSF`. The maths lives in [FaceImageOps] / [FaceMath]; this
/// class only owns the two ONNX sessions (lazy, created once) and threading.
///
/// Note: assets/models/yunet.onnx is the OpenCV Zoo file with its input H/W
/// made symbolic (faceeval/scripts/make_dynamic_yunet.py) — onnxruntime,
/// unlike OpenCV DNN, rejects inputs other than the declared 640×640.
/// Replacing it with the original zoo file breaks non-640 inputs.
class FaceEngine {
  FaceEngine._();

  static const String detectorAsset = 'assets/models/yunet.onnx';
  static const String recognizerAsset = 'assets/models/sface_int8.onnx';
  static const String _detectorInput = 'input';
  static const String _recognizerInput = 'data';
  static const String _recognizerOutput = 'fc1';

  static Future<OrtSession>? _detector;
  static Future<OrtSession>? _recognizer;

  // ---------------------------------------------------------------------------
  // Decoding

  /// Decode an encoded photo (JPEG/PNG/HEIF…) to BGR with the platform codec
  /// (libjpeg-turbo via Skia on Android — same decoder family as OpenCV's
  /// imread; EXIF orientation applied). Falls back to `package:image`.
  static Future<BgrImage> decodeImageBytes(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final width = image.width, height = image.height;
      final data =
          await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (data == null) throw StateError('toByteData returned null');
      final rgba =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      return Isolate.run(() => FaceImageOps.bgrFromRgba(rgba, width, height));
    } catch (_) {
      return Isolate.run(() {
        final decoded = img.decodeImage(bytes);
        if (decoded == null) {
          throw const FormatException('无法解码图片');
        }
        return FaceImageOps.bgrFromImage(decoded);
      });
    }
  }

  /// Convenience for callers that already hold a `package:image` image.
  static Future<BgrImage> fromImage(img.Image image) =>
      Isolate.run(() => FaceImageOps.bgrFromImage(image));

  // ---------------------------------------------------------------------------
  // Detection

  /// Detect faces. Big photos are shrunk to [FaceDetectorOptions.maxDetectSide]
  /// and small ones enlarged to [FaceDetectorOptions.minDetectSide] first;
  /// returned [FaceDetectionResult.faces] are in [image] coordinates.
  static Future<FaceDetectionResult> detect(
    BgrImage image, {
    FaceDetectorOptions options = const FaceDetectorOptions(),
  }) async {
    final session = await _detectorSession();
    final maxSide = options.maxDetectSide;
    final minSide = options.minDetectSide;
    final prepared = await Isolate.run(() {
      final size =
          FaceImageOps.detectionSize(image.width, image.height, maxSide);
      final shrunk = FaceImageOps.resizeArea(image, size.width, size.height);
      final big =
          FaceImageOps.enlargeSize(shrunk.width, shrunk.height, minSide);
      final detectionImage =
          FaceImageOps.resizeLinear(shrunk, big.width, big.height);
      final input = FaceImageOps.yunetInput(detectionImage);
      return (image: detectionImage, input: input);
    });
    final detectionImage = prepared.image;
    final padW = prepared.input.padWidth, padH = prepared.input.padHeight;

    final input = await OrtValue.fromList(
      prepared.input.tensor,
      [1, 3, padH, padW],
    );
    Map<String, OrtValue> outputs = const {};
    try {
      outputs = await session.run({_detectorInput: input});
      final flat = <String, Float32List>{};
      for (final name in FaceMath.yunetOutputNames) {
        final value = outputs[name];
        if (value == null) {
          throw StateError('YuNet output "$name" missing');
        }
        flat[name] = _asFloat32(await value.asFlattenedList());
      }
      var detectionFaces = FaceMath.decodeYunet(
        flat,
        padWidth: padW,
        padHeight: padH,
        scoreThreshold: options.scoreThreshold,
        nmsThreshold: options.nmsThreshold,
        topK: options.topK,
      );
      detectionFaces = FaceMath.filterSmallFaces(
        detectionFaces,
        detectionImage.width,
        detectionImage.height,
        options.minFaceFraction,
      );
      final sx = image.width / detectionImage.width;
      final sy = image.height / detectionImage.height;
      return FaceDetectionResult(
        imageWidth: image.width,
        imageHeight: image.height,
        faces: [for (final f in detectionFaces) f.scaled(sx, sy)],
        detectionImage: detectionImage,
        detectionFaces: detectionFaces,
      );
    } finally {
      await input.dispose();
      for (final v in outputs.values) {
        await v.dispose();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Embedding

  /// L2-normalised 128-d SFace embedding of `result.faces[index]`, aligned
  /// on the image the face was detected on (OpenCV alignCrop semantics).
  static Future<Float32List> embed(FaceDetectionResult result, int index) {
    return embedAligned(
      FaceMath.alignCrop(result.detectionImage, result.detectionFaces[index]),
    );
  }

  /// Embedding of an already aligned 112×112 BGR crop.
  static Future<Float32List> embedAligned(BgrImage aligned) async {
    final session = await _recognizerSession();
    final input = await OrtValue.fromList(
      FaceImageOps.sfaceInput(aligned),
      const [1, 3, 112, 112],
    );
    Map<String, OrtValue> outputs = const {};
    try {
      outputs = await session.run({_recognizerInput: input});
      final value = outputs[_recognizerOutput] ?? outputs.values.first;
      return FaceMath.l2Normalize(
        _asFloat32(await value.asFlattenedList()),
      );
    } finally {
      await input.dispose();
      for (final v in outputs.values) {
        await v.dispose();
      }
    }
  }

  /// Decode → detect → embed every face. Faces come highest score first.
  static Future<List<FaceAnalysis>> analyzeImageBytes(
    Uint8List bytes, {
    FaceDetectorOptions options = const FaceDetectorOptions(),
  }) async {
    final image = await decodeImageBytes(bytes);
    final result = await detect(image, options: options);
    return [
      for (var i = 0; i < result.faces.length; i++)
        FaceAnalysis(face: result.faces[i], embedding: await embed(result, i)),
    ];
  }

  /// Cosine similarity of two embeddings (see [FaceMath.cosineSimilarity]).
  static double similarity(List<double> a, List<double> b) =>
      FaceMath.cosineSimilarity(a, b);

  /// Load both models now instead of on first use.
  static Future<void> warmUp() async {
    await Future.wait([_detectorSession(), _recognizerSession()]);
  }

  /// Release the native sessions (they are re-created on next use).
  static Future<void> dispose() async {
    final detector = _detector, recognizer = _recognizer;
    _detector = null;
    _recognizer = null;
    for (final f in [detector, recognizer]) {
      if (f == null) continue;
      try {
        await (await f).close();
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Sessions

  static Future<OrtSession> _detectorSession() =>
      _detector ??= _open(detectorAsset, onError: () => _detector = null);

  static Future<OrtSession> _recognizerSession() =>
      _recognizer ??= _open(recognizerAsset, onError: () => _recognizer = null);

  static Future<OrtSession> _open(
    String asset, {
    required void Function() onError,
  }) async {
    try {
      final path = await _extractAsset(asset);
      return await OnnxRuntime().createSession(path);
    } catch (_) {
      onError(); // allow a retry on the next call
      rethrow;
    }
  }

  /// Copy the model out of the bundle once. Re-copies when the size differs,
  /// so an updated model under the same asset name is picked up.
  static Future<String> _extractAsset(String asset) async {
    final data = await rootBundle.load(asset);
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/face_models/${asset.split('/').last}');
    if (await file.exists() && await file.length() == data.lengthInBytes) {
      return file.path;
    }
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    await tmp.rename(file.path);
    return file.path;
  }

  static Float32List _asFloat32(List<dynamic> values) {
    if (values is Float32List) return values;
    final out = Float32List(values.length);
    for (var i = 0; i < values.length; i++) {
      out[i] = (values[i] as num).toDouble();
    }
    return out;
  }
}
