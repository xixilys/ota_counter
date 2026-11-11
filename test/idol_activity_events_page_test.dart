import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ota_counter/models/idol_activity_event_model.dart';
import 'package:ota_counter/pages/idol_activity_events_page.dart';
import 'package:ota_counter/services/idol_database_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    directory = await Directory.systemTemp.createTemp('ota-events-page-');
    await databaseFactory.setDatabasesPath(directory.path);
  });

  setUp(() async {
    final db = await IdolDatabaseService.database;
    await db.delete('idol_activity_events');
    await db.delete('idol_meta');
  });

  tearDownAll(() async {
    await (await IdolDatabaseService.database).close();
    await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump();
    }
  }

  testWidgets('event roster page renders cached events and can search',
      (tester) async {
    final now = DateTime.now();
    final event = IdolActivityEvent(
      sourceEventId: 'test-event-1',
      eventDate: DateTime(now.year, now.month, now.day + 1),
      city: '上海',
      venue: '测试剧场',
      eventName: '测试公演',
      startTime: '19:00',
      groups: const [IdolActivityGroup(name: '测试团', uid: '1')],
      ticketTiers: const [
        IdolTicketTier(name: '预售', price: 68),
        IdolTicketTier(name: '现场', price: 88),
      ],
      syncedAt: now,
    );
    await tester.runAsync(() async {
      final db = await IdolDatabaseService.database;
      await db.insert('idol_activity_events', event.toDbMap());
      await db.insert('idol_meta', {
        'key': 'activity_events_source_label',
        'value': 'MineCool 测试源',
      });
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const IdolActivityEventsPage(),
        ),
      );
    });
    await settle(tester);

    expect(find.text('演出名单'), findsOneWidget);
    expect(find.text('测试公演'), findsOneWidget);
    expect(find.text('预售 ¥68 / 现场 ¥88'), findsOneWidget);
    expect(find.textContaining('MineCool 测试源'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '上海');
    await tester.pump();
    expect(find.text('测试公演'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '不存在的城市');
    await tester.pump();
    expect(find.text('没有匹配的场次'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('event roster page shows an empty state', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const IdolActivityEventsPage(),
        ),
      );
    });
    await settle(tester);

    expect(find.text('还没有缓存演出名单'), findsOneWidget);
    expect(find.text('同步最新场次'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });
}
