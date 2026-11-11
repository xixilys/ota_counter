// ignore_for_file: invalid_use_of_visible_for_testing_member, avoid_relative_lib_imports
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/main.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/models/idol_activity_event_model.dart';
import 'package:ota_counter/pages/chart_page.dart';
import 'package:ota_counter/pages/idol_activity_events_page.dart';
import 'package:ota_counter/pages/sync_page.dart';
import 'package:ota_counter/pages/ticket_pricing_page.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

const _fontPath = 'tool/ui_preview/PingFangSC-Preview.ttf';

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
  const rows = <(String, String, String, int, int, int, int)>[
    ('林小满', 'Aurora', '#FF7A9E', 68, 24, 18, 6),
    ('苏晚晴', 'Aurora', '#7C6CF0', 54, 18, 12, 4),
    ('阿岚', 'Lumiere', '#21B6A8', 41, 16, 8, 2),
    ('星野遥', 'Lumiere', '#F4A63A', 37, 12, 10, 5),
    ('陈知夏', 'Starlight', '#4E8DF5', 29, 9, 7, 3),
    ('顾星野', 'Starlight', '#E45C8A', 23, 7, 5, 2),
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
      ),
    );
  }
  for (var day = 1; day <= 10; day++) {
    final isFree = day.isOdd;
    final ticketType = isFree ? '免费票' : (day % 4 == 0 ? '现场票' : '预售票');
    final price = isFree ? 0.0 : (day % 4 == 0 ? 100.0 : 80.0);
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: day.isEven ? 'Aurora 公演' : 'Lumiere 公演',
        sessionLabel: day.isEven ? '第一部' : '第二部',
        occurredAt: DateTime(2026, 10, day),
        quantity: 1,
        unitPrice: price,
        ticketType: ticketType,
        isFree: isFree,
        note: '预览数据',
      ),
    );
  }
}

Future<void> _seedChart() async {
  await DatabaseService.clearAppData();
  final now = DateTime.now();
  const rows = <(String, String, String)>[
    ('林小满', 'Aurora', '#FF7A9E'),
    ('苏晚晴', 'Aurora', '#7C6CF0'),
    ('阿岚', 'Lumiere', '#21B6A8'),
    ('星野遥', 'Lumiere', '#F4A63A'),
  ];
  for (final row in rows) {
    await DatabaseService.insertCounter(
      CounterModel(name: row.$1, groupName: row.$2, color: row.$3),
    );
  }
  for (final group in ['Aurora', 'Lumiere']) {
    await DatabaseService.upsertGroupPricing(
      GroupPricingModel(
        groupName: group,
        label: '标准价',
        threeInchPrice: 80,
        fiveInchPrice: 120,
        groupCutPrice: 200,
        threeInchShukudaiPrice: 100,
        fiveInchShukudaiPrice: 150,
        updatedAt: now,
      ),
    );
  }
  final counters = (await DatabaseService.getCounters());
  final pricings = {
    for (final pricing in await DatabaseService.getGroupPricings())
      pricing.groupName: pricing,
  };
  final fields = [
    CounterCountField.threeInch,
    CounterCountField.fiveInch,
    CounterCountField.threeInchShukudai,
    CounterCountField.fiveInchShukudai,
    CounterCountField.groupCut,
  ];
  for (var day = 0; day < 12; day++) {
    final counter = counters[day % counters.length];
    final field = fields[day % fields.length];
    await DatabaseService.insertActivityRecordWithCounterImpact(
      ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: now.subtract(Duration(days: day)),
        deltas: {field: 1 + (day % 3)},
        pricing: pricings[counter.groupName],
        activityName: day.isEven ? 'Aurora 定期公演' : 'Lumiere 定期公演',
        venueName: '涩谷 O-EAST',
        sessionLabel: day.isEven ? '第一部' : '第二部',
        note: '预览数据',
      ),
    );
  }
  await DatabaseService.insertActivityRecordWithCounterImpact(
    ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: '林小满', groupName: 'Aurora'),
        ActivityParticipant(memberName: '阿岚', groupName: 'Lumiere'),
      ],
      field: CounterCountField.groupCut,
      occurredAt: now.subtract(const Duration(days: 3)),
      activityName: '联合公演',
      venueName: '新宿 BLAZE',
      quantity: 2,
      totalPrice: 400,
      note: '预览数据',
    ),
  );
  await DatabaseService.insertActivityRecord(
    ActivityRecordModel.ticket(
      eventName: 'Aurora 定期公演',
      sessionLabel: '第一部',
      occurredAt: DateTime(now.year, now.month, now.day),
      quantity: 2,
      unitPrice: 80,
      ticketType: '预售票',
      isFree: false,
      note: '预览数据',
    ),
  );
  await DatabaseService.insertActivityRecord(
    ActivityRecordModel.ticket(
      eventName: 'Lumiere 免费场',
      sessionLabel: '第二部',
      occurredAt: DateTime(now.year, now.month, now.day),
      quantity: 2,
      unitPrice: 0,
      ticketType: '免费票',
      isFree: true,
      note: '免费场',
    ),
  );
  await DatabaseService.insertActivityRecord(
    ActivityRecordModel.ticket(
      eventName: 'Starlight 联合公演',
      occurredAt: DateTime(now.year, now.month, now.day),
      quantity: 1,
      unitPrice: 100,
      ticketType: '现场票',
      isFree: false,
      note: '现场票',
    ),
  );
}

Future<void> _settle(WidgetTester tester, {bool settle = true}) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (settle) {
    await tester.pumpAndSettle();
  }
}

