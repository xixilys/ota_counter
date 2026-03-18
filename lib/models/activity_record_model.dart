import 'dart:convert';

import 'counter_model.dart';
import 'group_pricing_model.dart';

enum ActivityRecordType {
  counter,
  multi,
  ticket;

  String get dbValue => switch (this) {
        ActivityRecordType.counter => 'counter',
        ActivityRecordType.multi => 'multi',
        ActivityRecordType.ticket => 'ticket',
      };

  static ActivityRecordType fromDb(String value) {
    return switch (value) {
      'duo' || 'multi' => ActivityRecordType.multi,
      'ticket' => ActivityRecordType.ticket,
      _ => ActivityRecordType.counter,
    };
  }
}

class ActivityParticipant {
  final String memberName;
  final String groupName;
  final int? personId;
  final String personName;

  const ActivityParticipant({
    required this.memberName,
    this.groupName = '',
    this.personId,
    this.personName = '',
  });

  String get resolvedPersonName {
    final normalized = personName.trim();
    if (normalized.isNotEmpty) {
      return normalized;
    }
    return memberName.trim();
  }

  String get displayLabel {
    final normalizedGroup = groupName.trim();
    if (normalizedGroup.isEmpty) {
      return memberName.trim();
    }
    return '${memberName.trim()} · $normalizedGroup';
  }

  Map<String, Object?> toMap() {
    return {
      'memberName': memberName,
      'groupName': groupName,
      'personId': personId,
      'personName': personName,
    };
  }

  factory ActivityParticipant.fromMap(Map<String, Object?> map) {
    return ActivityParticipant(
      memberName: (map['memberName'] ?? map['name'] ?? '') as String,
      groupName: (map['groupName'] ?? map['group_name'] ?? '') as String,
      personId: ((map['personId'] ?? map['person_id']) as num?)?.toInt(),
      personName: (map['personName'] ?? map['person_name'] ?? '') as String,
    );
  }
}

class ActivityRecordModel {
  final int? id;
  final ActivityRecordType type;
  final String source;
  final String? sourceRecordId;
  final int? counterId;
  final int? personId;
  final String personName;
  final String subjectName;
  final String secondarySubjectName;
  final String groupName;
  final String sessionLabel;
  final String note;
  final DateTime occurredAt;
  final String pricingLabel;
  final int threeInchCount;
  final int fiveInchCount;
  final int unsignedThreeInchCount;
  final int unsignedFiveInchCount;
  final int groupCutCount;
  final int threeInchShukudaiCount;
  final int fiveInchShukudaiCount;
  final int multiCutQuantity;
  final int ticketQuantity;
  final double threeInchPrice;
  final double fiveInchPrice;
  final double unsignedThreeInchPrice;
  final double unsignedFiveInchPrice;
  final double groupCutPrice;
  final double doubleCutUnitPrice;
  final double threeInchShukudaiPrice;
  final double fiveInchShukudaiPrice;
  final double ticketUnitPrice;
  final double totalAmount;
  final List<ActivityParticipant> participants;

  const ActivityRecordModel({
    this.id,
    required this.type,
    this.source = 'local',
    this.sourceRecordId,
    this.counterId,
    this.personId,
    this.personName = '',
    required this.subjectName,
    this.secondarySubjectName = '',
    this.groupName = '',
    this.sessionLabel = '',
    this.note = '',
    required this.occurredAt,
    this.pricingLabel = '',
    this.threeInchCount = 0,
    this.fiveInchCount = 0,
    this.unsignedThreeInchCount = 0,
    this.unsignedFiveInchCount = 0,
    this.groupCutCount = 0,
    this.threeInchShukudaiCount = 0,
    this.fiveInchShukudaiCount = 0,
    this.multiCutQuantity = 0,
    this.ticketQuantity = 0,
    this.threeInchPrice = 0,
    this.fiveInchPrice = 0,
    this.unsignedThreeInchPrice = 0,
    this.unsignedFiveInchPrice = 0,
    this.groupCutPrice = 0,
    this.doubleCutUnitPrice = 0,
    this.threeInchShukudaiPrice = 0,
    this.fiveInchShukudaiPrice = 0,
    this.ticketUnitPrice = 0,
    required this.totalAmount,
    this.participants = const [],
  });

