import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await useIsolatedTestDatabases();
  });

  for (final recognition in [false, true]) {
    test(
      'original gallery EXIF survives processing, recognition=$recognition',
      () async {
        final image = img.Image(width: 96, height: 128);
        image.exif.exifIfd[0x9003] = '2026:11:15 02:03:04';
        final bytes = Uint8List.fromList(img.encodeJpg(image));
        final file = File('${directory.path}/original-$recognition.jpg');
        await file.writeAsBytes(bytes);
        // File metadata must never replace the original shot's EXIF date.
        await file.setLastModified(DateTime(2026, 11, 17));
        final source = BatchSourcePhoto(
          path: file.path,
          capturedAt: null,
          fromCamera: false,
        );
        var analyzed = 0;
        final result = await BatchImportService.processPhoto(
          source,
          analyzer: recognition
              ? (_) async {
                  analyzed++;
                  return [];
                }
              : null,
        );
        expect(result.error, isNull);
        expect(result.photo.capturedAt, DateTime(2026, 11, 15, 2, 3, 4));
        expect(activityDayOf(result.photo.capturedAt!), DateTime(2026, 11, 14));
        expect(result.photo.path, source.path);
        expect(result.photo.fromCamera, isFalse);
        expect(source.capturedAt, isNull);
        expect(result.sourceHash, sha1.convert(bytes).toString());
        expect(
          await BatchImportService.sha1OfFile(file.path),
          result.sourceHash,
        );
        expect(
          await BatchImportService.readExifCaptureTimeFromFile(file.path),
          result.photo.capturedAt,
        );
        expect(analyzed, recognition ? result.cards.length : 0);
      },
    );
  }

  for (final fromCamera in [false, true]) {
    test('supplied capture time wins over EXIF, camera=$fromCamera', () async {
      final image = img.Image(width: 96, height: 128);
      image.exif.exifIfd[0x9003] = '2026:11:15 02:03:04';
      final file = File('${directory.path}/supplied-$fromCamera.jpg');
      await file.writeAsBytes(img.encodeJpg(image));
      final supplied = DateTime(2026, 11, 16, 23, 59);
      final result = await BatchImportService.processPhoto(
        BatchSourcePhoto(
          path: file.path,
          capturedAt: supplied,
          fromCamera: fromCamera,
        ),
      );
      expect(result.error, isNull);
      expect(result.photo.capturedAt, supplied);
    });
  }

  test('camera without supplied time does not borrow EXIF', () async {
    final image = img.Image(width: 96, height: 128);
    image.exif.exifIfd[0x9003] = '2026:11:15 02:03:04';
    final file = File('${directory.path}/camera.jpg');
    await file.writeAsBytes(img.encodeJpg(image));
    final result = await BatchImportService.processPhoto(
      BatchSourcePhoto(path: file.path, capturedAt: null, fromCamera: true),
    );
    expect(result.error, isNull);
    expect(result.photo.capturedAt, isNull);
  });

  test('gallery without EXIF remains undated', () async {
    final file = File('${directory.path}/no-exif.jpg');
    await file.writeAsBytes(img.encodeJpg(img.Image(width: 96, height: 128)));
    final result = await BatchImportService.processPhoto(
      BatchSourcePhoto(path: file.path, capturedAt: null, fromCamera: false),
    );
    expect(result.error, isNull);
    expect(result.photo.capturedAt, isNull);
  });
}
