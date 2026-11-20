import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:photo_view/src/core/photo_view_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ota_counter/pages/album/album_models.dart';
import 'package:ota_counter/pages/album/album_viewer_page.dart';
import 'package:ota_counter/pages/album/album_widgets.dart';
import 'package:ota_counter/services/album_clarity_service.dart';

Uint8List _fixture(int red, {int width = 120, int height = 180}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(red, 210, 220));
  img.fillRect(image,
      x1: width ~/ 4,
      y1: height ~/ 4,
      x2: width ~/ 2,
      y2: height * 3 ~/ 4,
      color: img.ColorRgb8(180, 180, 180));
  return Uint8List.fromList(img.encodePng(image));
}

// A near-frame corner, slanted paper edges and a visible fragment of its
// neighbour reproduce the archived crop that a minimum-area box rejected.
Uint8List _tightCut({bool clipped = false, bool secondCard = false}) {
  final image = img.Image(width: clipped ? 389 : 417, height: 530);
  img.fill(image, color: img.ColorRgb8(54, 62, 57));
  void polygon(List<(int, int)> corners, img.Color color) => img.fillPolygon(
        image,
        vertices: [for (final (x, y) in corners) img.Point(x, y)],
        color: color,
      );
  polygon(
      [(0, 225), (18, 221), (51, 500), (0, 505)], img.ColorRgb8(194, 187, 176));
  polygon([(20, 49), (306, 23), (411, 485), (117, 511)],
      img.ColorRgb8(204, 205, 201));
  polygon(
      [(51, 85), (283, 63), (358, 395), (122, 420)], img.ColorRgb8(46, 44, 49));
  img.fillRect(image,
      x1: 147, y1: 456, x2: 247, y2: 466, color: img.ColorRgb8(46, 151, 205));
  img.fillRect(image,
      x1: 102, y1: 57, x2: 177, y2: 62, color: img.ColorRgb8(197, 62, 77));
  if (secondCard) {
    img.fillRect(image,
        x1: 343, y1: 8, x2: 413, y2: 120, color: img.ColorRgb8(214, 211, 206));
    img.fillRect(image,
        x1: 350, y1: 18, x2: 406, y2: 99, color: img.ColorRgb8(49, 44, 46));
  }
  return Uint8List.fromList(img.encodePng(image));
}

ImageProvider _provider(WidgetTester tester, int index) {
  final gallery =
      tester.widget<PhotoViewGallery>(find.byType(PhotoViewGallery));
  return (gallery.builder!(tester.element(find.byType(PhotoViewGallery)), index)
          .child as Image)
      .image;
}