  factory ActivityRecordModel.counterAdjustment({
    int? id,
    required CounterModel counter,
    required DateTime occurredAt,
    required Map<CounterCountField, int> deltas,
    GroupPricingModel? pricing,
    String note = '',
    String? pricingLabel,
  }) {
    final resolvedPricing = pricing ??
        GroupPricingModel.unconfigured(
          counter.groupName.trim(),
        );
    final threeInchCount = deltas[CounterCountField.threeInch] ?? 0;
    final fiveInchCount = deltas[CounterCountField.fiveInch] ?? 0;
    final unsignedThreeInchCount =
        deltas[CounterCountField.unsignedThreeInch] ?? 0;
    final unsignedFiveInchCount =
        deltas[CounterCountField.unsignedFiveInch] ?? 0;
    final groupCutCount = deltas[CounterCountField.groupCut] ?? 0;
    final threeInchShukudaiCount =
        deltas[CounterCountField.threeInchShukudai] ?? 0;
    final fiveInchShukudaiCount =
        deltas[CounterCountField.fiveInchShukudai] ?? 0;

    final totalAmount = (threeInchCount * resolvedPricing.threeInchPrice) +
        (fiveInchCount * resolvedPricing.fiveInchPrice) +
        (unsignedThreeInchCount * resolvedPricing.unsignedThreeInchPrice) +
        (unsignedFiveInchCount * resolvedPricing.unsignedFiveInchPrice) +
        (groupCutCount * resolvedPricing.groupCutPrice) +
        (threeInchShukudaiCount * resolvedPricing.threeInchShukudaiPrice) +
        (fiveInchShukudaiCount * resolvedPricing.fiveInchShukudaiPrice);

    return ActivityRecordModel(
      id: id,
      type: ActivityRecordType.counter,
      source: 'local',
      sourceRecordId: null,
      counterId: counter.id,
      personId: counter.personId,
      personName: counter.personName,
      subjectName: counter.name,
      groupName: counter.groupName,
      note: note,
      occurredAt: occurredAt,
      pricingLabel: pricingLabel ?? resolvedPricing.label,
      threeInchCount: threeInchCount,
      fiveInchCount: fiveInchCount,
      unsignedThreeInchCount: unsignedThreeInchCount,
      unsignedFiveInchCount: unsignedFiveInchCount,
      groupCutCount: groupCutCount,
      threeInchShukudaiCount: threeInchShukudaiCount,
      fiveInchShukudaiCount: fiveInchShukudaiCount,
      threeInchPrice: resolvedPricing.threeInchPrice,
      fiveInchPrice: resolvedPricing.fiveInchPrice,
      unsignedThreeInchPrice: resolvedPricing.unsignedThreeInchPrice,
      unsignedFiveInchPrice: resolvedPricing.unsignedFiveInchPrice,
      groupCutPrice: resolvedPricing.groupCutPrice,
      threeInchShukudaiPrice: resolvedPricing.threeInchShukudaiPrice,
      fiveInchShukudaiPrice: resolvedPricing.fiveInchShukudaiPrice,
      totalAmount: totalAmount,
    );
  }

  factory ActivityRecordModel.ticket({
    int? id,
    required String eventName,
    required DateTime occurredAt,
    String sessionLabel = '',
    String note = '',
    int quantity = 1,
    double unitPrice = 0,
  }) {
    return ActivityRecordModel(
      id: id,
      type: ActivityRecordType.ticket,
      source: 'local',
      sourceRecordId: null,
      subjectName: eventName,
      sessionLabel: sessionLabel,
      note: note,
      occurredAt: occurredAt,
      pricingLabel: '门票',
      ticketQuantity: quantity,
      ticketUnitPrice: unitPrice,
      totalAmount: quantity * unitPrice,
    );
  }

