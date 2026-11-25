// Renders the 切册 photo 「调整照片信息」 sheet: as opened, and after picking
// another day. Output is written to /private/tmp/photo_info_preview/.
//
//   python3 tool/ui_preview/prepare_font.py
//   flutter test tool/ui_preview/photo_info_sheet_preview_test.dart
//
// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/pages/album/photo_info_sheet.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

import '../../test/support/isolated_test_databases.dart';

const _fontPath = 'tool/ui_preview/PingFangSC-Preview.ttf';
const _outputDir = '/private/tmp/photo_info_preview';

Future<void> _loadFonts() async {
  final bytes = await File(_fontPath).readAsBytes();
  await (FontLoader('PingFangPreview')
        ..addFont(Future.value(ByteData.sublistView(bytes))))
      .load();
  final icons = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
  await (FontLoader('MaterialIcons')..addFont(Future.value(icons))).load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int mediaId;

  setUpAll(() async {
    await _loadFonts();
    final databases = await useIsolatedTestDatabases();
    final documents = Directory('${databases.path}/documents')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => documents.path);
    Directory(_outputDir).createSync(recursive: true);
    await DatabaseService.clearAppData();
    await DatabaseService.insertCounter(
        CounterModel(name: '兔兔Miottie', groupName: 'ReCream', color: '#FF7A9E'));
    final tutu = (await DatabaseService.getCounters()).single;
    final recordId = await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: tutu,
        occurredAt: DateTime(2026, 11, 21),
        deltas: {CounterCountField.threeInch: 3},
        pricing: GroupPricingModel.unconfigured('ReCream'),
        activityName: '青岛 ReCream 专场',
        venueName: '青岛 Livehouse',
      ),
    );
    final picture = image.Image(width: 20, height: 30);
    mediaId = (await DatabaseService.saveActivityRecordMediaBytes(
      recordId: recordId,
      bytes: Uint8List.fromList(image.encodeJpg(picture)),
      mediaType: ActivityRecordMediaType.scan,
    ))
        .id!;
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('b')));
    await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 3);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      await File('$_outputDir/$name').writeAsBytes(bytes!.buffer.asUint8List());
    });
    print('wrote $_outputDir/$name');
  }

  testWidgets('photo info sheet', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('b'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(fontFamily: 'PingFangPreview'),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: TextButton(
                onPressed: () => showPhotoInfoSheet(context, mediaId: mediaId),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
    await shot(tester, 'photo-info-1-opened.png');

    await tester.tap(find.byKey(const ValueKey('photo-info-day')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('23'));
    await tester.tap(find.text('OK'));
    await settle(tester);
    await shot(tester, 'photo-info-2-new-day.png');
  });
}
