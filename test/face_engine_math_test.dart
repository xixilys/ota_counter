import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/services/face/face_image_ops.dart';
import 'package:ota_counter/services/face/face_math.dart';
import 'package:ota_counter/services/face/face_models.dart';

/// Expected values come from OpenCV 4.12 (opencv-python 4.12.0.88) via
/// faceeval/scripts/gen_unit_expectations.py on the same synthetic inputs.

BgrImage _synth(int w, int h) {
  final data = Uint8List(w * h * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 3; c++) {
        data[(y * w + x) * 3 + c] =
            (x * 31 + y * 17 + c * 67 + (x * y) % 23) & 255;
      }
    }
  }
  return BgrImage(w, h, data);
}

(int, int) _digest(List<num> values) {
  var sum = 0, weighted = 0;
  for (var i = 0; i < values.length; i++) {
    final v = values[i].toInt();
    sum += v;
    weighted += v * ((i % 251) + 1);
  }
  return (sum, weighted);
}

List<FacePoint> _pts(List<List<double>> raw) =>
    [for (final p in raw) FacePoint(p[0], p[1])];

void main() {
  group('helpers', () {
    test('cvRound rounds half to even like lrint', () {
      expect(FaceImageOps.cvRound(0.5), 0);
      expect(FaceImageOps.cvRound(1.5), 2);
      expect(FaceImageOps.cvRound(2.5), 2);
      expect(FaceImageOps.cvRound(-0.5), 0);
      expect(FaceImageOps.cvRound(-1.5), -2);
      expect(FaceImageOps.cvRound(2.4999), 2);
      expect(FaceImageOps.cvRound(-2.6), -3);
    });

    test('detectionSize keeps aspect and only shrinks', () {
      expect(FaceImageOps.detectionSize(4000, 3000, 1280),
          (width: 1280, height: 960));
      expect(FaceImageOps.detectionSize(1531, 2360, 1280),
          (width: 830, height: 1280));
      expect(FaceImageOps.detectionSize(640, 480, 1280),
          (width: 640, height: 480));
      expect(
          FaceImageOps.detectionSize(5000, 10, 1280), (width: 1280, height: 3));
      expect(FaceImageOps.detectionSize(4000, 3000, 0),
          (width: 4000, height: 3000));
    });

    test('bgrFromImage swaps to BGR and expands grey', () {
      final rgb = img.Image(width: 2, height: 1)
        ..setPixelRgb(0, 0, 10, 20, 30)
        ..setPixelRgb(1, 0, 200, 100, 0);
      expect(FaceImageOps.bgrFromImage(rgb).data, [30, 20, 10, 0, 100, 200]);

      final grey = img.Image(width: 1, height: 1, numChannels: 1)
        ..setPixelR(0, 0, 77);
      expect(FaceImageOps.bgrFromImage(grey).data, [77, 77, 77]);

      final rgba = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(FaceImageOps.bgrFromRgba(rgba, 2, 1).data, [3, 2, 1, 7, 6, 5]);
    });
  });

  group('resizeArea matches cv::resize INTER_AREA', () {
    final cases = <(int, int, int, int, (int, int), List<int>, List<int>)>[
      (97, 61, 40, 25, (383076, 48078972), [37, 104, 171], [130, 197, 71]),
      (64, 48, 32, 24, (294308, 36410481), [24, 91, 158], [176, 179, 54]),
      (90, 60, 30, 20, (229762, 28362774), [49, 116, 183], [141, 208, 133]),
      (
        1000,
        750,
        640,
        480,
        (117504364, 14804905253),
        [17, 84, 151],
        [175, 137, 53]
      ),
    ];
    for (final (sw, sh, dw, dh, digest, first, last) in cases) {
      test('${sw}x$sh -> ${dw}x$dh', () {
        final out = FaceImageOps.resizeArea(_synth(sw, sh), dw, dh);
        expect(out.data.sublist(0, 3), first);
        expect(out.data.sublist(out.data.length - 3), last);
        expect(_digest(out.data), digest);
      });
    }

    test('rejects upscaling', () {
      expect(() => FaceImageOps.resizeArea(_synth(10, 10), 20, 20),
          throwsArgumentError);
    });
  });

  group('enlarging small photos before detection', () {
    test('enlargeSize keeps aspect and only enlarges', () {
      expect(
          FaceImageOps.enlargeSize(151, 240, 480), (width: 302, height: 480));
      expect(
          FaceImageOps.enlargeSize(240, 151, 480), (width: 480, height: 302));
      expect(
          FaceImageOps.enlargeSize(640, 480, 480), (width: 640, height: 480));
      expect(FaceImageOps.enlargeSize(151, 240, 0), (width: 151, height: 240));
    });

    test('resizeLinear is within 1 of cv::resize INTER_LINEAR', () {
      // cv2.resize(_synth(3, 2), (7, 5), interpolation=cv2.INTER_LINEAR)
      const expected = [
        0, 67, 134, 4, 71, 138, 18, 85, 151, 31, 98, 165, 44, 111, 178, //
        58, 124, 191, 62, 129, 196, 2, 69, 136, 6, 73, 140, 19, 86, 153,
        33, 100, 167, 46, 113, 180, 59, 126, 193, 64, 131, 198, 9, 76, 143,
        13, 80, 147, 26, 93, 160, 40, 107, 174, 53, 120, 187, 67, 134, 201,
        72, 139, 206, 15, 82, 149, 20, 87, 154, 33, 100, 167, 47, 114, 181,
        61, 128, 195, 75, 141, 208, 79, 146, 213, 17, 84, 151, 21, 89, 155,
        35, 102, 169, 49, 116, 183, 63, 130, 196, 76, 143, 210, 81, 148, 215,
      ];
      final out = FaceImageOps.resizeLinear(_synth(3, 2), 7, 5);
      expect(out.width, 7);
      expect(out.height, 5);
      for (var i = 0; i < expected.length; i++) {
        expect((out.data[i] - expected[i]).abs(), lessThanOrEqualTo(1),
            reason: 'byte $i: ${out.data[i]} vs ${expected[i]}');
      }
    });

    test('resizeLinear returns the same image at the same size', () {
      final src = _synth(5, 4);
      expect(identical(FaceImageOps.resizeLinear(src, 5, 4), src), isTrue);
    });
  });

  group('YuNet input / decode', () {
    test('yunetInput pads to 32 with zeros, NCHW BGR, raw values', () {
      final image = BgrImage(
        2,
        1,
        Uint8List.fromList([1, 2, 3, 4, 5, 6]), // two BGR pixels
      );
      final input = FaceImageOps.yunetInput(image);
      expect(input.padWidth, 32);
      expect(input.padHeight, 32);
      const plane = 32 * 32;
      expect(input.tensor.length, 3 * plane);
      expect(input.tensor[0], 1); // B (0,0)
      expect(input.tensor[1], 4); // B (1,0)
      expect(input.tensor[plane], 2); // G
      expect(input.tensor[2 * plane + 1], 6); // R (1,0)
      expect(input.tensor[2], 0); // padding
      expect(input.tensor[32], 0); // padding row
      expect(FaceImageOps.padToDivisor(33), 64);
      expect(FaceImageOps.padToDivisor(64), 64);
      expect(FaceImageOps.padToDivisor(1), 32);
    });

    Map<String, Float32List> emptyOutputs(int padW, int padH) => {
          for (final s in FaceMath.yunetStrides) ...{
            'cls_$s': Float32List((padW ~/ s) * (padH ~/ s)),
            'obj_$s': Float32List((padW ~/ s) * (padH ~/ s)),
            'bbox_$s': Float32List((padW ~/ s) * (padH ~/ s) * 4),
            'kps_$s': Float32List((padW ~/ s) * (padH ~/ s) * 10),
          },
        };

    test('decodes one anchor exactly like postProcess', () {
      final out = emptyOutputs(64, 32); // stride 8: 8 cols × 4 rows
      const idx = 2 * 8 + 3; // r = 2, c = 3
      out['cls_8']![idx] = 0.81;
      out['obj_8']![idx] = 1.7; // clamped to 1
      out['bbox_8']!
        ..[idx * 4] = 0.5
        ..[idx * 4 + 1] = -0.25
        ..[idx * 4 + 2] = math.log(2)
        ..[idx * 4 + 3] = 0;
      for (var n = 0; n < 5; n++) {
        out['kps_8']![idx * 10 + 2 * n] = n * 0.1;
        out['kps_8']![idx * 10 + 2 * n + 1] = -n * 0.1;
      }
      final faces = FaceMath.decodeYunet(out, padWidth: 64, padHeight: 32);
      expect(faces, hasLength(1));
      final f = faces.single;
      expect(f.score, closeTo(0.9, 1e-6)); // sqrt(0.81 * 1)
      // cx = (3 + 0.5) * 8 = 28, cy = (2 - 0.25) * 8 = 14, w = 16, h = 8
      expect(f.x, closeTo(20, 1e-5));
      expect(f.y, closeTo(10, 1e-5));
      expect(f.width, closeTo(16, 1e-5));
      expect(f.height, closeTo(8, 1e-5));
      expect(f.landmarks[2].x, closeTo((0.2 + 3) * 8, 1e-5));
      expect(f.landmarks[2].y, closeTo((-0.2 + 2) * 8, 1e-5));
    });

    test('threshold is inclusive in decode, strict in NMS (>1 face)', () {
      final out = emptyOutputs(64, 64);
      // stride 32, anchor (0,0): score sqrt(0.36) == 0.6f, box (0,0,16,16).
      out['cls_32']![0] = 0.36;
      out['obj_32']![0] = 1;
      out['bbox_32']!
        ..[0] = 0.25
        ..[1] = 0.25
        ..[2] = math.log(0.5)
        ..[3] = math.log(0.5);
      final single = FaceMath.decodeYunet(out, padWidth: 64, padHeight: 64);
      expect(single, hasLength(1), reason: 'decode keeps score >= thr');

      // A second, far-away face triggers NMSBoxes, whose `score > thr`
      // drops the 0.6 face even though nothing overlaps it.
      out['cls_32']![3] = 0.81; // anchor (r 1, c 1)
      out['obj_32']![3] = 1;
      final two = FaceMath.decodeYunet(out, padWidth: 64, padHeight: 64);
      expect(two, hasLength(1));
      expect(two.single.score, closeTo(0.9, 1e-6));
    });

    test('overlapping faces are suppressed, best score first', () {
      final out = emptyOutputs(64, 64);
      out['cls_32']![0] = 0.64; // score 0.8, box (0,0,16,16)
      out['obj_32']![0] = 1;
      out['bbox_32']!
        ..[0] = 0.25
        ..[1] = 0.25
        ..[2] = math.log(0.5)
        ..[3] = math.log(0.5);
      out['cls_16']![0] = 0.81; // score 0.9, box (0,0,16,16)
      out['obj_16']![0] = 1;
      out['bbox_16']!
        ..[0] = 0.5
        ..[1] = 0.5;
      out['cls_8']![5 * 8 + 6] = 0.49; // score 0.7, anchor (r 5, c 6)
      out['obj_8']![5 * 8 + 6] = 1;
      final faces = FaceMath.decodeYunet(out, padWidth: 64, padHeight: 64);
      expect([for (final f in faces) f.score],
          [closeTo(0.9, 1e-6), closeTo(0.7, 1e-6)]);
    });
  });

  group('NMSBoxes matches cv::dnn::NMSBoxes', () {
    const boxes = [
      [37, 58, 30, 8], [47, 4, 28, 13], [32, -2, 9, 12], [45, -4, 24, 10], //
      [45, 43, 5, 39], [28, -6, 14, 28], [38, -9, 5, 21], [34, 13, 15, 5],
      [13, 11, 38, 8], [9, 17, 9, 24], [20, 47, 14, 34], [21, -8, 24, 23],
      [57, 48, 21, 17], [-1, 57, 19, 25],
    ];
    const scores = [
      0.989, 0.543, 0.69, 0.965, 0.615, 0.69, 0.602, 0.884, 0.655, 0.86, //
      0.672, 0.817, 0.546, 0.841,
    ];
    final scores32 = [for (final s in scores) FaceImageOps.toFloat32(s)];
    final cases = [
      (0.6, 0.3, 5000, [0, 3, 7, 9, 13, 11, 2, 10, 8, 4, 6]),
      (0.6, 0.3, 3, [0, 3, 7]),
      (0.7, 0.5, 0, [0, 3, 7, 9, 13, 11]),
    ];
    for (final (thr, nms, topK, expected) in cases) {
      test('thr $thr nms $nms topK $topK', () {
        expect(
          FaceMath.nmsBoxes(boxes, scores32,
              scoreThreshold: FaceImageOps.toFloat32(thr),
              nmsThreshold: FaceImageOps.toFloat32(nms),
              topK: topK),
          expected,
        );
      });
    }

    test('rectOverlap is IoU of integer rects', () {
      expect(FaceMath.rectOverlap([0, 0, 10, 10], [5, 0, 10, 10]),
          closeTo(50 / 150, 1e-6));
      expect(FaceMath.rectOverlap([0, 0, 10, 10], [20, 20, 5, 5]), 0);
    });
  });

  group('alignCrop matches FaceRecognizerSF::alignCrop', () {
    final image = _synth(160, 120);
    final cases = <String, (List<List<double>>, List<double>, (int, int))>{
      'upright': (
        [
          [60.3, 50.1],
          [95.7, 49.4],
          [78.2, 70.9],
          [63.5, 88.8],
          [93.1, 88.0]
        ],
        [
          1.0258334631,
          -0.0084377508,
          -23.567030454,
          0.0084377508,
          1.0258334631,
          0.007429794
        ],
        (4774574, 601330328),
      ),
      'tilted': (
        [
          [40.0, 60.0],
          [70.0, 42.0],
          [62.0, 66.0],
          [55.0, 88.0],
          [80.0, 74.0]
        ],
        [
          1.0194339755,
          -0.4896677817,
          25.7510252787,
          0.4896677817,
          1.0194339755,
          -25.4474423144
        ],
        (4629744, 584966247),
      ),
      'edge (partly outside the image)': (
        [
          [-5.0, 3.0],
          [25.0, 2.0],
          [10.0, 18.0],
          [-2.0, 30.0],
          [22.0, 31.0]
        ],
        [
          1.323256957,
          0.0053579025,
          42.7036170138,
          -0.0053579025,
          1.323256957,
          49.7236657695
        ],
        (1662765, 209462286),
      ),
      'mirrored (det < 0 branch)': (
        [
          [95.7, 49.4],
          [60.3, 50.1],
          [78.2, 70.9],
          [93.1, 88.0],
          [63.5, 88.8]
        ],
        [
          0.2016455658,
          0.0057450628,
          39.8666455424,
          -0.0057450628,
          0.2016455658,
          58.3475681127
        ],
        (299082, 37840964),
      ),
    };
    cases.forEach((name, c) {
      final (raw, expectedM, expectedDigest) = c;
      test(name, () {
        final m = FaceMath.similarityTransform(_pts(raw));
        for (var i = 0; i < 6; i++) {
          expect(m[i], closeTo(expectedM[i], 1e-8), reason: 'M[$i]');
        }
        final face = FaceDetection(
          x: 0,
          y: 0,
          width: 10,
          height: 10,
          landmarks: _pts(raw),
          score: 1,
        );
        final aligned = FaceMath.alignCrop(image, face);
        expect(aligned.width, 112);
        expect(aligned.height, 112);
        expect(_digest(aligned.data), expectedDigest);
      });
    });

    test('sfaceInput is RGB NCHW of the aligned crop', () {
      final face = FaceDetection(
        x: 0,
        y: 0,
        width: 10,
        height: 10,
        landmarks: _pts([
          [60.3, 50.1], [95.7, 49.4], [78.2, 70.9], [63.5, 88.8], //
          [93.1, 88.0],
        ]),
        score: 1,
      );
      final tensor = FaceImageOps.sfaceInput(FaceMath.alignCrop(image, face));
      const plane = 112 * 112;
      expect(tensor[0], 63); // R
      expect(tensor[plane], 15); // G
      expect(tensor[2 * plane], 163); // B
      expect(_digest(tensor), (4774574, 603284343));
      expect(
          () => FaceImageOps.sfaceInput(_synth(10, 10)), throwsArgumentError);
    });
  });

  group('embeddings', () {
    test('l2Normalize and cosineSimilarity', () {
      final n = FaceMath.l2Normalize([3, 4]);
      expect(n[0], closeTo(0.6, 1e-7));
      expect(n[1], closeTo(0.8, 1e-7));
      expect(FaceMath.l2Normalize([0, 0]), [0, 0]);
      expect(FaceMath.cosineSimilarity([1, 0], [0, 1]), 0);
      expect(FaceMath.cosineSimilarity([1, 2], [2, 4]), closeTo(1, 1e-12));
      expect(FaceMath.cosineSimilarity([1, 2], [-1, -2]), closeTo(-1, 1e-12));
      expect(() => FaceMath.cosineSimilarity([1], [1, 2]), throwsArgumentError);
    });

    test('filterSmallFaces and boxIou', () {
      FaceDetection box(double x, double y, double w, double h) =>
          FaceDetection(
            x: x,
            y: y,
            width: w,
            height: h,
            landmarks: const [],
            score: 1,
          );
      final faces = [box(0, 0, 50, 60), box(0, 0, 9, 9), box(0, 0, 40, 10)];
      // 4% of 250 = 10 → the 9×9 face goes.
      expect(FaceMath.filterSmallFaces(faces, 300, 250, 0.04), hasLength(2));
      expect(FaceMath.filterSmallFaces(faces, 300, 250, 0), hasLength(3));
      expect(FaceMath.boxIou(box(0, 0, 10, 10), box(5, 0, 10, 10)),
          closeTo(1 / 3, 1e-12));
    });

    test('detection maps back to original coordinates', () {
      final f = FaceDetection.fromOpenCvRow(
        [for (var i = 0; i < 15; i++) i.toDouble()],
      ).scaled(2, 3);
      expect(f.x, 0);
      expect(f.y, 3);
      expect(f.landmarks[0].x, 8);
      expect(f.landmarks[0].y, 15);
      expect(f.score, 14);
      expect(FaceDetection.fromMap(f.toMap()).toOpenCvRow(), f.toOpenCvRow());
    });
  });
}