Future<void> _wait(WidgetTester tester, {bool processing = true}) async {
  for (var i = 0; i < 500; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        (!processing || find.text('清晰处理中').evaluate().isEmpty)) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
      'local detail and contrast increase; skin chroma, white, alpha and input stay intact',
      () {
    const w = 21, h = 9;
    final rgba = Uint8List(w * h * 4);
    for (var p = 0; p < w * h; p++) {
      final value = p % w == 10 ? 218 : 245;
      rgba.setRange(p * 4, p * 4 + 4, [
        value,
        value + (value == 218 ? 7 : 0),
        value + (value == 218 ? 10 : 0),
        255
      ]);
    }
    rgba.setRange(0, 4, [255, 255, 255, 255]);
    rgba.setRange(4, 8, [224, 180, 156, 255]);
    rgba.setRange(8, 12, [24, 36, 48, 128]);
    final before = Uint8List.fromList(rgba);
    final enhanced = enhanceAlbumRgba(rgba, w, h);
    expect(rgba, before);
    expect(enhanced.sublist(0, 4), [255, 255, 255, 255]);
    expect(enhanced.sublist(8, 12), rgba.sublist(8, 12));
    expect(enhanced[4] - enhanced[5], rgba[4] - rgba[5]);
    expect(enhanced[5] - enhanced[6], rgba[5] - rgba[6]);
    final ink = (4 * w + 10) * 4, paper = (4 * w + 6) * 4;
    expect(
        enhanced[paper] - enhanced[ink], greaterThan(rgba[paper] - rgba[ink]));
    for (var i = 0; i < rgba.length; i += 4) {
      expect(enhanced[i] - enhanced[i + 1], rgba[i] - rgba[i + 1]);
      expect(enhanced[i + 1] - enhanced[i + 2], rgba[i + 1] - rgba[i + 2]);
      expect(enhanced[i + 3], rgba[i + 3]);
      expect((enhanced[i] - rgba[i]).abs(), lessThanOrEqualTo(10));
    }
  });

  test('unavailable direction detector does not cache an undecided scan',
      () async {
    final dir = await Directory.systemTemp.createTemp('album_scan_retry_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/landscape.png';
    final bytes = _fixture(194, width: 136, height: 86);
    await File(path).writeAsBytes(bytes);
    // The host has no Android ONNX/path provider. This must not be
    // persisted as a successful decision to keep the landscape direction.
    expect(await AlbumPhotoFiles.prepare(path, rectifyCut: false, isScan: true),
        isNull);
    expect(await dir.list().map((entry) => entry.path).toList(), [path]);
  });

  test(
      'cache is bounded, original bytes stay identical, and latest queued photo wins',
      () async {
    final dir = await Directory.systemTemp.createTemp('album_clarity_test_');
    final service = AlbumClarityService();
    addTearDown(() {
      service.dispose();
      dir.deleteSync(recursive: true);
    });
    final paths = <String>[];
    for (var i = 0; i < 4; i++) {
      final file = File('${dir.path}/$i.png');
      await file.writeAsBytes(_fixture(100 + i * 20));
      paths.add(file.path);
    }
    final bytes = await File(paths.first).readAsBytes();
    final first = await service.prepare(paths.first);
    expect(identical(first, await service.prepare(paths.first)), true);
    final stale = service.prepare(paths[1]);
    final newest = service.prepare(paths[2]);
    expect(await stale, isNull);
    expect((await newest)!.sourcePath, paths[2]);
    await service.prepare(paths[3]);
    expect(service.cachedImages, lessThanOrEqualTo(2));
    expect(service.cachedBytes,
        lessThanOrEqualTo(AlbumClarityService.maxCacheBytes));
    expect(await File(paths.first).readAsBytes(), bytes);
  });

  testWidgets(
      'viewer opens optimized despite old preference; original is a temporary comparison',
      (tester) async {
    SharedPreferences.setMockInitialValues({'cheki_album_clarity': false});
    final dir = await tester
        .runAsync(() => Directory.systemTemp.createTemp('album_clarity_view_'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    final paths = ['${dir!.path}/a.png', '${dir.path}/b.png'];
    await tester.runAsync(() async {
      await File(paths[0]).writeAsBytes(_fixture(240));
      await File(paths[1]).writeAsBytes(_fixture(70));
    });
    final photos = [
      for (var i = 0; i < paths.length; i++)
        AlbumPhoto(
            mediaId: i,
            path: paths[i],
            isScan: false,
            processingLabel: '原图',
            mediaLabel: '纪念照',
            specLabel: '切图',
            sessionKey: 'generated')
    ];
    Widget app() => MaterialApp(home: AlbumViewerPage(photos: photos));
    await tester.pumpWidget(app());
    await _wait(tester);
    expect(find.text('清晰'), findsOneWidget);
    expect(_provider(tester, 0), isA<AlbumClarityImage>());
    final core = tester.widget<PhotoViewCore>(find.byType(PhotoViewCore).first);
    final originalScale = core.controller.scale!;
    // Exercise the actual two-finger gesture, not just the presence of PhotoView.
    final center = tester.getCenter(find.byType(PhotoViewCore).first);
    final left =
        await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final right =
        await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await left.moveTo(center - const Offset(90, 0));
    await right.moveTo(center + const Offset(90, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(core.controller.scale, greaterThan(originalScale * 1.2));
    // Restore contained scale so the next horizontal swipe can turn the page.
    core.controller.scale = originalScale;
    core.controller.position = Offset.zero;
    await tester.pump();
    await tester.fling(find.byType(PageView), const Offset(-600, 0), 1200);
    await _wait(tester);
    final provider = _provider(tester, 1) as AlbumClarityImage;
    expect(provider.sourcePath, paths[1]);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byType(PhotoView), findsWidgets);
    await tester.tap(find.text('清晰'));
    await _wait(tester);
    expect(_provider(tester, 1), FileImage(File(paths[1])));
    // Cancel while an enhancement is being scheduled: no late clear frame may
    // overwrite the original or install the first photo on the second page.
    await tester.tap(find.text('原色'));
    await tester.pump();
    await tester.tap(find.text('清晰处理中'));
    await _wait(tester);
    expect(_provider(tester, 1), FileImage(File(paths[1])));
    // Reopening resets the comparison to the default, optimized rendition.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await _wait(tester);
    expect(find.text('清晰'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'fresh viewer straightens a tight raw cut; clipped, two-card and ordinary photos keep full frame',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('album_tight_cut_')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final original = _tightCut();
    final paths = [
      for (final file in ['cut.png', 'clipped.png', 'memory.png', 'two.png'])
        '${dir.path}/$file',
    ];
    await tester.runAsync(() async {
      await File(paths[0]).writeAsBytes(original);
      await File(paths[1]).writeAsBytes(_tightCut(clipped: true));
      await File(paths[2]).writeAsBytes(original);
      await File(paths[3]).writeAsBytes(_tightCut(secondCard: true));
    });
    await tester.pumpWidget(MaterialApp(
        home: AlbumViewerPage(photos: [
      for (var i = 0; i < paths.length; i++)
        AlbumPhoto(
          path: paths[i],
          isScan: i != 2,
          canAutoRectify: i != 2,
          mediaLabel: i != 2 ? '切图' : '纪念照',
          processingLabel: '原图',
          specLabel: '3寸 1',
        ),
    ])));
    await _wait(tester);
    expect(find.text('清晰'), findsOneWidget);
    expect(find.text('切图 · 已校正'), findsOneWidget);
    final card = _provider(tester, 0) as AlbumClarityImage;
    expect(card.rectified, true);
    expect(card.width / card.height, closeTo(54 / 86, 0.003));
    var topRed = 0, bottomBlue = 0;
    for (var y = 0; y < card.height; y++) {
      for (var x = 0; x < card.width; x++) {
        final i = (y * card.width + x) * 4;
        final r = card.rgba[i], g = card.rgba[i + 1], b = card.rgba[i + 2];
        if (y < card.height * .08 && r > g + 80) topRed++;
        if (y > card.height * .80 && b > r + 80) bottomBlue++;
      }
    }
    expect(topRed, greaterThan(150));
    expect(bottomBlue, greaterThan(250));
    final imgRect = tester.getRect(
        find.byWidgetPredicate((w) => w is Image && identical(w.image, card)));
    expect(
        imgRect.bottom, lessThan(tester.getTopLeft(find.text('切图 · 已校正')).dy));
    final core = tester.widget<PhotoViewCore>(find.byType(PhotoViewCore).first);
    final center = tester.getCenter(find.byType(PhotoViewCore).first);
    final left = await tester.startGesture(center - const Offset(40, 0));
    final right = await tester.startGesture(center + const Offset(40, 0));
    final contained = core.controller.scale!;
    await tester.pump();
    await left.moveTo(center - const Offset(90, 0));
    await right.moveTo(center + const Offset(90, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(core.controller.scale, greaterThan(contained * 1.2));

    await tester.tap(find.text('清晰'));
    await _wait(tester);
    expect(find.text('切图 · 原图'), findsOneWidget);
    expect(_provider(tester, 0), FileImage(File(paths[0])));
    final restored =
        tester.widget<PhotoViewCore>(find.byType(PhotoViewCore).first);
    expect(core.controller.scale,
        closeTo(restored.scaleBoundaries.initialScale, 0.001));
    expect(
        tester
            .getRect(find.byWidgetPredicate(
                (w) => w is Image && w.image == FileImage(File(paths[0]))))
            .bottom,
        lessThan(tester.getTopLeft(find.text('切图 · 原图')).dy));
    expect(core.controller.position, Offset.zero);
    expect(await tester.runAsync(() => File(paths[0]).readAsBytes()), original);
    await tester.tap(find.text('原色'));
    await _wait(tester);

    final gallery =
        tester.widget<PhotoViewGallery>(find.byType(PhotoViewGallery));
    for (final i in [1, 2, 3]) {
      gallery.pageController!.jumpToPage(i);
      await _wait(tester);
      expect(find.text('清晰'), findsOneWidget);
      expect(find.text('切图 · 已校正'), findsNothing);
      final full = _provider(tester, i) as AlbumClarityImage;
      expect(full.sourcePath, paths[i]);
      expect(full.rectified, false);
      expect(full.width, i == 1 ? 389 : 417);
      expect(full.height, 530);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('captions sit below an already cut portrait in both modes',
      (tester) async {
    tester.view.physicalSize = const Size(400, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('album_caption_')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final photo = File('${dir.path}/cut.png');
    await tester.runAsync(
        () => photo.writeAsBytes(_fixture(80, width: 240, height: 480)));
    await tester.pumpWidget(MaterialApp(
        home: AlbumViewerPage(photos: [
      AlbumPhoto(
        path: photo.path,
        isScan: true,
        mediaLabel: '切图',
        processingLabel: '原图',
        specLabel: '3寸 1',
        activityName: '示例演出 Vol.16 三周年特别公演',
        venueName: '某场馆 The Venue',
      ),
    ])));

    await _wait(tester);
    for (final mode in ['清晰', '原色']) {
      expect(find.text(mode), findsOneWidget);
      final picture = find.byKey(ValueKey(photo.path));
      expect(tester.getBottomLeft(picture).dy,
          lessThan(tester.getTopLeft(find.text('未归属')).dy));
      expect(tester.getTopLeft(picture).dy,
          greaterThan(tester.getBottomLeft(find.text(mode)).dy));
      if (mode == '清晰') {
        await tester.tap(find.text(mode));
        await _wait(tester);
      }
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'one unreadable photo falls back without disabling the next photo',
      (tester) async {
    final dir = await tester
        .runAsync(() => Directory.systemTemp.createTemp('clarity_fallback_'));
    addTearDown(() => dir!.deleteSync(recursive: true));
    final path = '${dir!.path}/valid.png';
    await tester.runAsync(() => File(path).writeAsBytes(_fixture(220)));
    SharedPreferences.setMockInitialValues({'cheki_album_clarity': true});
    await tester.pumpWidget(MaterialApp(
        home: AlbumViewerPage(photos: [
      for (final file in ['${dir.path}/unreadable.png', path])
        AlbumPhoto(
            path: file,
            isScan: false,
            mediaLabel: '切图',
            specLabel: '切图',
            sessionKey: 'fallback'),
    ])));
    await _wait(tester);
    expect(find.text('原色 · 未增强'), findsOneWidget);
    final gallery =
        tester.widget<PhotoViewGallery>(find.byType(PhotoViewGallery));
    gallery.pageController!.jumpToPage(1);
    await _wait(tester);
    expect(find.text('清晰'), findsOneWidget);
    final provider = _provider(tester, 1) as AlbumClarityImage;
    expect(provider.sourcePath, path);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'album thumbnail uses the saved rectification, never the raw slant',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('album_thumb_')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/cut.png';
    final source = _tightCut();
    await tester.runAsync(() => File(path).writeAsBytes(source));
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 200,
          height: 300,
          child: AlbumPhotoThumb(
            photo: AlbumPhoto(
              path: path,
              isScan: true,
              canAutoRectify: true,
              mediaLabel: '切图',
              specLabel: '3寸 1',
            ),
          ),
        ),
      ),
    ));
    // A historical photo awaiting processing should not briefly show its
    // crooked source; the first image widget must already use the rendition.
    expect(find.byType(Image), findsNothing);
    for (var i = 0; i < 100 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final image = tester.widget<Image>(find.byType(Image));
    final file = (image.image as ResizeImage).imageProvider as FileImage;
    final saved = await tester
        .runAsync(() => AlbumPhotoFiles.prepare(path, rectifyCut: true));
    expect(saved!.rectified, isTrue);
    expect(file.file.path, saved.thumbnail.path);
    expect(file.file.path, isNot(path));
    expect(image.fit, BoxFit.contain);
    expect(await tester.runAsync(() => File(path).readAsBytes()), source);
    await tester.pumpWidget(const SizedBox());
  });
  test('archive preparation also completes an offscreen attachment', () async {
    final dir = await Directory.systemTemp.createTemp('album_warm_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/offscreen.png';
    final bytes = _fixture(105, width: 250, height: 480);
    await File(path).writeAsBytes(bytes);
    AlbumPhotoFiles.warmScans([(path, false)]);
    final cache = Directory('${dir.path}/.album-optimized-v4/offscreen.png');
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    bool completed = false;
    while (!completed && DateTime.now().isBefore(deadline)) {
      completed = await cache.exists() &&
          await cache.list().any((e) => e.path.endsWith('-full.png'));
      if (!completed) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    expect(completed, isTrue);
    expect(await File(path).readAsBytes(), bytes);
  });

  testWidgets('a wide scan uses a small rendition and its paper hugs the image',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('album_wide_')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/square.png';
    await tester.runAsync(
        () => File(path).writeAsBytes(_fixture(125, width: 860, height: 900)));
    await tester.pumpWidget(MaterialApp(
        home: Center(
      child: SizedBox(
        width: 240,
        height: 420,
        child: AlbumPhotoTile(
          photo: AlbumPhoto(
              path: path, isScan: true, mediaLabel: '切图', specLabel: '三寸'),
          onTap: () {},
        ),
      ),
    )));
    for (var i = 0; i < 200 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final picture = find.byType(Image);
    expect(picture, findsOneWidget);
    final image = tester.widget<Image>(picture);
    final rendition = (await tester.runAsync(
        () => AlbumPhotoFiles.prepare(path, rectifyCut: false, isScan: true)))!;
    final file = (image.image as ResizeImage).imageProvider as FileImage;
    expect(file.file.path, rendition.thumbnail.path);
    expect(rendition.thumbnail.path, isNot(rendition.file.path));
    expect(tester.getSize(picture).aspectRatio, closeTo(860 / 900, .02));
    expect(tester.getTopLeft(find.byType(AlbumPrintCaption)).dy,
        closeTo(tester.getBottomLeft(picture).dy, .5));
    expect(image.fit, BoxFit.contain);
    await tester.pumpWidget(const SizedBox());
  });

}
