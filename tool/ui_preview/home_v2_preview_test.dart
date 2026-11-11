// Renders the home page with realistic synthetic data for before/after
// screenshots of the home redesign.
//
//   python3 tool/ui_preview/prepare_font.py
//   flutter test tool/ui_preview/home_v2_preview_test.dart --update-goldens \
//     --dart-define=HOME_V2_PHASE=after
//
// HOME_V2_PHASE picks the file name suffix (before / after).
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

const _fontPath = 'tool/ui_preview/PingFangSC-Preview.ttf';
const _phase = String.fromEnvironment('HOME_V2_PHASE', defaultValue: 'after');

Future<void> _loadPreviewFont() async {
  final file = File(_fontPath);
  if (!file.existsSync()) {
    fail('Missing $_fontPath. Run: python3 tool/ui_preview/prepare_font.py');
  }
  final bytes = await file.readAsBytes();
  final loader = FontLoader('PingFangPreview')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();

  final iconBytes = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(iconBytes));
  await iconLoader.load();
}

Future<void> _seed() async {
  await DatabaseService.clearAppData();
  // name, group, color, 3", 5", 3" 宿, 5" 宿, 团切
  const rows = <(String, String, String, int, int, int, int, int)>[
    ('林小满', '甜度超标', '#FF5C8A', 96, 31, 22, 8, 6),
    ('苏晚晴', '甜度超标', '#8B6CF0', 72, 20, 14, 5, 6),
    ('桃井柚', '甜度超标', '#FF9F43', 41, 9, 6, 2, 6),
    ('阿岚', 'Lumiere', '#1FB5A8', 58, 17, 9, 3, 4),
    ('星野遥', 'Lumiere', '#F5B700', 44, 12, 10, 4, 4),
    ('白鸟纱', 'Lumiere', '#4E8DF5', 21, 5, 3, 0, 4),
    ('陈知夏', '星屑电台', '#E8485F', 37, 10, 6, 2, 3),
    ('顾星野', '星屑电台', '#3DBE6B', 26, 6, 4, 1, 3),
    ('宫本栞', '星屑电台', '#F06BC8', 19, 4, 2, 0, 3),
    ('七海', 'NEON★PARADE', '#00B3E6', 33, 8, 5, 2, 2),
    ('小雪', 'NEON★PARADE', '#9AA5B1', 15, 3, 1, 0, 2),
    ('莓莓', 'NEON★PARADE', '#FF4F9A', 12, 2, 2, 0, 2),
    ('凛', '午夜糖果', '#5B5BD6', 22, 7, 3, 1, 1),
    ('朝比奈', '午夜糖果', '#FFB000', 9, 2, 0, 0, 1),
    ('葵', '午夜糖果', '#2EC4B6', 7, 1, 1, 0, 1),
    ('若菜', '春日便当', '#7BC043', 6, 1, 0, 0, 0),
    ('千岁', '春日便当', '#FF7F50', 4, 0, 0, 0, 0),
    ('羽月', '春日便当', '#C77DFF', 3, 0, 0, 0, 0),
  ];
  for (final row in rows) {
    await DatabaseService.insertCounter(
      CounterModel(
        name: row.$1,
        groupName: row.$2,
        color: row.$3,
        threeInchCount: row.$4,
        fiveInchCount: row.$5,
        threeInchShukudaiCount: row.$6,
        fiveInchShukudaiCount: row.$7,
        groupCutCount: row.$8,
      ),
    );
  }
  const tickets = <(String, String, double, bool)>[
    ('甜度超标 定期公演', '预售票', 88, false),
    ('甜度超标 定期公演', '预售票', 88, false),
    ('Lumiere 一周年', '现场票', 120, false),
    ('地下偶像拼盘 Vol.88', '免费票', 0, true),
    ('星屑电台 生诞祭', '预售票', 150, false),
    ('午夜糖果 免费场', '免费票', 0, true),
    ('NEON★PARADE 对版', '现场票', 100, false),
  ];
  for (var i = 0; i < tickets.length; i++) {
    final t = tickets[i];
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: t.$1,
        sessionLabel: i.isEven ? '第一部' : '第二部',
        occurredAt: DateTime(2026, 10, 3 + i * 4),
        quantity: 1,
        unitPrice: t.$3,
        ticketType: t.$2,
        isFree: t.$4,
        note: '预览数据',
      ),
    );
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

Widget _app(Brightness brightness) {
  final theme = brightness == Brightness.dark
      ? AppTheme.dark(fontFamily: 'PingFangPreview')
      : AppTheme.light(fontFamily: 'PingFangPreview');
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    darkTheme: theme,
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    home: const MyHomePage(),
  );
}

void _phoneView(WidgetTester tester, {double height = 2400}) {
  // 1080 x 2400 @ 2.625 ≈ a 411 x 914 dp Android phone, with a 24 dp status
  // bar and a 16 dp gesture bar like the real device.
  tester.view.physicalSize = Size(1080, height);
  tester.view.devicePixelRatio = 2.625;
  tester.view.padding = const FakeViewPadding(top: 63, bottom: 42);
  tester.view.viewPadding = const FakeViewPadding(top: 63, bottom: 42);
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await _loadPreviewFont();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'grid_size': 2.0,
      'sort_direction': false,
      'sort_type': 'count',
      'overview_metric_columns': 3,
    });
    PackageInfo.setMockInitialValues(
      appName: 'OTA Counter',
      packageName: 'top.huangxuanqi.otacounter',
      version: '1.5.4',
      buildNumber: '0',
      buildSignature: '',
    );
    await _seed();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('capture home v2 $mode', (tester) async {
      _phoneView(tester);
      // flutter_test draws shadows as hard blocks by default; render them
      // soft like a device does.
      debugDisableShadows = false;
      await tester.runAsync(() async {
        await tester.pumpWidget(_app(brightness));
      });
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../../docs/ui-preview/home-v2-$_phase-$mode.png'),
      );
      debugDisableShadows = true;
    });
  }

  testWidgets('capture home v2 3col light', (tester) async {
    SharedPreferences.setMockInitialValues({
      'grid_size': 3.0,
      'sort_direction': false,
      'sort_type': 'count',
      'overview_metric_columns': 3,
    });
    _phoneView(tester);
    debugDisableShadows = false;
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/home-v2-$_phase-3col-light.png'),
    );
    debugDisableShadows = true;
  });

  testWidgets('capture home v2 cards light', (tester) async {
    _phoneView(tester, height: 5600);
    debugDisableShadows = false;
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
          '../../docs/ui-preview/home-v2-$_phase-cards-light.png'),
    );
    debugDisableShadows = true;
  });

  testWidgets('home v2 narrow and large text have no overflow', (tester) async {
    tester.view.physicalSize = const Size(720, 1520);
    tester.view.devicePixelRatio = 2.25;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });
}
