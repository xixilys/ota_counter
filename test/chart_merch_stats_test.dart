import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/merch_purchase_model.dart';
import 'package:ota_counter/pages/chart_page.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/merch_service.dart';

import 'support/isolated_test_databases.dart';

Finder _byType(String type) =>
    find.byWidgetPredicate((widget) => widget.runtimeType.toString() == type);

Finder get _merchTicket =>
    find.byKey(const ValueKey<String>('merch-spend-ticket'));

Future<void> _openChart(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1400, 16000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(home: const ChartPage()),
    );
    for (var i = 0;
        i < 200 && _byType('_CalendarDayDetailCard').evaluate().isEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async => useIsolatedTestDatabases());

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DatabaseService.clearAppData();
  });

  testWidgets('merch spending for the current period appears next to tickets',
      (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.runAsync(() async {
      // A ticket today, plus merch today and one buy in the previous year.
      await DatabaseService.insertActivityRecord(
        ActivityRecordModel(
          type: ActivityRecordType.ticket,
          subjectName: '今日演出',
          occurredAt: today,
          ticketQuantity: 1,
          ticketUnitPrice: 100,
          usesCurrentPricing: false,
          totalAmount: 100,
        ),
      );
      await MerchService.savePurchase(
        MerchPurchaseModel.purchase(
          kind: '生写真',
          memberName: '小雪',
          quantity: 2,
          unitPrice: 25,
          occurredAt: today,
        ),
      );
      await MerchService.savePurchase(
        MerchPurchaseModel.purchase(
          kind: '吧唧',
          memberName: '小雪',
          quantity: 1,
          unitPrice: 30,
          occurredAt: DateTime(today.year - 1, 6, 1),
        ),
      );
    });

    await _openChart(tester);
    expect(_byType('_CalendarDayDetailCard'), findsOneWidget);

    // "今日" scope: only the purchase made today counts.
    final ticket = _merchTicket;
    expect(ticket, findsOneWidget);
    expect(
      find.descendant(of: ticket, matching: find.text('¥50')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ticket, matching: find.text('1 笔 · 2 件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ticket, matching: find.text('生写真 2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: ticket, matching: find.text('吧唧 1')),
      findsNothing,
    );

    // The day summary also prints today's merch spending.
    final dayCard = _byType('_CalendarDayDetailCard');
    expect(
      find.descendant(of: dayCard, matching: find.text('周边')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dayCard, matching: find.text('¥50')),
      findsWidgets,
    );


    // Switching to 全部 re-reads the whole ledger.
    await tester.runAsync(() async {
      await tester.tap(find.text('全部').first);
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.text('¥80').evaluate().isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(_merchTicket, findsOneWidget);
    expect(
      find.descendant(of: _merchTicket, matching: find.text('¥80')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _merchTicket, matching: find.text('2 笔 · 3 件')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _merchTicket, matching: find.text('吧唧 1')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no merch in the period hides the merch ticket', (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    await tester.runAsync(() async {
      await MerchService.savePurchase(
        MerchPurchaseModel.purchase(
          kind: '生写真',
          quantity: 1,
          unitPrice: 40,
          occurredAt: DateTime(today.year - 1, 1, 2),
        ),
      );
    });
    await _openChart(tester);
    expect(_merchTicket, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
