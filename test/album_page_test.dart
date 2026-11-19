import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/pages/album/album_page.dart';
import 'package:ota_counter/pages/album/album_widgets.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/settings_service.dart';
import 'package:ota_counter/models/album_preferences.dart';
import 'package:ota_counter/pages/album/album_viewer_page.dart';
import 'package:ota_counter/pages/record_memory_page.dart';
import 'package:ota_counter/pages/idol_cut_overview_page.dart';
import 'package:ota_counter/services/album_clarity_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

import 'support/album_sample_data.dart';
import 'support/isolated_test_databases.dart';

late Directory _documents;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 250; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    // File generation and decoder work complete on wall time, not the
    // widget test's fake animation clock.
    if (i >= 24 &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.text('清晰处理中').evaluate().isEmpty) {
      break;
    }
  }
  await tester.pumpAndSettle();
}

Widget _app({required Widget home, Brightness brightness = Brightness.light}) {
  final theme =
      brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    darkTheme: theme,
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    home: home,
  );
}

void _phone(WidgetTester tester, {double width = 430, double height = 932}) {
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _scrollToTimeline(WidgetTester tester) async {
  final scrollable = find.byType(CustomScrollView).first;
  for (var i = 0; i < 4; i++) {
    await tester.drag(scrollable, const Offset(0, -650));
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'top.huangxuanqi.otacounter',
      version: '1.6.2',
      buildNumber: '0',
      buildSignature: '',
    );
    final dir = await useIsolatedTestDatabases();
    _documents = Directory('${dir.path}/documents')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => _documents.path,
    );
    // Production seeds the idol library at startup. Doing it here means the
    // optional 演出名单 enrichment query never waits on that first-run
    // transaction (which would leave timers pending at test teardown).
    await IdolDatabaseService.initializeBuiltInDataIfNeeded();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
    await seedAlbumSample(_documents);
  });

  testWidgets('存图记录 reuses the scan rendition and original comparison',
      (tester) async {
    _phone(tester);
    final (record, media) = (await tester.runAsync(() async {
      final records = await DatabaseService.getActivityRecords();
      final allMedia = await DatabaseService.getActivityRecordMedia();
      final media = allMedia.firstWhere((item) => item.isScan);
      return (records.firstWhere((item) => item.id == media.recordId), media);
    }))!;
    final saved = (await tester.runAsync(() => AlbumPhotoFiles.prepare(
          media.path,
          rectifyCut: !media.processingMode.isProcessed,
          isScan: true,
        )))!;
    await tester.pumpWidget(_app(home: RecordMemoryPage(record: record)));
    await _settle(tester);

    final tile = find.byWidgetPredicate((widget) =>
        widget is AlbumPhotoThumb && widget.photo.path == media.path);
    await tester.ensureVisible(tile);
    await _settle(tester);
    final image = tester
        .widget<Image>(find.descendant(of: tile, matching: find.byType(Image)));
    expect(((image.image as ResizeImage).imageProvider as FileImage).file.path,
        saved.thumbnail.path);
    await tester.tap(tile);
    await _settle(tester);
    expect(find.byType(AlbumViewerPage), findsOneWidget);
    expect(find.text('清晰'), findsOneWidget);
    await tester.tap(find.text('清晰'));
    await _settle(tester);
    expect(find.text('原色'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_app(
      home: IdolCutOverviewPage(
        idolName: record.subjectName,
        records: [record],
        ownerCounters: const [],
      ),
    ));
    await _settle(tester);
    await tester.ensureVisible(tile);
    final overview = tester
        .widget<Image>(find.descendant(of: tile, matching: find.byType(Image)));
    expect(
        ((overview.image as ResizeImage).imageProvider as FileImage).file.path,
        saved.thumbnail.path);
    await tester.tap(tile);
    await _settle(tester);
    expect(find.byType(AlbumViewerPage), findsOneWidget);
    expect(find.text(media.isReversed ? '已反' : '未反'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('landing combines latest session, member and session shelves', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('切册'), findsWidgets);
    expect(find.text('最近一场'), findsOneWidget);
    expect(find.text('成员'), findsOneWidget);
    expect(find.text('场次'), findsOneWidget);
    expect(find.text('36 张'), findsWidgets);
    expect(find.text('Aurora 定期公演 Vol.12'), findsWidgets);
    expect(find.text('林小满'), findsWidgets);

    await _scrollToTimeline(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('10月'), findsWidgets);
    expect(find.text('2026'), findsWidgets);
    expect(find.byType(AlbumPhotoTile), findsWidgets);
  });

  testWidgets('member shelf opens the full grid and a member album', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);

    await tester.tap(find.byKey(const Key('album-members-all')));
    await tester.pumpAndSettle();
    expect(find.text('成员'), findsWidgets);
    expect(find.text('每位成员一张封面，点开就是她的切册。'), findsOneWidget);
    expect(find.byType(AlbumMemberCover), findsWidgets);
    expect(find.textContaining('单人切'), findsWidgets);

    await tester.tap(find.byType(AlbumMemberCover).first);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('林小满的切册'), findsOneWidget);
    expect(find.text('9 张'), findsWidgets);
    expect(find.textContaining('单人切 6 · 同框 3'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('最近一场'), findsOneWidget);
  });

  testWidgets('session shelf opens one session and the full session list', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);

    await tester.tap(find.text('Aurora 定期公演 Vol.12').first);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(AlbumPhotoTile), findsWidgets);
    expect(find.textContaining('涩谷 O-EAST'), findsWidgets);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('album-sessions-all')));
    await tester.pumpAndSettle();
    expect(find.text('场次'), findsWidgets);
    expect(find.text('Aurora 定期公演 Vol.12'), findsWidgets);
    expect(find.byType(AlbumPhotoTile), findsWidgets);
  });

  testWidgets('photo tap opens the zoomable viewer and swipes', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);
    await _scrollToTimeline(tester);

    final firstTile = find.byType(AlbumPhotoTile).at(3);
    await tester.ensureVisible(firstTile);
    await tester.pumpAndSettle();
    await tester.tap(firstTile);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('双指缩放 · 左右滑动切换'), findsOneWidget);
    String pageLabel() =>
        tester.widget<Text>(find.textContaining('/ 36')).data!;
    expect(find.textContaining('/ 36'), findsOneWidget);
    final before = pageLabel();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            widget.data != null &&
            widget.data!.contains('张') &&
            widget.data!.isNotEmpty,
      ),
      findsWidgets,
    );

    await tester.fling(
      find.byType(PageView),
      const Offset(-320, 0),
      1000,
    );
    await _settle(tester);
    expect(pageLabel(), isNot(before));
  });

  testWidgets('year jump lands on the older year and the undated section', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);

    expect(find.text('12月'), findsNothing);
    await tester.tap(find.byIcon(Icons.calendar_month_rounded));
    await tester.pumpAndSettle();
    expect(find.text('跳到年份'), findsOneWidget);
    expect(find.text('2026年'), findsOneWidget);
    expect(find.text('2025年'), findsOneWidget);
    expect(find.text('日期不明'), findsOneWidget);

    await tester.tap(find.text('2025年'));
    await tester.pumpAndSettle();
    expect(find.text('12月'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.calendar_month_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日期不明').last);
    await tester.pumpAndSettle();
    expect(find.text('日期不明'), findsWidgets);
  });

  testWidgets('member-filtered album from the detail hook', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        home: const AlbumPage(
          memberPersonId: 101,
          memberName: '林小满',
          memberGroupName: 'Aurora',
          memberColorHex: '#FF7A9E',
        ),
      ),
    );
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('林小满的切册'), findsOneWidget);
    expect(find.text('9 张'), findsWidgets);
    expect(find.textContaining('单人切 6 · 同框 3'), findsOneWidget);
    expect(find.text('最近一场'), findsNothing);
  });

  testWidgets('narrow screen and large text have no layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);
    expect(tester.takeException(), isNull);

    await _scrollToTimeline(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide screen and large text have no layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1800, 2600);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);
    expect(tester.takeException(), isNull);

    await _scrollToTimeline(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark theme renders the album', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(home: const AlbumPage(), brightness: Brightness.dark),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('切册'), findsWidgets);
    expect(find.text('最近一场'), findsOneWidget);
    await _scrollToTimeline(tester);
    expect(find.byType(AlbumPhotoTile), findsWidgets);
  });

  testWidgets('home overflow menu opens 切册', (tester) async {
    _phone(tester);
    await tester.pumpWidget(const MyApp());
    await _settle(tester);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('切册').last);
    await _settle(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('最近一场'), findsOneWidget);
    expect(find.text('成员'), findsWidgets);
  });
  testWidgets(
      'saved display choices apply to real timeline and survive reopening',
      (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);
    await tester.tap(find.byTooltip('切册显示设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应援印边'));
    await tester.ensureVisible(find.text('2 列'));
    await tester.tap(find.text('2 列'));
    await tester.ensureVisible(find.text('每天一张主打'));
    await tester.tap(find.text('每天一张主打'));
    await tester.ensureVisible(find.text('时间线照片铺满相框'));
    await tester.tap(find.text('时间线照片铺满相框'));
    await tester.ensureVisible(find.text('首页展示收藏架'));
    await tester.tap(find.text('首页展示收藏架'));
    await tester.ensureVisible(find.text('保存显示设置'));
    await tester.tap(find.text('保存显示设置'));
    await tester.pumpAndSettle();
    expect(find.text('最近一场'), findsNothing);
    expect(
        tester
            .widget<AlbumPhotoTile>(find.byType(AlbumPhotoTile).first)
            .printStyle,
        AlbumPrintStyle.supporter);
    expect(find.byType(AlbumPhotoTile), findsWidgets);
    expect(tester.widget<AlbumPhotoTile>(find.byType(AlbumPhotoTile).first).fit,
        BoxFit.contain);
    expect((await SettingsService.getAlbumPreferences()).columns, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);
    expect(find.text('最近一场'), findsNothing);
    expect(
        tester
            .widget<AlbumPhotoTile>(find.byType(AlbumPhotoTile).first)
            .printStyle,
        AlbumPrintStyle.supporter);
    await tester.tap(find.byTooltip('跳到年份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025年'));
    await tester.pumpAndSettle();
    expect(find.text('12月'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('checked ZIP import is available only in the global album',
      (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(home: const AlbumPage()));
    await _settle(tester);
    await tester.tap(find.byTooltip('切册操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入已核对切图'));
    await tester.pumpAndSettle();
    expect(find.text('选择本地 ZIP'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(home: const AlbumPage(memberName: '林小满')));
    await _settle(tester);
    expect(find.byTooltip('切册操作'), findsNothing);
    expect(find.text('导入已核对切图'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
