// End-to-end 批量拍切 on a device / emulator: gallery multi-pick → cut →
// on-device face recognition → review → save → home + member detail.
//
// Not self-contained on purpose (real cheki photos must not live in the
// repo). The photos come from a local HTTP server over `adb reverse`:
//   1. put these archived scans of the owner's backup in <dir>
//      (faceeval/backup/extracted/documents/activity_record_media/):
//      samples   小树 1773885784219256_4.jpg, 1774012408732238_7.jpg
//                小雪 1774590788600669_156.jpg, 1774627210654312_158.jpg
//      batch     小树 1774162317339650_150.jpg, 1774186906528695_154.jpg,
//                     1774186941318385_154.jpg
//                小雪 1774627238507906_158.jpg
//   2. python3 -m http.server 8766 --bind 127.0.0.1 -d <dir>
//      adb -s emulator-5554 reverse tcp:8766 tcp:8766
//   3. flutter test integration_test/batch_import_flow_test.dart \
//        -d emulator-5554
//
// The system photo picker is another app and cannot be driven from a
// Flutter test, so ImagePickerPlatform is replaced by a fake that returns
// files the test writes: one synthetic desk photo with three polaroids laid
// out on a dark table, plus one real photo as-is. Everything after the
// picker is the production path. Temp files are deleted at the end.
// Lines starting with "BATCH_IT" are the report.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/activity_record_media_scope.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/face_sample_model.dart';
import 'package:ota_counter/pages/batch_capture_page.dart';
import 'package:ota_counter/services/batch_import_service.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_engine.dart';
import 'package:ota_counter/services/face/face_sample_service.dart';
import 'package:ota_counter/services/settings_service.dart';
import 'package:ota_counter/widgets/counter_card.dart';

const String _fixtureUrl = String.fromEnvironment(
  'BATCH_FIXTURE_URL',
  defaultValue: 'http://127.0.0.1:8766',
);

void _log(String line) => debugPrint('BATCH_IT $line');

