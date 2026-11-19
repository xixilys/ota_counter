import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/ticket_type_model.dart';
import 'package:ota_counter/services/database_service.dart';
import 'package:ota_counter/services/ticket_classify_service.dart';
import 'package:ota_counter/services/ticket_pricing_service.dart';

import 'support/isolated_test_databases.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await useIsolatedTestDatabases();
  });

  setUp(() async {
    await DatabaseService.clearAppData();
  });

  tearDown(() async {
    await DatabaseService.clearAppData();
  });

  Future<List<TicketTypeModel>> seedTypes() async {
    await TicketPricingService.getTicketTypes();
    await TicketPricingService.upsertTicketType(
      TicketTypeModel(
        name: '早鸟票',
        defaultPrice: 66,
        sortOrder: 2,
        updatedAt: DateTime(2026, 11, 2),
      ),
    );
    return TicketPricingService.getTicketTypes();
  }

  ActivityRecordModel ticket({
    required String event,
    String venue = '',
    String session = '',
    String note = '',
    int quantity = 1,
    double unitPrice = 0,
    bool? isFree,
    DateTime? occurredAt,
  }) {
    return ActivityRecordModel.ticket(
      eventName: event,
      occurredAt: occurredAt ?? DateTime(2026, 11, 2),
      venueName: venue,
      sessionLabel: session,
      note: note,
      quantity: quantity,
      unitPrice: unitPrice,
      isFree: isFree,
    );
  }

  group('ticket type suggestions', () {
    test('free records suggest the free type first', () async {
      final types = await seedTypes();
      final free = ticket(event: '免费场', session: '第 1 部', isFree: true);
      final suggestion = TicketClassifyService.suggestType(free, types);
      expect(suggestion?.typeName, '免费票');
      expect(suggestion?.reason, '免费场次');

      final noMoney = ticket(event: '无料场', session: '无料');
      expect(
        TicketClassifyService.suggestType(noMoney, types)?.typeName,
        '免费票',
      );
    });

    test('event, session, venue and note text are searched', () async {
      final types = await seedTypes();
      expect(
        TicketClassifyService.suggestType(
          ticket(event: '某场演出', session: '预售', unitPrice: 68),
          types,
        )?.typeName,
        '预售票',
      );
      expect(
        TicketClassifyService.suggestType(
          ticket(event: '某场演出', venue: '剧场', note: '现场票', unitPrice: 100),
          types,
        )?.typeName,
        '现场票',
      );
      expect(
        TicketClassifyService.suggestType(
          ticket(event: '学生专场', unitPrice: 30),
          types,
        )?.typeName,
        '学生票',
      );
      expect(
        TicketClassifyService.suggestType(
          ticket(event: '女性限定场', unitPrice: 50),
          types,
        )?.typeName,
        '女性票',
      );
      expect(
        TicketClassifyService.suggestType(
          ticket(event: '特典会先行', unitPrice: 80),
          types,
        )?.typeName,
        '特典票',
      );
      expect(
        TicketClassifyService.suggestType(
          ticket(event: '双人票', unitPrice: 208),
          types,
        )?.typeName,
        '双人票',
      );
    });

    test('early-bird text wins over the generic pre-sale word', () async {
      final types = await seedTypes();
      final suggestion = TicketClassifyService.suggestType(
        ticket(event: '早鸟票专场', session: '预售', unitPrice: 66),
        types,
      );
      expect(suggestion?.typeName, '早鸟票');
    });

    test('price matching uses the learned default price', () async {
      final types = await seedTypes();
      final suggestion = TicketClassifyService.suggestType(
        ticket(event: '没有文字的场次', unitPrice: 66),
        types,
      );
      expect(suggestion?.typeName, '早鸟票');
      expect(suggestion?.reason, contains('默认价'));
    });

    test('unknown text and price leave the decision to the user', () async {
      final types = await seedTypes();
      final suggestion = TicketClassifyService.suggestType(
        ticket(event: '某某拼盘', unitPrice: 123),
        types,
      );
      expect(suggestion, isNull);
    });
  });

  group('grouping uncategorised tickets', () {
    test('groups by suggested type first, then by unit price', () async {
      final types = await seedTypes();
      final records = [
        ticket(event: '春风剧场拼盘', venue: '春风剧场', session: '预售', unitPrice: 86)
            .copyWith(id: 1),
        ticket(
          event: '夏夜拼盘',
          venue: '海边舞台',
          session: '预售',
          quantity: 2,
          unitPrice: 86,
        ).copyWith(id: 2),
        ticket(event: '春风剧场拼盘', venue: '春风剧场', session: '现场', unitPrice: 120)
            .copyWith(id: 3),
        ticket(
          event: '春风剧场拼盘',
          venue: '春风剧场',
          unitPrice: 86,
          occurredAt: DateTime(2026, 11, 3),
        ).copyWith(id: 4),
      ];
      final groups = TicketClassifyService.groupRecords(records, types);

      // 预售票 ¥86 from two different events lands in one group, so one tap
      // classifies both; the 现场 keyword/120 group and the un-suggested ¥86
      // record stay distinct.
      expect(groups, hasLength(3));
      final presale = groups.firstWhere(
        (group) => group.suggestedTypeName == '预售票',
      );
      expect(presale.records, hasLength(2));
      expect(presale.quantity, 3);
      expect(presale.amount, 258);
      expect(presale.eventLabels, containsAll(['春风剧场拼盘', '夏夜拼盘']));
      expect(presale.dateLabels, ['2026-11-02']);
      expect(presale.suggestedRecordIds, hasLength(2));
      expect(groups.first.suggestedTypeName, isNotNull);
      // Groups without a confident suggestion sort after suggested ones.
      expect(groups.last.suggestedTypeName, isNull);
      expect(groups.last.records.single.id, 4);
      final onSite = groups.firstWhere(
        (group) => group.unitPrice == 120,
      );
      expect(onSite.records.single.id, 3);
      expect(onSite.suggestedTypeName, '现场票');
    });

    test('one event, one price and no type stays a single group', () async {
      final types = await seedTypes();
      final groups = TicketClassifyService.groupRecords(
        [ticket(event: '某某拼盘', unitPrice: 123).copyWith(id: 5)],
        types,
      );
      expect(groups, hasLength(1));
      expect(groups.single.records, hasLength(1));
      expect(groups.single.eventLabels, ['某某拼盘']);
      expect(groups.single.suggestedTypeName, isNull);
    });
  });

  group('bulk assignment', () {
    test('updates saved records, keeps amounts and relearns prices', () async {
      await seedTypes();
      final first = ticket(
        event: '春风剧场拼盘',
        venue: '春风剧场',
        session: '预售',
        quantity: 2,
        unitPrice: 86,
      );
      final second = ticket(
        event: '春风剧场拼盘',
        venue: '春风剧场',
        session: '预售',
        unitPrice: 86,
      );
      final third = ticket(
        event: '免费场',
        session: '无料',
        isFree: true,
      );
      final firstId = await DatabaseService.insertActivityRecord(first);
      final secondId = await DatabaseService.insertActivityRecord(second);
      final thirdId = await DatabaseService.insertActivityRecord(third);

      final uncategorised =
          await TicketPricingService.getUncategorizedTickets();
      expect(uncategorised, hasLength(3));

      final result = await TicketPricingService.assignTypeToTickets(
        recordIds: [firstId, secondId],
        typeName: '预售票',
      );
      expect(result.assigned, 2);
      expect(result.skipped, 0);
      expect(result.learnedPresets, greaterThan(0));

      final records = await DatabaseService.getActivityRecords();
      final assigned = records.where((record) => record.ticketType == '预售票');
      expect(assigned, hasLength(2));
      expect(
        records.singleWhere((record) => record.id == firstId).totalAmount,
        172,
      );
      expect(
        records.singleWhere((record) => record.id == secondId).totalAmount,
        86,
      );

      final usage = await TicketPricingService.getTypeUsage();
      expect(usage['预售票']?.ticketCount, 3);
      expect(usage['预售票']?.amount, 258);
      expect(usage['预售票']?.lastUnitPrice, 86);

      final suggestion = await TicketPricingService.suggestPrice(
        eventName: '春风剧场拼盘',
        venueName: '春风剧场',
        ticketType: '预售票',
      );
      expect(suggestion.source, '该场次上次价格');
      expect(suggestion.unitPrice, 86);

      // The free ticket stays uncategorised until the user classifies it.
      expect(
        (await TicketPricingService.getUncategorizedTickets()).single.id,
        thirdId,
      );
      expect(
        records
            .singleWhere((record) => record.id == thirdId)
            .resolvedTicketIsFree,
        isTrue,
      );
    });

    test('unknown type and empty selection are handled', () async {
      final id = await DatabaseService.insertActivityRecord(
        ticket(event: '某场', unitPrice: 100),
      );
      expect(
        () => TicketPricingService.assignTypeToTickets(
          recordIds: [id],
          typeName: '不存在票种',
        ),
        throwsA(isA<StateError>()),
      );
      final empty = await TicketPricingService.assignTypeToTickets(
        recordIds: const [],
        typeName: '预售票',
      );
      expect(empty.assigned, 0);
    });
  });
}
