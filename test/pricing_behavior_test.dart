import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';
import 'package:ota_counter/models/group_pricing_model.dart';

void main() {
  test('unconfigured pricing keeps unsigned options off by default', () {
    final pricing = GroupPricingModel.unconfigured('测试团');

    expect(pricing.enableUnsignedOptions, isFalse);
    expect(pricing.hasUnsignedPrices, isFalse);
    expect(pricing.unsignedThreeInchPrice, 30);
    expect(pricing.unsignedFiveInchPrice, 60);
  });

  test('explicit unsigned toggle is not forced on by stored unsigned prices',
      () {
    final pricing = GroupPricingModel(
      groupName: '测试团',
      label: '默认价格',
      enableUnsignedOptions: false,
      unsignedThreeInchPrice: 35,
      unsignedFiveInchPrice: 70,
      updatedAt: DateTime(2026, 3, 18),
    );

    expect(pricing.enableUnsignedOptions, isFalse);
    expect(pricing.hasUnsignedPrices, isFalse);
  });

  test('records using built-in default pricing follow current group pricing',
      () {
    final record = ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        name: '测试成员',
        groupName: '测试团',
        color: '#ffffff',
      ),
      occurredAt: DateTime(2026, 3, 18),
      deltas: const {
        CounterCountField.threeInch: 2,
      },
      pricing: GroupPricingModel.unconfigured('测试团'),
    );

    expect(record.pricingLabel, GroupPricingModel.builtInDefaultLabel);
    expect(record.shouldResolveWithCurrentPricing, isTrue);
  });

  test('records with explicit saved pricing keep historical price', () {
    final record = ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        name: '测试成员',
        groupName: '测试团',
        color: '#ffffff',
      ),
      occurredAt: DateTime(2026, 3, 18),
      deltas: const {
        CounterCountField.threeInch: 2,
      },
      pricing: GroupPricingModel(
        groupName: '测试团',
        label: '2026 春巡',
        threeInchPrice: 77,
        updatedAt: DateTime(2026, 3, 18),
      ),
    );

    expect(record.shouldResolveWithCurrentPricing, isFalse);
  });

  test('explicit free pricing remains a zero-value historical snapshot', () {
    final record = ActivityRecordModel.counterAdjustment(
      counter: CounterModel(
        name: '测试成员',
        groupName: '测试团',
        color: '#ffffff',
      ),
      occurredAt: DateTime(2026, 3, 18),
      deltas: const {
        CounterCountField.threeInch: 1,
      },
      pricing: GroupPricingModel(
        groupName: '测试团',
        label: '赠送券',
        threeInchPrice: 0,
        updatedAt: DateTime(2026, 3, 18),
      ),
    );

    final restored = ActivityRecordModel.fromMap(record.toMap());

    expect(record.totalAmount, 0);
    expect(record.usesCurrentPricing, isFalse);
    expect(record.shouldResolveWithCurrentPricing, isFalse);
    expect(restored.usesCurrentPricing, isFalse);
    expect(restored.shouldResolveWithCurrentPricing, isFalse);
  });

  test('legacy zero-priced records still follow current group pricing', () {
    final record = ActivityRecordModel(
      type: ActivityRecordType.counter,
      subjectName: '测试成员',
      groupName: '测试团',
      occurredAt: DateTime(2026, 3, 18),
      pricingLabel: '旧记录',
      threeInchCount: 1,
      totalAmount: 0,
    );

    expect(record.shouldResolveWithCurrentPricing, isTrue);
  });
}
