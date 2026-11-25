import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/pages/album/photo_info_sheet.dart';
import 'package:ota_counter/services/cheki_photo_move_service.dart';
import 'package:ota_counter/services/database_service.dart';

import 'support/isolated_test_databases.dart';

Uint8List _jpeg() {
  final picture = image.Image(width: 20, height: 30);
  image.fill(picture, color: image.ColorRgb8(90, 40, 60));
  return Uint8List.fromList(image.encodeJpg(picture));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int mediaId;
  late int recordId;
  late CounterModel tutu;
  late CounterModel mimi;

  setUpAll(() async {
    final databases = await useIsolatedTestDatabases();
    final documents = Directory('${databases.path}/documents')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => documents.path);
  });

  setUp(() async {
    await DatabaseService.clearAppData();
    ChekiPhotoMoveService.learnFaces = (
            {required record, required counter, required photos}) async =>
        {'face_samples_added': 0};
    for (final name in ['兔兔Miottie', '米米']) {
      await DatabaseService.insertCounter(
          CounterModel(name: name, groupName: 'ReCream', color: '#FF7A9E'));
    }
    final counters = await DatabaseService.getCounters();
    tutu = counters.singleWhere((c) => c.name == '兔兔Miottie');
    mimi = counters.singleWhere((c) => c.name == '米米');
    recordId = await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: tutu,
        occurredAt: DateTime(2026, 11, 21),
        deltas: {CounterCountField.threeInch: 2},
        pricing: GroupPricingModel.unconfigured('ReCream'),
        activityName: '青岛公演',
      ),
    );
    mediaId = (await DatabaseService.saveActivityRecordMediaBytes(
      recordId: recordId,
      bytes: _jpeg(),
      mediaType: ActivityRecordMediaType.scan,
    ))
        .id!;
  });

  /// Lets real database work (sqflite FFI) finish between frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<List<String?>> openSheet(WidgetTester tester) async {
    final results = <String?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => results
                .add(await showPhotoInfoSheet(context, mediaId: mediaId)),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
    return results;
  }

  testWidgets('changing the member previews and moves photo and count',
      (tester) async {
    final results = await openSheet(tester);
    expect(find.text('调整照片信息'), findsOneWidget);
    expect(find.textContaining('张数自动跟着走'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('photo-info-member')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('米米（ReCream）').last);
    await settle(tester);

    expect(find.textContaining('还没有米米的流水，会新建一条'), findsOneWidget);
    expect(find.textContaining('原流水3寸从 2 张变 1 张'), findsOneWidget);
    expect(find.textContaining('按米米重新学习'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('photo-info-save')));
    await settle(tester);
    expect(results.single, contains('已挪到米米'));

    final counters = await tester.runAsync(() => DatabaseService.getCounters())
        as List<CounterModel>;
    expect(counters.singleWhere((c) => c.id == tutu.id).threeInchCount, 1);
    expect(counters.singleWhere((c) => c.id == mimi.id).threeInchCount, 1);
  });

  testWidgets('same member and day edits the record\'s activity',
      (tester) async {
    final results = await openSheet(tester);
    await tester.enterText(find.widgetWithText(TextField, '活动'), '上海公演');
    await tester.pumpAndSettle();
    expect(find.textContaining('活动信息改的是整条流水'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('photo-info-save')));
    await settle(tester);
    expect(results.single, '已更新这条流水的活动信息');
    final records =
        await tester.runAsync(() => DatabaseService.getActivityRecords())
            as List<ActivityRecordModel>;
    expect(records.single.activityName, '上海公演');
    expect(records.single.threeInchCount, 2);
  });
}