Widget _app({required Brightness brightness, Widget? home}) {
  final theme = brightness == Brightness.dark
      ? AppTheme.dark(fontFamily: 'PingFangPreview')
      : AppTheme.light(fontFamily: 'PingFangPreview');
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    darkTheme: theme,
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    home: home ?? const MyHomePage(),
  );
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

  testWidgets('capture home light', (tester) async {
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(_app(brightness: Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/home-after-light.png'),
    );
  });

  testWidgets('narrow home has no layout overflow', (tester) async {
    tester.view.physicalSize = const Size(720, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(_app(brightness: Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text home has no layout overflow', (tester) async {
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.runAsync(() async {
      await tester.pumpWidget(_app(brightness: Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capture home light full', (tester) async {
    tester.view.physicalSize = const Size(860, 3000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(_app(brightness: Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/home-after-light-full.png'),
    );
  });

  testWidgets('capture home three columns', (tester) async {
    SharedPreferences.setMockInitialValues({
      'grid_size': 3.0,
      'sort_direction': false,
      'sort_type': 'count',
      'overview_metric_columns': 3,
    });
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(_app(brightness: Brightness.light));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/home-after-3col.png'),
    );
  });

  testWidgets('capture chart light', (tester) async {
    await tester.runAsync(_seedChart);
    tester.view.physicalSize = const Size(860, 3000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _app(brightness: Brightness.light, home: const ChartPage()),
      );
    });
    await _settle(tester, settle: false);
    expect(tester.takeException(), isNull);
    // ignore: avoid_print
    print(
        'chart loading=${find.byType(CircularProgressIndicator).evaluate().length} '
        'scaffold=${find.byType(Scaffold).evaluate().length} '
        'transient=${tester.binding.transientCallbackCount}');
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/chart-after-light.png'),
    );
  });

  testWidgets('capture event roster', (tester) async {
    await tester.runAsync(() async {
      final db = await IdolDatabaseService.database;
      await db.delete('idol_activity_events');
      await db.delete('idol_meta');
      final now = DateTime.now();
      final events = <IdolActivityEvent>[
        IdolActivityEvent(
          sourceEventId: 'preview-1',
          eventDate: DateTime(now.year, now.month, now.day + 1),
          city: '上海',
          venue: '万代南梦宫上海文化中心',
          eventName: 'Aurora 定期公演 Vol.12',
          startTime: '19:00',
          groups: const [IdolActivityGroup(name: 'Aurora', uid: '1')],
          ticketTiers: const [
            IdolTicketTier(name: '预售', price: 68),
            IdolTicketTier(name: '现场', price: 88),
          ],
          syncedAt: now,
        ),
        IdolActivityEvent(
          sourceEventId: 'preview-2',
          eventDate: DateTime(now.year, now.month, now.day + 3),
          city: '上海',
          venue: '新歌剧院',
          eventName: 'Lumiere × Starlight 联合公演',
          startTime: '18:30',
          groups: const [
            IdolActivityGroup(name: 'Lumiere', uid: '2'),
            IdolActivityGroup(name: 'Starlight', uid: '3'),
          ],
          isFree: true,
          syncedAt: now,
        ),
        IdolActivityEvent(
          sourceEventId: 'preview-3',
          eventDate: DateTime(now.year, now.month, now.day + 8),
          city: '杭州',
          venue: '酒球会',
          eventName: '地下偶像拼盘 Vol.88',
          startTime: '20:00',
          groups: const [IdolActivityGroup(name: 'Starlight', uid: '3')],
          ticketTiers: const [
            IdolTicketTier(name: '普通', price: 50),
            IdolTicketTier(name: '现场', price: 70),
            IdolTicketTier(name: '女性', price: 25),
          ],
          syncedAt: now,
        ),
      ];
      for (final event in events) {
        await db.insert('idol_activity_events', event.toDbMap());
      }
      await db.insert('idol_meta', {
        'key': 'activity_events_source_label',
        'value': 'MineCool 地下偶像行程',
      });
      await db.insert('idol_meta', {
        'key': 'activity_events_generated_at',
        'value': now.toIso8601String(),
      });
      await db.insert('idol_meta', {
        'key': 'activity_events_synced_at',
        'value': now.toIso8601String(),
      });
    });
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _app(
            brightness: Brightness.light, home: const IdolActivityEventsPage()),
      );
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/events-after-light.png'),
    );
  });

  testWidgets('capture ticket stats in chart', (tester) async {
    await tester.runAsync(_seedChart);
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _app(brightness: Brightness.light, home: const ChartPage()),
      );
    });
    await _settle(tester, settle: false);
    await tester.scrollUntilVisible(
      find.text('门票场次'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/chart-tickets-after-light.png'),
    );
  });

  testWidgets('capture sync settings', (tester) async {
    SharedPreferences.setMockInitialValues({
      'mcp_sync_base_url': 'http://192.168.1.20:8787',
      'mcp_sync_token': 'demo-token-1234567890',
      'mcp_sync_auto': true,
    });
    tester.view.physicalSize = const Size(860, 2100);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _app(brightness: Brightness.light, home: const SyncPage()),
      );
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/sync-after-light.png'),
    );
  });

  testWidgets('capture ticket pricing', (tester) async {
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _app(brightness: Brightness.light, home: const TicketPricingPage()),
      );
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/tickets-after-light.png'),
    );
  });

  testWidgets('capture home dark', (tester) async {
    tester.view.physicalSize = const Size(860, 1864);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.runAsync(() async {
      await tester.pumpWidget(_app(brightness: Brightness.dark));
    });
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/ui-preview/home-after-dark.png'),
    );
  });
}