Future<Uint8List> _fetch(String name) async {
  final client = HttpClient();
  try {
    final response =
        await (await client.getUrl(Uri.parse('$_fixtureUrl/$name'))).close();
    if (response.statusCode != 200) {
      throw HttpException('GET $name -> ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  } finally {
    client.close();
  }
}

/// Dark table, polaroids (instax mini 54×86 card, 46×62 picture) in a row.
Uint8List _desk(List<Uint8List> photos) {
  const cardW = 300, cardH = 478, gap = 160;
  const imgW = 256, imgH = 344, imgLeft = 22, imgTop = 33;
  final width = gap + photos.length * (cardW + gap);
  const height = 1100;
  final desk = img.Image(width: width, height: height);
  img.fill(desk, color: img.ColorRgb8(34, 32, 36));
  for (var i = 0; i < photos.length; i++) {
    final x = gap + i * (cardW + gap);
    const y = (height - cardH) ~/ 2;
    img.fillRect(desk,
        x1: x,
        y1: y,
        x2: x + cardW - 1,
        y2: y + cardH - 1,
        color: img.ColorRgb8(244, 243, 238));
    final photo = img.bakeOrientation(img.decodeImage(photos[i])!);
    // Centre-crop to the picture area's aspect, then scale (no distortion).
    final target = imgW / imgH;
    var cw = photo.width, ch = photo.height;
    if (cw / ch > target) {
      cw = (ch * target).round();
    } else {
      ch = (cw / target).round();
    }
    final cropped = img.copyCrop(photo,
        x: (photo.width - cw) ~/ 2,
        y: (photo.height - ch) ~/ 2,
        width: cw,
        height: ch);
    img.compositeImage(
      desk,
      img.copyResize(cropped, width: imgW, height: imgH),
      dstX: x + imgLeft,
      dstY: y + imgTop,
    );
  }
  return Uint8List.fromList(img.encodeJpg(desk, quality: 92));
}

class _FakePicker extends ImagePickerPlatform {
  _FakePicker(this.files);

  final List<String> files;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async =>
      [for (final f in files) XFile(f)];
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(minutes: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 300));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('timed out waiting for $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('batch import: pick → review → save → ledger', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'test.ota',
      version: 'test',
      buildNumber: '0',
      buildSignature: '',
    );
    BatchCapturePage.cameraEnabled = false;
    final temp = await Directory(
            '${(await getTemporaryDirectory()).path}/batch_it_${DateTime.now().millisecondsSinceEpoch}')
        .create(recursive: true);
    addTearDown(() async {
      await DatabaseService.clearAppData();
      await FaceSampleService.clearAll();
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    // --- Ledger before the batch: 小树 has one 三寸 on 2026-03-22.
    await DatabaseService.clearAppData();
    await FaceSampleService.clearAll();
    final treeId = await DatabaseService.insertCounter(
        CounterModel(name: '小树', groupName: 'PokaPokaTime', color: '#22C55E'));
    final snowId = await DatabaseService.insertCounter(
        CounterModel(name: '小雪', groupName: '風時計Kazetoke', color: '#67E8F9'));
    final day = DateTime(2026, 3, 22);
    var counters = await DatabaseService.getCounters();
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: counters.firstWhere((c) => c.id == treeId),
        occurredAt: day,
        deltas: {CounterCountField.threeInch: 1},
      ),
    );

    // --- Recognition on, members known from two photos each.
    await SettingsService.saveFaceRecognitionEnabled(true);
    final warm = Stopwatch()..start();
    await FaceEngine.warmUp();
    _log('warmUp ${warm.elapsedMilliseconds} ms');
    counters = await DatabaseService.getCounters();
    for (final (id, names) in [
      (treeId, ['1773885784219256_4.jpg', '1774012408732238_7.jpg']),
      (snowId, ['1774590788600669_156.jpg', '1774627210654312_158.jpg']),
    ]) {
      final member = FaceSampleService.memberFromCounter(
          counters.firstWhere((c) => c.id == id));
      for (final name in names) {
        final faces = await FaceEngine.analyzeImageBytes(await _fetch(name));
        expect(faces, isNotEmpty, reason: 'sample $name has a face');
        await FaceSampleService.addSamples([
          FaceSampleService.sampleFromAnalysis(faces.first,
              source: FaceSampleSource.bootstrap, owner: member),
        ]);
      }
    }

    // --- The "gallery": a desk photo (小树, 小树, 小雪) + one real photo.
    final deskPath = '${temp.path}/desk.jpg';
    await File(deskPath).writeAsBytes(_desk([
      await _fetch('1774162317339650_150.jpg'),
      await _fetch('1774186906528695_154.jpg'),
      await _fetch('1774627238507906_158.jpg'),
    ]));
    final realPath = '${temp.path}/real.jpg';
    await File(realPath).writeAsBytes(await _fetch('1774186941318385_154.jpg'));
    // The archived photo is already just the picture (no white border), so
    // the cutter keeps it whole as one card; count it the production way.
    final realCards = (await BatchImportService.processPhoto(
      BatchSourcePhoto(path: realPath, capturedAt: null, fromCamera: false),
    ))
        .cards
        .length;
    _log('real photo alone gives $realCards card(s)');
    final truth = ['小树', '小树', '小雪', for (var i = 0; i < realCards; i++) '小树'];
    ImagePickerPlatform.instance = _FakePicker([deskPath, realPath]);

    // --- Home → 新增 → 批量拍切 → 从相册多选.
    await tester.pumpWidget(const MyApp());
    await _pumpUntil(tester, find.textContaining('新增'));
    await tester.tap(find.textContaining('新增').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量拍切'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('从相册多选'));
    final processing = Stopwatch()..start();
    await _pumpUntil(tester, find.textContaining('已切出 ${truth.length} 张'));
    await _pumpUntil(
        tester,
        find.byWidgetPredicate((w) =>
            w is Text &&
            (w.data ?? '').contains('处理中') == false &&
            (w.data ?? '').startsWith('2 张照片')));
    _log('cut + faces for 2 photos: ${processing.elapsedMilliseconds} ms');

    await tester.tap(find.byKey(const ValueKey('batch_next')));
    await _pumpUntil(tester, find.text('这批是哪天的切？'));
    await _pumpUntil(tester, find.textContaining('这天有'));
    expect(find.text('2026-03-22'), findsOneWidget,
        reason: 'no capture time → latest day with records');
    await tester.tap(find.byKey(const ValueKey('batch_day_confirm')));
    await _pumpUntil(tester, find.text('复核 ${truth.length} 张'));

    // --- Review: report what recognition said, then make it match truth.
    final scrollable = find.byType(Scrollable).first;
    var autoRight = 0, needed = 0;
    for (var i = 0; i < truth.length; i++) {
      final tile = find.byKey(ValueKey('batch_card_$i'));
      await tester.scrollUntilVisible(tile, 200, scrollable: scrollable);
      final texts = tester
          .widgetList<Text>(
              find.descendant(of: tile, matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .toList();
      final status = texts.first;
      final members = texts[1];
      _log('card $i truth=${truth[i]} status=$status members=$members');
      if (members == truth[i]) {
        if (status == '自动') autoRight++;
      } else {
        needed++;
        await tester
            .tap(find.descendant(of: tile, matching: find.text(members)));
        await tester.pumpAndSettle();
        final rows = find.byType(CheckboxListTile);
        for (final element in rows.evaluate().toList()) {
          final row = element.widget as CheckboxListTile;
          final title = (row.title as Text).data;
          if ((row.value ?? false) != (title == truth[i])) {
            await tester.tap(find.byWidget(row));
            await tester.pump();
          }
        }
        await tester.tap(find.byKey(const ValueKey('member_picker_done')));
        await tester.pumpAndSettle();
      }
      // Sizes are instax mini; flip any guess that says otherwise.
      for (var k = 0; k < 2; k++) {
        final chip = find.descendant(
            of: tile,
            matching: find.byWidgetPredicate(
                (w) => w is Text && (w.data == '五寸' || w.data == '三寸?')));
        if (chip.evaluate().isEmpty) break;
        await tester.tap(chip.first);
        await tester.pump();
      }
    }
    _log('recognition: $autoRight/${truth.length} auto & correct, '
        '$needed fixed by hand');

    await tester.scrollUntilVisible(find.text('将要保存'), -200,
        scrollable: scrollable);
    final treeBatch = truth.where((t) => t == '小树').length;
    // 小树: ledger has 1 → +(n-1). 小雪: none → +1.
    final supplements = [treeBatch - 1, 1];
    for (final n in supplements.toSet()) {
      expect(find.text('+$n 张'),
          findsNWidgets(supplements.where((x) => x == n).length));
    }

    await tester.tap(find.byKey(const ValueKey('batch_save')));
    await _pumpUntil(tester, find.text('我的切奇'));
    await tester.pumpAndSettle();

    // --- Ledger after: counts follow the rule, every photo is attached.
    counters = await DatabaseService.getCounters();
    final tree = counters.firstWhere((c) => c.id == treeId);
    final snow = counters.firstWhere((c) => c.id == snowId);
    expect(tree.threeInchCount, treeBatch);
    expect(snow.threeInchCount, 1);
    final records = await DatabaseService.getActivityRecords();
    final media = await DatabaseService.getActivityRecordMedia();
    expect(media.length, truth.length);
    int mediaOf(CounterModel c) => media.where((m) {
          final record = records.firstWhere((r) => r.id == m.recordId);
          return (record.counterId == c.id) &&
              activityRecordMediaBelongsToMember(
                  media: m, record: record, ownerCounters: [c]);
        }).length;
    expect(mediaOf(tree), treeBatch);
    expect(mediaOf(snow), 1);
    expect(records.where((r) => r.note == BatchImportService.supplementNote),
        hasLength(2));
    final learned = (await FaceSampleService.getSamples(isSelf: false))
        .where((s) => s.source == FaceSampleSource.confirmed)
        .length;
    _log('saved: 小树 ${tree.threeInchCount} 三寸 / ${mediaOf(tree)} photos, '
        '小雪 ${snow.threeInchCount} / ${mediaOf(snow)}; learned $learned faces');

    // Home card and member detail show the same.
    final card = find.widgetWithText(CounterCard, '小树');
    expect(card, findsOneWidget);
    final cardName = find.descendant(of: card, matching: find.text('小树')).first;
    await tester.ensureVisible(cardName);
    await tester.pumpAndSettle();
    await tester.tap(cardName);
    await tester.pumpAndSettle();
    await _pumpUntil(tester, find.text('存图数'));
    Finder metric(String label) => find
        .ancestor(of: find.text(label), matching: find.byType(Column))
        .first;
    expect(
        find.descendant(of: metric('存图数'), matching: find.text('$treeBatch')),
        findsOneWidget);
    expect(find.descendant(of: metric('总计'), matching: find.text('$treeBatch')),
        findsOneWidget);
    _log('member detail 小树: 总计 $treeBatch, 存图数 $treeBatch');

    final enrollment = find.text('登记人脸');
    await tester.ensureVisible(enrollment);
    await tester.pumpAndSettle();
    await tester.tap(enrollment);
    await _pumpUntil(tester, find.text('从相册选择照片（可多选）'));
    final treeSamples = (await FaceSampleService.getMemberSamples(
            FaceSampleService.memberFromCounter(tree)))
        .length;
    await _pumpUntil(tester, find.text('已有 $treeSamples 个样本'));
    expect(find.text('拍照登记'), findsOneWidget);
    _log('member face enrollment: $treeSamples samples, gallery + camera');

    // Same original again → duplicate warning.
    expect(
        await DatabaseService.countMediaBySourceHash(
            [await BatchImportService.sha1OfFile(deskPath)]),
        {await BatchImportService.sha1OfFile(deskPath): 3});
  }, timeout: const Timeout(Duration(minutes: 10)));
}
