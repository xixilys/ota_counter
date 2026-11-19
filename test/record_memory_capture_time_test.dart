import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/pages/album/album_grouping.dart';
import 'package:ota_counter/pages/record_memory_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/face/face_recognition_rules.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory documents;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    documents = await useIsolatedTestDatabases();
    messenger.setMockMethodCallHandler(paths, (_) async => documents.path);
  });
  tearDownAll(() {
    messenger.setMockMethodCallHandler(paths, null);
  });

  for (final (source, manual, exif, expected) in [
    (
      ImageSource.gallery,
      false,
      '2026:11:15 02:03:04',
      DateTime(2026, 11, 15, 2, 3, 4),
    ),
    (
      ImageSource.camera,
      false,
      '2026:11:16 23:04:05',
      DateTime(2026, 11, 16, 23, 4, 5),
    ),
    (ImageSource.gallery, true, null, null),
  ]) {
    testWidgets(
        'single scan keeps original capture time: $source manual=$manual',
        (tester) async {
      final occurredAt = DateTime(2026, 11, 12, 18);
      final record = ActivityRecordModel(
        type: ActivityRecordType.counter,
        subjectName: '小雪',
        groupName: 'Aurora',
        threeInchCount: 1,
        totalAmount: 0,
        occurredAt: occurredAt,
      );
      final id = (await tester
          .runAsync(() => DatabaseService.insertActivityRecord(record)))!;
      final file = File('${documents.path}/source-$id.jpg');
      final side = manual ? 96 : 48;
      final picture = img.Image(width: side, height: side);
      if (exif != null) picture.exif.exifIfd[0x9003] = exif;
      await tester.runAsync(() async {
        await file.writeAsBytes(img.encodeJpg(picture));
        await file.setLastModified(DateTime(2026, 11, 20, 1));
      });

      var picked = false;
      messenger.setMockMethodCallHandler(picker, (call) async {
        picked = true;
        expect(call.method, 'pickImage');
        expect(call.arguments['source'], source.index);
        expect(call.arguments['maxWidth'], isNull);
        expect(call.arguments['imageQuality'], isNull);
        return file.path;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
      await tester.runAsync(() => tester.pumpWidget(MaterialApp(
            home: RecordMemoryPage(record: record.copyWith(id: id)),
          )));
      await _waitFor(tester, find.textContaining('这条见面记录还没有存图'));
      await _tap(tester, '新增存图');
      await _tap(tester, '扫描切图');
      await _tap(tester, manual ? '手动框选辅助' : '简单防反光');
      await _tap(
        tester,
        manual
            ? '从相册选择后手动框选'
            : source == ImageSource.gallery
                ? '从相册选择一张'
                : '拍一张扫描',
        io: true,
      );
      if (manual) {
        await _waitFor(tester, find.text('生成切图'));
        await _tap(tester, '生成切图', io: true);
      }
      await _waitFor(tester, find.text('新增存图'));
      expect(picked, isTrue);

      final (saved, storedRecord) = (await tester.runAsync(() async {
        final rows =
            await DatabaseService.getActivityRecordMedia(recordIds: [id]);
        final records = await DatabaseService.getActivityRecords();
        return (rows.single, records.singleWhere((row) => row.id == id));
      }))!;
      expect(saved.capturedAt, expected);
      expect(saved.recordId, id);
      expect(storedRecord.occurredAt, occurredAt);
      final day = expected == null
          ? recordActivityDay(occurredAt)
          : activityDayOf(expected);
      final photo = buildAlbumData(
        counters: const [],
        records: [storedRecord],
        media: [saved],
      ).photos.single;
      expect(photo.activityDay, day);
      expect(photo.dateFromPhoto, expected != null);
    });
  }
}

Future<void> _tap(WidgetTester tester, String text, {bool io = false}) async {
  final target = find.text(text).hitTestable();
  if (io) {
    await tester.runAsync(() => tester.tap(target));
    return;
  }
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 300; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 350));
      return;
    }
  }
  expect(finder, findsOneWidget);
}
