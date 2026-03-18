import 'activity_record_model.dart';
import 'counter_model.dart';

bool isGroupCutMultiRecord(ActivityRecordModel record) {
  return record.isMulti && record.multiCountField == CounterCountField.groupCut;
}

int chartTypeFieldContribution(
  ActivityRecordModel record,
  CounterCountField field,
) {
  final count = record.countForField(field);
  if (count <= 0) {
    return 0;
  }
  if (!record.isMulti) {
    return count;
  }
  if (field == CounterCountField.groupCut) {
    return count;
  }
  return count * record.multiParticipantCount;
}

int chartGroupSummaryGroupCutContribution(ActivityRecordModel record) {
  if (!isGroupCutMultiRecord(record)) {
    return 0;
  }
  return record.effectiveMultiQuantity;
}

int chartGroupSummaryMultiContribution(
  ActivityRecordModel record, {
  required int participantSlots,
}) {
  if (!record.isMulti ||
      participantSlots <= 0 ||
      isGroupCutMultiRecord(record)) {
    return 0;
  }
  return record.effectiveMultiQuantity * participantSlots;
}
