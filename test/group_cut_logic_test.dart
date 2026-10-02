import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/counter_model.dart';

void main() {
  test('multi group cut records are stored as group cut entries', () {
    final record = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G'),
        ActivityParticipant(memberName: 'B', groupName: 'G'),
        ActivityParticipant(memberName: 'C', groupName: 'G'),
      ],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 3, 18),
      quantity: 3,
      totalPrice: 200,
    );

    expect(record.isMulti, isTrue);
    expect(record.countForField(CounterCountField.groupCut), 3);
    expect(record.multiCountField, CounterCountField.groupCut);
    expect(record.multiFieldLabel, '团切');
    expect(record.effectiveMultiQuantity, 3);
    expect(record.multiContributionTotal, 9);
  });

  test('legacy multi quantity falls back to count and old double quantity', () {
    final base = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G'),
        ActivityParticipant(memberName: 'B', groupName: 'G'),
      ],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 3, 18),
      quantity: 4,
    ).toMap();
    final legacyQuantity = Map<String, Object?>.from(base)
      ..['multi_cut_quantity'] = 0
      ..['double_cut_quantity'] = 4;
    expect(
        ActivityRecordModel.fromMap(legacyQuantity).effectiveMultiQuantity, 4);
    final legacyField = Map<String, Object?>.from(base)
      ..remove('multi_cut_quantity')
      ..remove('double_cut_quantity');
    expect(ActivityRecordModel.fromMap(legacyField).effectiveMultiQuantity, 4);
  });

  test('repeated aliases for one person do not multiply their photo count', () {
    final record = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G', personId: 1),
        ActivityParticipant(memberName: 'A alias', groupName: 'G', personId: 1),
        ActivityParticipant(memberName: 'B', groupName: 'G', personId: 2),
      ],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 3, 18),
      quantity: 2,
    );
    expect(record.effectiveParticipants, hasLength(2));
    expect(record.multiContributionTotal, 4);
  });

  test('direct member editing fields can hide group cut', () {
    final fields = CounterCountField.visibleValues(
      enableUnsigned: true,
      includeGroupCut: false,
    );

    expect(fields, isNot(contains(CounterCountField.groupCut)));
    expect(fields, contains(CounterCountField.threeInch));
    expect(fields, contains(CounterCountField.fiveInch));
  });

  test('counter detects when edited counts would decrease', () {
    final before = CounterModel(
      name: 'A',
      color: '#ffffff',
      threeInchCount: 9,
      fiveInchCount: 1,
    );
    final after = before.copyWith(threeInchCount: 0);

    expect(after.hasLowerCountThan(before), isTrue);
    expect(before.hasLowerCountThan(after), isFalse);
  });
}
