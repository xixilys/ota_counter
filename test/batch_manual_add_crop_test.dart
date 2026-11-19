import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/pages/batch_capture_page.dart';
import 'package:ota_counter/pages/batch_review_page.dart';
import 'package:ota_counter/pages/manual_scan_crop_page.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/face/face_models.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';
import 'package:ota_counter/services/record_scan_service.dart';

import 'support/isolated_test_databases.dart';

const _member = FaceMember(counterId: 1, name: '甲', groupName: '一团');
final _day = BatchDayContext(
  day: DateTime(2026, 11, 16),
  records: const [],
  sessions: const [],
  dayMembers: const [_member],
  counters: const [],
);

class _MissingPhotoPicker extends ImagePickerPlatform {
  final String path;
  _MissingPhotoPicker(this.path);
  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async =>
      [XFile(path)];
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 500; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      if (condition()) return;
    }
    fail('timed out waiting for asynchronous UI work');
  });
  await tester.pumpAndSettle();
}

BatchReviewCard _tileCard(WidgetTester tester, int index) =>
    (tester.widget(find.byKey(ValueKey('batch_card_$index'))) as dynamic).card
        as BatchReviewCard;

void main() {
  late Directory dir;
  String? previewFont;
  final preview = Platform.environment['OTA_BATCH_CROP_OUT'];
  setUpAll(() async {
    dir = await useIsolatedTestDatabases();
    SharedPreferences.setMockInitialValues({});
    final font = File('tool/ui_preview/PingFangSC-Preview.ttf');
    if (preview != null && font.existsSync()) {
      final loader = FontLoader('BatchPreview')
        ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(
            await rootBundle.load('fonts/MaterialIcons-Regular.otf')));
      await icons.load();
      previewFont = 'BatchPreview';
    }
  });

  BatchSourceResult source(String name) {
    final image = img.Image(width: 400, height: 600);
    img.fill(image, color: img.ColorRgb8(34, 38, 48));
    for (var i = 0; i < 2; i++) {
      final x = 30 + i * 190, y = 35 + i * 275;
      img.fillRect(image,
          x1: x,
          y1: y,
          x2: x + 150,
          y2: y + 240,
          color: img.ColorRgb8(244, 240, 236));
      img.fillRect(image,
          x1: x + 12,
          y1: y + 12,
          x2: x + 138,
          y2: y + 190,
          color: img.ColorRgb8(80 + i * 60, 110, 160));
      img.drawString(image, 'CARD ${i + 1}',
          font: img.arial14,
          x: x + 20,
          y: y + 210,
          color: img.ColorRgb8(40, 40, 40));
    }
    final file = File('${dir.path}/$name.jpg');
    file.writeAsBytesSync(img.encodeJpg(image));
    return BatchSourceResult(
      photo: BatchSourcePhoto(
          path: file.path,
          capturedAt: DateTime(2026, 11, 16),
          fromCamera: false),
      sourceHash: name,
      cards: const [],
      sourceWidth: 400,
      sourceHeight: 600,
    );
  }

  Future<void> showReview(
    WidgetTester tester, {
    List<BatchReviewCard> cards = const [],
    List<BatchSourceResult> sources = const [],
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, fontFamily: previewFont),
      home: BatchReviewPage(
          cards: cards,
          sources: sources,
          day: _day,
          session: null,
          candidates: const [_member],
          allMembers: const [_member]),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (preview == null) return;
    Directory(preview).createSync(recursive: true);
    await _until(
        tester,
        () => find
            .byType(RawImage)
            .evaluate()
            .every((e) => (e.widget as RawImage).image != null));
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('$preview/$name.png'));
  }

  Future<void> generate(WidgetTester tester, int count) async {
    await tester.tap(find.text('生成切图'));
    await _until(
        tester,
        () =>
            find.text('复核 $count 张').evaluate().isNotEmpty &&
            find.text('处理中…').evaluate().isEmpty);
  }

  testWidgets(
      'one source adds an unconfirmed crop without touching recognised cards',
      (tester) async {
    final original = source('one');
    final originalBytes = File(original.photo.path).readAsBytesSync();
    final face = FaceAnalysis(
      face: FaceDetection(
          x: 0, y: 0, width: 10, height: 10, score: .9, landmarks: const []),
      embedding: Float32List.fromList([1, 0]),
    );
    final oldCard = BatchCard(
      bytes: originalBytes,
      fileExtension: '.jpg',
      processingMode: ActivityRecordMediaProcessingMode.antiGlareBasic,
      quad: const RecordScanQuad(
          topLeftX: 30,
          topLeftY: 35,
          topRightX: 180,
          topRightY: 35,
          bottomLeftX: 30,
          bottomLeftY: 275,
          bottomRightX: 180,
          bottomRightY: 275),
      sizeClass: RecordScanCardSize.mini,
      confidence: 1,
      splitFromMerged: false,
      faces: [face],
    );
    final recognizedSource = BatchSourceResult(
      photo: original.photo,
      sourceHash: original.sourceHash,
      cards: [oldCard],
      sourceWidth: 400,
      sourceHeight: 600,
    );
    final existing = BatchReviewCard(
        source: recognizedSource,
        card: oldCard,
        members: [_member],
        status: FaceMatchStatus.auto,
        suggestions: [_member],
        size: ChekiSize.threeInch,
        sizeUncertain: false,
        faceMatches: [(face: face, member: _member)]);
    final inputCards = [existing];
    // Backwards-compatible callers can supply cards without a sources argument.
    await showReview(tester, cards: inputCards);
    await capture(tester, 'review-add-entry');
    await tester.tap(find.byKey(const ValueKey('batch_add_crop')));
    await _until(
        tester, () => find.byType(ManualScanCropPage).evaluate().isNotEmpty);
    expect(find.text('选择要补框的原图'), findsNothing);
    final draft = tester
        .widget<ManualScanCropPage>(find.byType(ManualScanCropPage))
        .draft;
    final handles = find.byWidgetPredicate(
        (w) => w is GestureDetector && w.onPanUpdate != null);
    expect(handles, findsNWidgets(4));
    await tester.drag(handles.first, const Offset(15, 10));
    await generate(tester, 2);
    final added = _tileCard(tester, 1);
    expect(added.source, same(recognizedSource));
    expect(added.status, FaceMatchStatus.unknown);
    expect(added.members, isEmpty);
    expect(added.suggestions, isEmpty);
    expect(added.card.faces, isEmpty);
    expect(added.faceMatches, isEmpty);
    expect(added.confirmedFaces, isEmpty);
    expect(added.sizeUncertain, isTrue);
    expect(added.quad.topLeftX, greaterThan(draft.suggestedQuad.topLeftX));
    expect(added.quad.topLeftY, greaterThan(draft.suggestedQuad.topLeftY));
    expect(_tileCard(tester, 0), same(existing));
    expect(existing.status, FaceMatchStatus.auto);
    expect(existing.members, [_member]);
    expect(existing.confirmedFaces.single.face, same(face));
    expect(existing.bytes, orderedEquals(originalBytes));
    expect(inputCards, [existing]);
    expect(recognizedSource.cards, [oldCard]);
    expect(File(original.photo.path).readAsBytesSync(),
        orderedEquals(originalBytes));
    expect(find.text('保存 1 张，跳过 1 张待核对'), findsOneWidget);
    await capture(tester, 'review-added-pending');
  });

  testWidgets(
      'zero-card sources are selectable; cancelling does not add a card',
      (tester) async {
    final a = source('first');
    final b = source('missed');
    await showReview(tester, sources: [a, b]);
    expect(find.textContaining('点右上角“补框”'), findsOneWidget);
    await capture(tester, 'review-zero-cards');
    await tester.tap(find.byKey(const ValueKey('batch_add_crop')));
    await tester.pumpAndSettle();
    expect(find.text('选择要补框的原图'), findsOneWidget);
    await capture(tester, 'review-source-picker');
    await tester.tap(find.byKey(const ValueKey('batch_crop_source_1')));
    await _until(
        tester, () => find.byType(ManualScanCropPage).evaluate().isNotEmpty);
    final draft = tester
        .widget<ManualScanCropPage>(find.byType(ManualScanCropPage))
        .draft;
    expect(
        draft.sourceBytes, orderedEquals(File(b.photo.path).readAsBytesSync()));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('复核 0 张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('batch_add_crop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('batch_crop_source_1')));
    await _until(
        tester, () => find.byType(ManualScanCropPage).evaluate().isNotEmpty);
    await generate(tester, 1);
    final added = _tileCard(tester, 0);
    expect(added.source, same(b));
    expect(added.status, FaceMatchStatus.unknown);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('batch_save')))
            .onPressed,
        isNull);
    await tester.tap(find.text('点这里指定成员'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('member_${_member.key}')));
    await tester.tap(find.byKey(const ValueKey('member_picker_done')));
    await tester.pumpAndSettle();
    expect(added.status, FaceMatchStatus.auto);
    expect(added.confirmedFaces, isEmpty,
        reason: 'manual assignment cannot learn an old embedding');
  });

  testWidgets(
      'missing original reports a read error and leaves review unchanged',
      (tester) async {
    final missing = BatchSourceResult(
      photo: BatchSourcePhoto(
          path: '${dir.path}/missing.jpg', capturedAt: null, fromCamera: false),
      sourceHash: 'missing',
      cards: const [],
      sourceWidth: 400,
      sourceHeight: 600,
    );
    await showReview(tester, sources: [missing]);
    await tester.tap(find.byKey(const ValueKey('batch_add_crop')));
    await _until(tester,
        () => find.textContaining('补框失败，无法读取或裁切原图').evaluate().isNotEmpty);
    expect(find.byType(ManualScanCropPage), findsNothing);
    expect(find.text('复核 0 张'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('batch_add_crop')))
            .onPressed,
        isNotNull);
  });

  testWidgets('capture keeps a readable failure prompt when all originals fail',
      (tester) async {
    final previousPicker = ImagePickerPlatform.instance;
    final previousCamera = BatchCapturePage.cameraEnabled;
    ImagePickerPlatform.instance =
        _MissingPhotoPicker('${dir.path}/absent.jpg');
    BatchCapturePage.cameraEnabled = false;
    addTearDown(() {
      ImagePickerPlatform.instance = previousPicker;
      BatchCapturePage.cameraEnabled = previousCamera;
    });
    await tester.pumpWidget(const MaterialApp(home: BatchCapturePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('从相册多选'));
    await _until(
        tester, () => find.byIcon(Icons.error_outline).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('batch_next')));
    await _until(
        tester, () => find.text('照片读取或处理失败，请重试或重新选择').evaluate().isNotEmpty);
    expect(find.byType(BatchReviewPage), findsNothing);
  });
}
