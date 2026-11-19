import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ota_counter/pages/album/album_models.dart';
import 'package:ota_counter/pages/album/album_widgets.dart';
import 'package:ota_counter/services/album_clarity_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'visible attachment switches from its existing render to a camera rescan without changing the archive',
      (tester) async {
    final folder = Directory.systemTemp.createTempSync('album-camera-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final path = '${folder.path}/old.png';
    final source = img.encodePng(img.Image(width: 260, height: 260));
    File(path).writeAsBytesSync(source);
    final photo =
        AlbumPhoto(path: path, isScan: true, mediaLabel: '切图', specLabel: '3寸');
    await tester.pumpWidget(MaterialApp(home: AlbumPhotoThumb(photo: photo)));
    final old = await tester.runAsync(
        () => AlbumPhotoFiles.prepare(path, rectifyCut: false, isScan: true));
    expect(old!.file.path, isNot(contains('.album-camera-')));
    final recovered = img.Image(width: 270, height: 430);
    img.fill(recovered, color: img.ColorRgb8(201, 197, 208));
    img.fillRect(recovered,
        x1: 18, y1: 25, x2: 251, y2: 333, color: img.ColorRgb8(38, 40, 44));
    await tester.runAsync(() async {
      await AlbumPhotoFiles.saveCameraScan(path, await File(path).stat(),
          Uint8List.fromList(img.encodeJpg(recovered)));
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    final selected = await tester.runAsync(
        () => AlbumPhotoFiles.prepare(path, rectifyCut: false, isScan: true));
    expect((selected!.width, selected.height), (270, 430));
    final provider =
        tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect((provider.imageProvider as FileImage).file.path,
        selected.thumbnail.path);
    expect(selected.rectified, isTrue);
    expect(selected.file.path, contains('.album-camera-'));
    expect(File(path).readAsBytesSync(), source);
  });
}
