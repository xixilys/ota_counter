import 'activity_record_model.dart';
import 'counter_model.dart';

String chartPersonStatsKey({
  required int? personId,
  required String personName,
  required String groupName,
  required String subjectName,
}) {
  if (personId != null) {
    return 'person:$personId';
  }

  final normalizedPersonName = _normalizeLookupPart(personName);
  if (normalizedPersonName.isNotEmpty) {
    return 'person-name:$normalizedPersonName';
  }

  return 'fallback:${_normalizeLookupPart(groupName)}|${_normalizeLookupPart(subjectName)}';
}

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
  ActivityRecordModel record,
) {
  // Group summaries count one multi-cut record per involved group.
  if (!record.isMulti || isGroupCutMultiRecord(record)) {
    return 0;
  }
  return 1;
}

String _normalizeLookupPart(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) {
    return '';
  }
  return trimmed.replaceAll(
    RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'),
    '',
  );
}
