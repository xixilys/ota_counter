import 'package:flutter_test/flutter_test.dart';

import 'package:ota_counter/models/activity_record_model.dart';
import 'package:ota_counter/models/chart_stats_helpers.dart';
import 'package:ota_counter/models/counter_model.dart';

void main() {
  test('group-cut multi records contribute one group cut in chart stats', () {
    final record = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G'),
        ActivityParticipant(memberName: 'B', groupName: 'G'),
        ActivityParticipant(memberName: 'C', groupName: 'G'),
        ActivityParticipant(memberName: 'D', groupName: 'G'),
        ActivityParticipant(memberName: 'E', groupName: 'G'),
      ],
      field: CounterCountField.groupCut,
      occurredAt: DateTime(2026, 3, 18),
      quantity: 5,
      totalPrice: 200,
    );

    expect(isGroupCutMultiRecord(record), isTrue);
    expect(
      chartTypeFieldContribution(record, CounterCountField.groupCut),
      1,
    );
    expect(chartGroupSummaryGroupCutContribution(record), 1);
    expect(
      chartGroupSummaryMultiContribution(record),
      0,
    );
  });

  test('regular multi records count once per involved group in summaries', () {
    final record = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G'),
        ActivityParticipant(memberName: 'B', groupName: 'G'),
        ActivityParticipant(memberName: 'C', groupName: 'G'),
      ],
      field: CounterCountField.threeInch,
      occurredAt: DateTime(2026, 3, 18),
      quantity: 2,
      totalPrice: 180,
    );

    expect(isGroupCutMultiRecord(record), isFalse);
    expect(
      chartTypeFieldContribution(record, CounterCountField.threeInch),
      6,
    );
    expect(chartGroupSummaryGroupCutContribution(record), 0);
    expect(chartGroupSummaryMultiContribution(record), 1);
  });

  test('cross-group multi records count once for each involved group', () {
    final record = ActivityRecordModel.multiCut(
      participants: const [
        ActivityParticipant(memberName: 'A', groupName: 'G1'),
        ActivityParticipant(memberName: 'B', groupName: 'G1'),
        ActivityParticipant(memberName: 'C', groupName: 'G2'),
      ],
      field: CounterCountField.fiveInch,
      occurredAt: DateTime(2026, 3, 18),
      quantity: 4,
      totalPrice: 220,
    );

    expect(isGroupCutMultiRecord(record), isFalse);
    expect(chartGroupSummaryMultiContribution(record), 1);
  });
}
