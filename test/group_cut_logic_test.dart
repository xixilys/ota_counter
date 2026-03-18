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
    expect(record.countForField(CounterCountField.groupCut), 1);
    expect(record.multiCountField, CounterCountField.groupCut);
    expect(record.multiFieldLabel, '团切');
    expect(record.effectiveMultiQuantity, 1);
    expect(record.multiContributionTotal, 3);
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
}