  factory ActivityRecordModel.multiCut({
    int? id,
    required List<ActivityParticipant> participants,
    required CounterCountField field,
    required DateTime occurredAt,
    String note = '',
    String pricingLabel = '',
    int quantity = 1,
    double totalPrice = 0,
  }) {
    final normalizedQuantity =
        field == CounterCountField.groupCut ? 1 : quantity;
    final normalizedParticipants = participants
        .where((participant) => participant.memberName.trim().isNotEmpty)
        .toList(growable: false);
    final participantGroups = normalizedParticipants
        .map((participant) => participant.groupName.trim())
        .where((groupName) => groupName.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final canonicalGroupName = participantGroups.isEmpty
        ? ''
        : participantGroups.length == 1
            ? participantGroups.first
            : '跨团';

    return ActivityRecordModel(
      id: id,
      type: ActivityRecordType.multi,
      source: 'local',
      sourceRecordId: null,
      subjectName: normalizedParticipants.isNotEmpty
          ? normalizedParticipants.first.memberName
          : '',
      secondarySubjectName: normalizedParticipants.length > 1
          ? normalizedParticipants[1].memberName
          : '',
      groupName: canonicalGroupName,
      note: note,
      occurredAt: occurredAt,
      pricingLabel: pricingLabel,
      threeInchCount:
          field == CounterCountField.threeInch ? normalizedQuantity : 0,
      fiveInchCount:
          field == CounterCountField.fiveInch ? normalizedQuantity : 0,
      unsignedThreeInchCount:
          field == CounterCountField.unsignedThreeInch ? normalizedQuantity : 0,
      unsignedFiveInchCount:
          field == CounterCountField.unsignedFiveInch ? normalizedQuantity : 0,
      groupCutCount:
          field == CounterCountField.groupCut ? normalizedQuantity : 0,
      multiCutQuantity: normalizedQuantity,
      totalAmount: totalPrice,
      participants: normalizedParticipants,
    );
  }

  ActivityRecordModel copyWith({
    int? id,
    ActivityRecordType? type,
    String? source,
    String? sourceRecordId,
    int? counterId,
    int? personId,
    String? personName,
    String? subjectName,
    String? secondarySubjectName,
    String? groupName,
    String? sessionLabel,
    String? note,
    DateTime? occurredAt,
    String? pricingLabel,
    int? threeInchCount,
    int? fiveInchCount,
    int? unsignedThreeInchCount,
    int? unsignedFiveInchCount,
    int? groupCutCount,
    int? threeInchShukudaiCount,
    int? fiveInchShukudaiCount,
    int? multiCutQuantity,
    int? ticketQuantity,
    double? threeInchPrice,
    double? fiveInchPrice,
    double? unsignedThreeInchPrice,
    double? unsignedFiveInchPrice,
    double? groupCutPrice,
    double? doubleCutUnitPrice,
    double? threeInchShukudaiPrice,
    double? fiveInchShukudaiPrice,
    double? ticketUnitPrice,
    double? totalAmount,
    List<ActivityParticipant>? participants,
  }) {
    return ActivityRecordModel(
      id: id ?? this.id,
      type: type ?? this.type,
      source: source ?? this.source,
      sourceRecordId: sourceRecordId ?? this.sourceRecordId,
      counterId: counterId ?? this.counterId,
      personId: personId ?? this.personId,
      personName: personName ?? this.personName,
      subjectName: subjectName ?? this.subjectName,
      secondarySubjectName: secondarySubjectName ?? this.secondarySubjectName,
      groupName: groupName ?? this.groupName,
      sessionLabel: sessionLabel ?? this.sessionLabel,
      note: note ?? this.note,
      occurredAt: occurredAt ?? this.occurredAt,
      pricingLabel: pricingLabel ?? this.pricingLabel,
      threeInchCount: threeInchCount ?? this.threeInchCount,
      fiveInchCount: fiveInchCount ?? this.fiveInchCount,
      unsignedThreeInchCount:
          unsignedThreeInchCount ?? this.unsignedThreeInchCount,
      unsignedFiveInchCount:
          unsignedFiveInchCount ?? this.unsignedFiveInchCount,
      groupCutCount: groupCutCount ?? this.groupCutCount,
      threeInchShukudaiCount:
          threeInchShukudaiCount ?? this.threeInchShukudaiCount,
      fiveInchShukudaiCount:
          fiveInchShukudaiCount ?? this.fiveInchShukudaiCount,
      multiCutQuantity: multiCutQuantity ?? this.multiCutQuantity,
      ticketQuantity: ticketQuantity ?? this.ticketQuantity,
      threeInchPrice: threeInchPrice ?? this.threeInchPrice,
      fiveInchPrice: fiveInchPrice ?? this.fiveInchPrice,
      unsignedThreeInchPrice:
          unsignedThreeInchPrice ?? this.unsignedThreeInchPrice,
      unsignedFiveInchPrice:
          unsignedFiveInchPrice ?? this.unsignedFiveInchPrice,
      groupCutPrice: groupCutPrice ?? this.groupCutPrice,
      doubleCutUnitPrice: doubleCutUnitPrice ?? this.doubleCutUnitPrice,
      threeInchShukudaiPrice:
          threeInchShukudaiPrice ?? this.threeInchShukudaiPrice,
      fiveInchShukudaiPrice:
          fiveInchShukudaiPrice ?? this.fiveInchShukudaiPrice,
      ticketUnitPrice: ticketUnitPrice ?? this.ticketUnitPrice,
      totalAmount: totalAmount ?? this.totalAmount,
      participants: participants ?? this.participants,
    );
  }

  bool get isTicket => type == ActivityRecordType.ticket;

  bool get isMulti => type == ActivityRecordType.multi;

  bool get isDuo => isMulti;

  bool get isCounter => type == ActivityRecordType.counter;

  List<ActivityParticipant> get effectiveParticipants {
    if (participants.isNotEmpty) {
      return participants;
    }
    if (!isMulti) {
      return const <ActivityParticipant>[];
    }
    return _buildLegacyParticipants(
      subjectName: subjectName,
      secondarySubjectName: secondarySubjectName,
      groupName: groupName,
      personId: personId,
      personName: personName,
    );
  }

  int get effectiveMultiQuantity =>
      isMulti ? (multiCutQuantity > 0 ? multiCutQuantity : 1) : 0;

  int get multiParticipantCount => effectiveParticipants.length;

  CounterCountField? get multiCountField {
    for (final field in CounterCountField.multiSelectableValues) {
      if (countForField(field) > 0) {
        return field;
      }
    }
    return null;
  }

  String get multiFieldLabel => multiCountField?.label ?? '';

  int get multiTotalCount => effectiveMultiQuantity;

  int get multiContributionTotal =>
      multiParticipantCount * effectiveMultiQuantity;

  double get multiParticipantAmountShare {
    final count = multiParticipantCount;
    if (count <= 0) {
      return 0;
    }
    return totalAmount / count;
  }

  String get multiDisplayName {
    final participantNames = effectiveParticipants
        .map((participant) => participant.memberName.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (participantNames.isEmpty) {
      return subjectName;
    }
    if (participantNames.length == 1) {
      return participantNames.first;
    }
    if (participantNames.length == 2) {
      return '${participantNames.first} × ${participantNames.last}';
    }
    return '${participantNames[0]} / ${participantNames[1]} 等${participantNames.length}人';
  }

  String get duoDisplayName => multiDisplayName;

  int countForField(CounterCountField field) {
    switch (field.key) {
      case 'threeInchCount':
        return threeInchCount;
      case 'fiveInchCount':
        return fiveInchCount;
      case 'unsignedThreeInchCount':
        return unsignedThreeInchCount;
      case 'unsignedFiveInchCount':
        return unsignedFiveInchCount;
      case 'groupCutCount':
        return groupCutCount;
      case 'threeInchShukudaiCount':
        return threeInchShukudaiCount;
      case 'fiveInchShukudaiCount':
        return fiveInchShukudaiCount;
      default:
        return 0;
    }
  }

  double priceForField(CounterCountField field) {
    switch (field.key) {
      case 'threeInchCount':
        return threeInchPrice;
      case 'fiveInchCount':
        return fiveInchPrice;
      case 'unsignedThreeInchCount':
        return unsignedThreeInchPrice;
      case 'unsignedFiveInchCount':
        return unsignedFiveInchPrice;
      case 'groupCutCount':
        return groupCutPrice;
      case 'threeInchShukudaiCount':
        return threeInchShukudaiPrice;
      case 'fiveInchShukudaiCount':
        return fiveInchShukudaiPrice;
      default:
        return 0;
    }
  }

  int get counterCountTotal =>
      threeInchCount +
      fiveInchCount +
      unsignedThreeInchCount +
      unsignedFiveInchCount +
      groupCutCount +
      threeInchShukudaiCount +
      fiveInchShukudaiCount;

  int get totalUnits => switch (type) {
        ActivityRecordType.counter => counterCountTotal,
        ActivityRecordType.multi => multiTotalCount,
        ActivityRecordType.ticket => ticketQuantity,
      };

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'record_type': type.dbValue,
      'source': source,
      'source_record_id': sourceRecordId,
      'counter_id': counterId,
      'person_id': personId,
      'person_name': personName,
      'subject_name': subjectName,
      'secondary_subject_name': secondarySubjectName,
      'group_name': groupName,
      'session_label': sessionLabel,
      'note': note,
      'occurred_at': occurredAt.toIso8601String(),
      'pricing_label': pricingLabel,
      'three_inch_count': threeInchCount,
      'five_inch_count': fiveInchCount,
      'unsigned_three_inch_count': unsignedThreeInchCount,
      'unsigned_five_inch_count': unsignedFiveInchCount,
      'group_cut_count': groupCutCount,
      'three_inch_shukudai_count': threeInchShukudaiCount,
      'five_inch_shukudai_count': fiveInchShukudaiCount,
      'multi_cut_quantity': multiCutQuantity,
      'double_cut_quantity': multiCutQuantity,
      'ticket_quantity': ticketQuantity,
      'three_inch_price': threeInchPrice,
      'five_inch_price': fiveInchPrice,
      'unsigned_three_inch_price': unsignedThreeInchPrice,
      'unsigned_five_inch_price': unsignedFiveInchPrice,
      'group_cut_price': groupCutPrice,
      'double_cut_unit_price': doubleCutUnitPrice,
      'three_inch_shukudai_price': threeInchShukudaiPrice,
      'five_inch_shukudai_price': fiveInchShukudaiPrice,
      'ticket_unit_price': ticketUnitPrice,
      'total_amount': totalAmount,
      'multi_participants_json': jsonEncode(
        effectiveParticipants
            .map((participant) => participant.toMap())
            .toList(),
      ),
    };
  }

