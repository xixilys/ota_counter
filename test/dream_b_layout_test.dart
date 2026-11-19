import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/merch_purchase_model.dart';
import 'package:ota_counter/pages/merch_page.dart';
import 'package:ota_counter/pages/ticket_organize_page.dart';
import 'package:ota_counter/pages/ticket_pricing_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/merch_service.dart';
import 'package:ota_counter/services/ticket_pricing_service.dart';
import 'package:ota_counter/theme/app_theme.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    await DatabaseService.clearAppData();
    await _seed();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  for (final page in <String, Widget>{
    'ticket ledger': const TicketPricingPage(),
    'organise flow': const TicketOrganizePage(),
    'merch ledger': const MerchPage(),
  }.entries) {
    testWidgets(
        '${page.key} survives a narrow screen at 1.3 text scale without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(720, 6000);
      tester.view.devicePixelRatio = 2;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(
        tester.platformDispatcher.clearTextScaleFactorTestValue,
      );

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: page.value,
          ),
        );
      });
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('merch quick-add dialog fits at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(720, 6000);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const MerchPage(),
        ),
      );
    });
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    await tester.tap(find.text('记一笔周边'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('organiser selection bar fits at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(720, 6000);
    tester.view.devicePixelRatio = 2;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const TicketOrganizePage(),
        ),
      );
    });
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    final groupCheckbox = find.byType(Checkbox).first;
    await tester.tap(groupCheckbox);
    await tester.pumpAndSettle();
    expect(find.textContaining('已选'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _seed() async {
  await DatabaseService.insertCounter(
    CounterModel(name: '林小满', groupName: 'Aurora', color: '#FF7A9E'),
  );
  await DatabaseService.insertCounter(
    CounterModel(name: '苏晚晴', groupName: 'Aurora', color: '#7C6CF0'),
  );
  final types = await TicketPricingService.getTicketTypes();
  for (final entry in <String, double>{
    '预售票': 88,
    '现场票': 120,
    '双人票': 208,
  }.entries) {
    await TicketPricingService.upsertTicketType(
      types
          .firstWhere((type) => type.name == entry.key)
          .copyWith(defaultPrice: entry.value),
    );
  }
  await DatabaseService.insertActivityRecord(
    ActivityRecordModel.ticket(
      eventName: 'Aurora 定期公演',
      occurredAt: DateTime(2026, 3, 1),
      quantity: 2,
      unitPrice: 88,
      ticketType: '预售票',
      isFree: false,
    ),
  );
  await DatabaseService.insertActivityRecord(
    ActivityRecordModel.ticket(
      eventName: 'Aurora 免费场',
      occurredAt: DateTime(2026, 2, 1),
      quantity: 1,
      unitPrice: 0,
      ticketType: '免费票',
      isFree: true,
    ),
  );
  for (final (event, session, price, isFree)
      in <(String, String, double, bool)>[
    ('春风剧场拼盘', '预售', 86, false),
    ('春风剧场拼盘', '预售', 86, false),
    ('白色情人节联欢', '双人', 104, false),
    ('花糖祭 第五场', '提前', 88, false),
    ('星轨北京 vol.3', '摄影', 138, false),
    ('未命名场次', '普通', 0, true),
  ]) {
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: event,
        sessionLabel: session,
        occurredAt: DateTime(2026, 3, 14),
        unitPrice: price,
        isFree: isFree,
      ),
    );
  }
  await MerchService.getKinds();
  for (final (kind, member, quantity, price) in <(String, String, int, double)>[
    ('生写真', '林小满', 3, 30),
    ('吧唧', '林小满', 2, 25),
    ('应援棒', '苏晚晴', 1, 45),
  ]) {
    await MerchService.savePurchase(
      MerchPurchaseModel.purchase(
        kind: kind,
        memberName: member,
        groupName: 'Aurora',
        quantity: quantity,
        unitPrice: price,
        occurredAt: DateTime(2026, 3, 5),
      ),
    );
  }
}
