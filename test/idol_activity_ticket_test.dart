import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/idol_activity_event_model.dart';

void main() {
  test('event ticket tiers survive JSON and database round trips', () {
    final event = IdolActivityEvent.fromJson({
      'sourceEventId': 'minecool-detail-1',
      'date': '2026-11-08',
      'city': '上海',
      'venue': '世界树剧场',
      'eventName': 'Aurora 定期公演',
      'groups': [
        {'name': 'Aurora', 'uid': '1'},
      ],
      'isFree': false,
      'ticketTiers': [
        {'name': '预售', 'price': 68},
        {'name': '现场', 'price': 88},
      ],
    });

    expect(event.ticketSummary, '预售 ¥68 / 现场 ¥88');
    expect(event.ticketTiers, hasLength(2));

    final stored = event.toDbMap();
    final restored = IdolActivityEvent.fromMap({...stored, 'id': 7});
    expect(restored.isFree, isFalse);
    expect(restored.ticketTiers, hasLength(2));
    expect(restored.ticketSummary, '预售 ¥68 / 现场 ¥88');
    expect(restored.groups.single.name, 'Aurora');
  });

  test('free event ticket label and legacy rows default safely', () {
    final free = IdolActivityEvent.fromJson({
      'sourceEventId': 'minecool-detail-2',
      'date': '2026-11-09',
      'eventName': '免费场',
      'isFree': true,
      'ticketTiers': const <Object>[],
    });
    expect(free.ticketSummary, '免费入场');

    final legacy = IdolActivityEvent.fromMap({
      'source_event_id': 'old-1',
      'event_date': '2026-01-01',
      'event_name': '旧数据',
      'groups_json': '[]',
      'synced_at': '2026-01-01T00:00:00.000',
    });
    expect(legacy.isFree, isFalse);
    expect(legacy.ticketTiers, isEmpty);
    expect(legacy.ticketSummary, isEmpty);
  });

  test('free plus paid premium tier shows both', () {
    final event = IdolActivityEvent.fromJson({
      'sourceEventId': 'minecool-detail-3',
      'date': '2026-11-10',
      'eventName': '免费+VIP',
      'isFree': true,
      'ticketTiers': [
        {'name': 'VIP', 'price': 66},
      ],
    });
    expect(event.ticketSummary, '免费入场 · VIP ¥66');
  });
}
