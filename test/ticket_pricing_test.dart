import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/ticket_type_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/ticket_pricing_service.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    await DatabaseService.clearAppData();
    final db = await DatabaseService.database;
    await db.delete(TicketPricingService.presetsTable);
    await db.delete(TicketPricingService.ticketTypesTable);
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  test('default types seed and event price is learned from a record', () async {
    final types = await TicketPricingService.getTicketTypes();
    expect(types.map((type) => type.name), contains('免费票'));
    expect(
      types.singleWhere((type) => type.name == '免费票').isFree,
      isTrue,
    );

    final record = ActivityRecordModel.ticket(
      eventName: '测试公演',
      occurredAt: DateTime(2026, 11, 2),
      venueName: '测试剧场',
      quantity: 2,
      unitPrice: 88,
      ticketType: '预售票',
    );
    await DatabaseService.insertActivityRecord(record);
    await TicketPricingService.rememberRecord(record);

    final suggestion = await TicketPricingService.suggestPrice(
      eventName: '测试公演',
      venueName: '测试剧场',
      ticketType: '预售票',
    );
    expect(suggestion.unitPrice, 88);
    expect(suggestion.isFree, isFalse);
    expect(suggestion.source, '该场次上次价格');

    final stats = await TicketPricingService.getStats();
    expect(stats.ticketCount, 2);
    expect(stats.amount, 176);
  });

  test('free ticket stats distinguish free and paid quantities', () async {
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: '免费场',
        occurredAt: DateTime(2026, 11, 2),
        quantity: 2,
        unitPrice: 0,
        ticketType: '免费票',
        isFree: true,
      ),
    );
    await DatabaseService.insertActivityRecord(
      ActivityRecordModel.ticket(
        eventName: '付费场',
        occurredAt: DateTime(2026, 11, 2),
        quantity: 3,
        unitPrice: 80,
        ticketType: '现场票',
        isFree: false,
      ),
    );

    final imported = await TicketPricingService.rebuildFromHistory();
    expect(imported, 2);
    final freeSuggestion = await TicketPricingService.suggestPrice(
      eventName: '免费场',
      ticketType: '免费票',
    );
    expect(freeSuggestion.isFree, isTrue);
    final paidSuggestion = await TicketPricingService.suggestPrice(
      eventName: '付费场',
      ticketType: '现场票',
    );
    expect(paidSuggestion.unitPrice, 80);

    final stats = await TicketPricingService.getStats();
    expect(stats.ticketCount, 5);
    expect(stats.freeTicketCount, 2);
    expect(stats.paidTicketCount, 3);
    expect(stats.amount, 240);
    expect(stats.countByType['免费票'], 2);
    expect(stats.countByType['现场票'], 3);

    final record = await DatabaseService.getActivityRecords();
    final free = record.singleWhere((item) => item.subjectName == '免费场');
    expect(free.resolvedTicketIsFree, isTrue);
    expect(free.ticketTypeLabel, '免费票');
    final restored = ActivityRecordModel.fromMap(free.toMap());
    expect(restored.ticketType, '免费票');
    expect(restored.resolvedTicketIsFree, isTrue);
  });

  test('ticket type CRUD keeps names unique', () async {
    final id = await TicketPricingService.upsertTicketType(
      TicketTypeModel(
        name: '早鸟票',
        defaultPrice: 66,
        updatedAt: DateTime(2026, 11, 2),
      ),
    );
    expect(id, greaterThan(0));
    final secondId = await TicketPricingService.upsertTicketType(
      TicketTypeModel(
        name: '早鸟票',
        defaultPrice: 77,
        updatedAt: DateTime(2026, 11, 2),
      ),
    );
    expect(secondId, id);
    final types = await TicketPricingService.getTicketTypes();
    expect(types.where((type) => type.name == '早鸟票'), hasLength(1));
    expect(
      types.singleWhere((type) => type.name == '早鸟票').defaultPrice,
      77,
    );
  });

  testWidgets('ticket dialog exposes type and free controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                showDialog<ActivityRecordDraft>(
                  context: context,
                  builder: (_) => AddActivityRecordDialog(
                    counters: const [],
                    pricings: const [],
                    initialDraft: ActivityRecordDraft(
                      type: ActivityRecordType.ticket,
                      occurredAt: DateTime(2026, 11, 2),
                    ),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }

    expect(find.text('票种'), findsOneWidget);
    expect(find.text('免费场次'), findsOneWidget);
    expect(find.text('预计金额：¥0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('ticket draft carries type and free flag into the record', () {
    final record = ActivityRecordDraft(
      type: ActivityRecordType.ticket,
      occurredAt: DateTime(2026, 11, 2),
      activityName: '免费场',
      ticketQuantity: 2,
      ticketUnitPrice: 0,
      ticketType: '免费票',
      ticketIsFree: true,
    ).toActivityRecord(pricings: const []);
    expect(record, isNotNull);
    expect(record!.ticketType, '免费票');
    expect(record.resolvedTicketIsFree, isTrue);
    expect(record.ticketTypeLabel, '免费票');
  });
}