  factory ActivityRecordModel.fromMap(Map<String, Object?> map) {
    final type = ActivityRecordType.fromDb(
      (map['record_type'] ?? 'counter') as String,
    );
    final participants = _readParticipants(map['multi_participants_json']);
    final subjectName = (map['subject_name'] ?? '') as String;
    final secondarySubjectName =
        (map['secondary_subject_name'] ?? '') as String;
    final groupName = (map['group_name'] ?? '') as String;
    final personId = (map['person_id'] as num?)?.toInt();
    final personName = (map['person_name'] ?? '') as String;

    return ActivityRecordModel(
      id: (map['id'] as num?)?.toInt(),
      type: type,
      source: (map['source'] ?? 'local') as String,
      sourceRecordId: map['source_record_id'] as String?,
      counterId: (map['counter_id'] as num?)?.toInt(),
      personId: personId,
      personName: personName,
      subjectName: subjectName,
      secondarySubjectName: secondarySubjectName,
      groupName: groupName,
      sessionLabel: (map['session_label'] ?? '') as String,
      note: (map['note'] ?? '') as String,
      occurredAt: DateTime.tryParse((map['occurred_at'] ?? '') as String) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pricingLabel: (map['pricing_label'] ?? '') as String,
      threeInchCount: _readInt(map['three_inch_count']),
      fiveInchCount: _readInt(map['five_inch_count']),
      unsignedThreeInchCount: _readInt(map['unsigned_three_inch_count']),
      unsignedFiveInchCount: _readInt(map['unsigned_five_inch_count']),
      groupCutCount: _readInt(map['group_cut_count']),
      threeInchShukudaiCount: _readInt(map['three_inch_shukudai_count']),
      fiveInchShukudaiCount: _readInt(map['five_inch_shukudai_count']),
      multiCutQuantity: _readInt(
        map['multi_cut_quantity'] ?? map['double_cut_quantity'],
      ),
      ticketQuantity: _readInt(map['ticket_quantity']),
      threeInchPrice: _readDouble(map['three_inch_price']),
      fiveInchPrice: _readDouble(map['five_inch_price']),
      unsignedThreeInchPrice: _readDouble(map['unsigned_three_inch_price']),
      unsignedFiveInchPrice: _readDouble(map['unsigned_five_inch_price']),
      groupCutPrice: _readDouble(map['group_cut_price']),
      doubleCutUnitPrice: _readDouble(map['double_cut_unit_price']),
      threeInchShukudaiPrice: _readDouble(map['three_inch_shukudai_price']),
      fiveInchShukudaiPrice: _readDouble(map['five_inch_shukudai_price']),
      ticketUnitPrice: _readDouble(map['ticket_unit_price']),
      totalAmount: _readDouble(map['total_amount']),
      participants: participants.isNotEmpty || type != ActivityRecordType.multi
          ? participants
          : _buildLegacyParticipants(
              subjectName: subjectName,
              secondarySubjectName: secondarySubjectName,
              groupName: groupName,
              personId: personId,
              personName: personName,
            ),
    );
  }

