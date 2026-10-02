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
  if (!record.isMulti) {
    // Corrections can be negative and must cancel their original counts.
    return record.countForField(field);
  }
  return record.multiCountField == field ? record.effectiveMultiQuantity : 0;
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
  // Each involved group receives the physical photo quantity.
  if (!record.isMulti || isGroupCutMultiRecord(record)) {
    return 0;
  }
  return record.effectiveMultiQuantity;
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
