import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/services/album_orientation_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/record_scan_service.dart';

void main() {
  test('a sideways portrait wins only with a strong unique upright direction',
      () async {
    Future<int> choose(double original, double left, double right) =>
        AlbumOrientationService.choose(
            (angle) async => {0: original, -90: left, 90: right}[angle]!);
    expect(await choose(.67, .89, .57), -90);
    expect(await choose(0, .835, 0), -90);
    expect(await choose(0, .35, .89), 90);
    expect(await choose(.87, .93, 0), 0);
    expect(await choose(.72, .94, 0), 0);
    expect(await choose(.60, .87, .83), 0);
    expect(await choose(0, 0, 0), 0);
    expect(
        await AlbumOrientationService.choose(
            (angle) async => angle == 180 ? .89 : .2,
            alternatives: const [180]),
        180);
  });

  test('only a side signature margin with supported window rails hints a turn',
      () {
    img.Image print(
        {required int left, required int right, required int bottom}) {
      final paper = img.Image(width: 336, height: 240)
        ..clear(img.ColorRgb8(200, 214, 212));
      return img.fillRect(paper,
          x1: left,
          y1: 24,
          x2: 335 - right,
          y2: 239 - bottom,
          color: img.ColorRgb8(40, 49, 55));
    }

    final sideways = print(left: 78, right: 28, bottom: 24);
    expect(RecordScanService.sidewaysPrintHint(sideways), -90);
    expect(
        RecordScanService.sidewaysPrintHint(
            img.copyRotate(sideways, angle: 180)),
        90);
    expect(
        RecordScanService.sidewaysPrintHint(
            print(left: 28, right: 28, bottom: 53)),
        isNull);
    // Losing another rim must not make a lone thick margin sufficient.
    img.fillRect(sideways,
        x1: 78, y1: 215, x2: 307, y2: 239, color: img.ColorRgb8(40, 49, 55));
    expect(RecordScanService.sidewaysPrintHint(sideways), isNull);
  });

  test('upright landmark checks exclude sideways and inverted detections', () {
    FaceDetection face(List<FacePoint> points, double score) => FaceDetection(
        x: 0, y: 0, width: 30, height: 30, landmarks: points, score: score);
    const landmarks = [
      FacePoint(6, 8),
      FacePoint(19, 9),
      FacePoint(12, 15),
      FacePoint(6, 23),
      FacePoint(18, 23),
    ];
    final side =
        face(landmarks.map((p) => FacePoint(30 - p.y, p.x)).toList(), .99);
    final inverted =
        face(landmarks.map((p) => FacePoint(30 - p.x, 30 - p.y)).toList(), .99);
    expect(AlbumOrientationService.uprightScore([side, inverted]), 0);
    expect(
        AlbumOrientationService.uprightScore(
            [side, face(landmarks, .85), inverted]),
        .85);
    expect(AlbumOrientationService.isLandscapeCard(372, 234), true);
    expect(AlbumOrientationService.isLandscapeCard(342, 215), true);
    expect(AlbumOrientationService.isLandscapeCard(234, 372), false);
    expect(AlbumOrientationService.isLandscapeCard(540, 180), false);
  });
}