  static List<ActivityParticipant> _readParticipants(Object? rawJson) {
    if (rawJson is! String || rawJson.trim().isEmpty) {
      return const <ActivityParticipant>[];
    }

    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) {
        return const <ActivityParticipant>[];
      }
      return decoded
          .whereType<Map>()
          .map((item) {
            return ActivityParticipant.fromMap(
              item.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            );
          })
          .where((participant) => participant.memberName.trim().isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <ActivityParticipant>[];
    }
  }

  static List<ActivityParticipant> _buildLegacyParticipants({
    required String subjectName,
    required String secondarySubjectName,
    required String groupName,
    required int? personId,
    required String personName,
  }) {
    final entries = <ActivityParticipant>[];
    final primary = subjectName.trim();
    if (primary.isNotEmpty) {
      entries.add(
        ActivityParticipant(
          memberName: primary,
          groupName: groupName.trim(),
          personId: personId,
          personName: personName,
        ),
      );
    }
    final secondary = secondarySubjectName.trim();
    if (secondary.isNotEmpty) {
      entries.add(
        ActivityParticipant(
          memberName: secondary,
          groupName: groupName.trim(),
        ),
      );
    }
    return entries;
  }

  static int _readInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  static double _readDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? 0;
    }
    return 0;
  }
}
