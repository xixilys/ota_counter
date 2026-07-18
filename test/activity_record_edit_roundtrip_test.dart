import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';
import 'package:ota_counter/widgets/add_activity_record_dialog.dart';

void main() {
  final counter = CounterModel(
    id: 7,
    name: '测试成员',
    groupName: '测试团',
    personId: 77,
    personName: '测试成员',
    color: '#ffffff',
  );

  test('counter edit round-trip preserves session and historical unit prices',
      () {
    final original = ActivityRecordModel.counterAdjustment(
      id: 42,
      counter: counter,
      occurredAt: DateTime(2026, 7, 1),
      deltas: const {
        CounterCountField.threeInch: 2,
      },
      pricing: GroupPricingModel(
        groupName: '测试团',
        label: '2026 春巡',
        threeInchPrice: 77,
        updatedAt: DateTime(2026, 7, 1),
      ),
      activityName: '测试偶活',
      venueName: '测试场地',
      sessionLabel: '一部',
      note: '原备注',
    );

    final rebuilt = ActivityRecordDraft.fromRecord(
      original,
      resolvedCounter: counter,
    )
        .copyWith(
      note: '新备注',
    )
        .toActivityRecord(
      pricings: [
        GroupPricingModel(
          groupName: '测试团',
          label: '2026 夏巡',
          threeInchPrice: 120,
          updatedAt: DateTime(2026, 7, 18),
        ),
      ],
      id: original.id,
    );

    expect(rebuilt, isNotNull);
    expect(rebuilt!.sessionLabel, '一部');
    expect(rebuilt.pricingLabel, '2026 春巡');
    expect(rebuilt.threeInchPrice, 77);
    expect(rebuilt.totalAmount, 154);
    expect(rebuilt.note, '新备注');
  });

  test('counter count edits still use saved historical pricing snapshot', () {
    final original = ActivityRecordModel.counterAdjustment(
      counter: counter,
      occurredAt: DateTime(2026, 7, 1),
      deltas: const {
        CounterCountField.threeInch: 1,
      },
      pricing: GroupPricingModel(
        groupName: '测试团',
        label: '2026 春巡',
        threeInchPrice: 77,
        updatedAt: DateTime(2026, 7, 1),
      ),
      sessionLabel: '二部',
    );

    final rebuilt = ActivityRecordDraft.fromRecord(
      original,
      resolvedCounter: counter,
    ).copyWith(
      counterDeltas: const {
        CounterCountField.threeInch: 3,
      },
    ).toActivityRecord(
      pricings: [
        GroupPricingModel(
          groupName: '测试团',
          label: '2026 夏巡',
          threeInchPrice: 150,
          updatedAt: DateTime(2026, 7, 18),
        ),
      ],
    );

    expect(rebuilt, isNotNull);
    expect(rebuilt!.threeInchPrice, 77);
    expect(rebuilt.totalAmount, 231);
    expect(rebuilt.sessionLabel, '二部');
  });

  test('records using built-in defaults still follow current pricing on edit',
      () {
    final original = ActivityRecordModel.counterAdjustment(
      counter: counter,
      occurredAt: DateTime(2026, 7, 1),
      deltas: const {
        CounterCountField.threeInch: 2,
      },
    );

    final rebuilt = ActivityRecordDraft.fromRecord(
      original,
      resolvedCounter: counter,
    ).toActivityRecord(
      pricings: [
        GroupPricingModel(
          groupName: '测试团',
          label: '2026 夏巡',
          threeInchPrice: 90,
          updatedAt: DateTime(2026, 7, 18),
        ),
      ],
    );

    expect(rebuilt, isNotNull);
    expect(rebuilt!.pricingLabel, '2026 夏巡');
    expect(rebuilt.threeInchPrice, 90);
    expect(rebuilt.totalAmount, 180);
    expect(rebuilt.usesCurrentPricing, isTrue);
    expect(rebuilt.shouldResolveWithCurrentPricing, isTrue);
  });

  test('free historical records stay free after an edit round-trip', () {
    final original = ActivityRecordModel.counterAdjustment(
      counter: counter,
      occurredAt: DateTime(2026, 7, 1),
      deltas: const {
        CounterCountField.threeInch: 2,
      },
      pricing: GroupPricingModel(
        groupName: '测试团',
        label: '赠送券',
        threeInchPrice: 0,
        updatedAt: DateTime(2026, 7, 1),
      ),
    );

    final rebuilt = ActivityRecordDraft.fromRecord(
      original,
      resolvedCounter: counter,
    ).toActivityRecord(
      pricings: [
        GroupPricingModel(
          groupName: '测试团',
          label: '2026 夏巡',
          threeInchPrice: 120,
          updatedAt: DateTime(2026, 7, 18),
        ),
      ],
    );

    expect(rebuilt, isNotNull);
    expect(rebuilt!.pricingLabel, '赠送券');
    expect(rebuilt.threeInchPrice, 0);
    expect(rebuilt.totalAmount, 0);
    expect(rebuilt.shouldResolveWithCurrentPricing, isFalse);
  });

  test('record counter resolution prefers person id over a homonym', () {
    final counters = [
      CounterModel(
        id: 1,
        name: '同名成员',
        groupName: '同团',
        personId: 101,
        personName: '同名真人',
        color: '#111111',
      ),
      CounterModel(
        id: 2,
        name: '同名成员',
        groupName: '同团',
        personId: 202,
        personName: '同名真人',
        color: '#222222',
      ),
    ];
    final record = ActivityRecordModel(
      type: ActivityRecordType.counter,
      personId: 202,
      personName: '同名真人',
      subjectName: '同名成员',
      groupName: '同团',
      occurredAt: DateTime(2026, 7, 1),
      threeInchCount: 1,
      totalAmount: 60,
    );

    final resolved = resolveCounterForActivityRecord(counters, record);

    expect(resolved?.id, 2);
  });

  test('multi edit round-trip preserves session, label, and total price', () {
    final original = ActivityRecordModel.multiCut(
      id: 88,
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: '测试团'),
        ActivityParticipant(memberName: 'B', groupName: '测试团'),
      ],
      field: CounterCountField.threeInch,
      occurredAt: DateTime(2026, 7, 1),
      activityName: '测试偶活',
      venueName: '测试场地',
      sessionLabel: '终演后',
      note: '原备注',
      pricingLabel: '2026 春巡多人切',
      quantity: 2,
      totalPrice: 260,
    );

    final rebuilt = ActivityRecordDraft.fromRecord(original)
        .copyWith(
      note: '新备注',
    )
        .toActivityRecord(
      pricings: [
        GroupPricingModel(
          groupName: '测试团',
          label: '2026 夏巡',
          threeInchPrice: 120,
          updatedAt: DateTime(2026, 7, 18),
        ),
      ],
      id: original.id,
    );

    expect(rebuilt, isNotNull);
    expect(rebuilt!.sessionLabel, '终演后');
    expect(rebuilt.pricingLabel, '2026 春巡多人切');
    expect(rebuilt.totalAmount, 260);
    expect(rebuilt.note, '新备注');
  });

  test('ticket edit round-trip preserves imported pricing label', () {
    final original = ActivityRecordModel.ticket(
      eventName: '测试活动',
      occurredAt: DateTime(2026, 7, 1),
      quantity: 2,
      unitPrice: 50,
    ).copyWith(pricingLabel: 'OTA 历史导入');

    final rebuilt = ActivityRecordDraft.fromRecord(original).toActivityRecord(
      pricings: const [],
    );

    expect(rebuilt, isNotNull);
    expect(rebuilt!.pricingLabel, 'OTA 历史导入');
    expect(rebuilt.totalAmount, 100);
  });
}
