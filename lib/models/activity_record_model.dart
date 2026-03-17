import 'counter_model.dart';
import 'group_pricing_model.dart';

enum ActivityRecordType {
  counter,
  ticket;

  String get dbValue => switch (this) {
        ActivityRecordType.counter => 'counter',
        ActivityRecordType.ticket => 'ticket',
      };

  static ActivityRecordType fromDb(String value) {
    return switch (value) {
      'ticket' => ActivityRecordType.ticket,
      _ => ActivityRecordType.counter,
    };
  }
}

class ActivityRecordModel {
  final int? id;
  final ActivityRecordType type;
  final String source;
  final String? sourceRecordId;
  final int? counterId;
  final String subjectName;
  final String groupName;
  final String sessionLabel;
  final String note;
  final DateTime occurredAt;
  final String pricingLabel;
  final int threeInchCount;
  final int fiveInchCount;
  final int groupCutCount;
  final int threeInchShukudaiCount;
  final int fiveInchShukudaiCount;
  final int ticketQuantity;
  final double threeInchPrice;
  final double fiveInchPrice;
  final double groupCutPrice;
  final double threeInchShukudaiPrice;
  final double fiveInchShukudaiPrice;
  final double ticketUnitPrice;
  final double totalAmount;

  const ActivityRecordModel({
    this.id,
    required this.type,
    this.source = 'local',
    this.sourceRecordId,
    this.counterId,
    required this.subjectName,
    this.groupName = '',
    this.sessionLabel = '',
    this.note = '',
    required this.occurredAt,
    this.pricingLabel = '',
    this.threeInchCount = 0,
    this.fiveInchCount = 0,
    this.groupCutCount = 0,
    this.threeInchShukudaiCount = 0,
    this.fiveInchShukudaiCount = 0,
    this.ticketQuantity = 0,
    this.threeInchPrice = 0,
    this.fiveInchPrice = 0,
    this.groupCutPrice = 0,
    this.threeInchShukudaiPrice = 0,
    this.fiveInchShukudaiPrice = 0,
    this.ticketUnitPrice = 0,
    required this.totalAmount,
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
    final groupCutCount = deltas[CounterCountField.groupCut] ?? 0;
    final threeInchShukudaiCount =
        deltas[CounterCountField.threeInchShukudai] ?? 0;
    final fiveInchShukudaiCount =
        deltas[CounterCountField.fiveInchShukudai] ?? 0;

    final totalAmount = (threeInchCount * resolvedPricing.threeInchPrice) +
        (fiveInchCount * resolvedPricing.fiveInchPrice) +
        (groupCutCount * resolvedPricing.groupCutPrice) +
        (threeInchShukudaiCount * resolvedPricing.threeInchShukudaiPrice) +
        (fiveInchShukudaiCount * resolvedPricing.fiveInchShukudaiPrice);

    return ActivityRecordModel(
      id: id,
      type: ActivityRecordType.counter,
      source: 'local',
      sourceRecordId: null,
      counterId: counter.id,
      subjectName: counter.name,
      groupName: counter.groupName,
      note: note,
      occurredAt: occurredAt,
      pricingLabel: pricingLabel ?? resolvedPricing.label,
      threeInchCount: threeInchCount,
      fiveInchCount: fiveInchCount,
      groupCutCount: groupCutCount,
      threeInchShukudaiCount: threeInchShukudaiCount,
      fiveInchShukudaiCount: fiveInchShukudaiCount,
      threeInchPrice: resolvedPricing.threeInchPrice,
      fiveInchPrice: resolvedPricing.fiveInchPrice,
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

  ActivityRecordModel copyWith({
    int? id,
    ActivityRecordType? type,
    String? source,
    String? sourceRecordId,
    int? counterId,
    String? subjectName,
    String? groupName,
    String? sessionLabel,
    String? note,
    DateTime? occurredAt,
    String? pricingLabel,
    int? threeInchCount,
    int? fiveInchCount,
    int? groupCutCount,
    int? threeInchShukudaiCount,
    int? fiveInchShukudaiCount,
    int? ticketQuantity,
    double? threeInchPrice,
    double? fiveInchPrice,
    double? groupCutPrice,
    double? threeInchShukudaiPrice,
    double? fiveInchShukudaiPrice,
    double? ticketUnitPrice,
    double? totalAmount,
  }) {
    return ActivityRecordModel(
      id: id ?? this.id,
      type: type ?? this.type,
      source: source ?? this.source,
      sourceRecordId: sourceRecordId ?? this.sourceRecordId,
      counterId: counterId ?? this.counterId,
      subjectName: subjectName ?? this.subjectName,
      groupName: groupName ?? this.groupName,
      sessionLabel: sessionLabel ?? this.sessionLabel,
      note: note ?? this.note,
      occurredAt: occurredAt ?? this.occurredAt,
      pricingLabel: pricingLabel ?? this.pricingLabel,
      threeInchCount: threeInchCount ?? this.threeInchCount,
      fiveInchCount: fiveInchCount ?? this.fiveInchCount,
      groupCutCount: groupCutCount ?? this.groupCutCount,
      threeInchShukudaiCount:
          threeInchShukudaiCount ?? this.threeInchShukudaiCount,
      fiveInchShukudaiCount:
          fiveInchShukudaiCount ?? this.fiveInchShukudaiCount,
      ticketQuantity: ticketQuantity ?? this.ticketQuantity,
      threeInchPrice: threeInchPrice ?? this.threeInchPrice,
      fiveInchPrice: fiveInchPrice ?? this.fiveInchPrice,
      groupCutPrice: groupCutPrice ?? this.groupCutPrice,
      threeInchShukudaiPrice:
          threeInchShukudaiPrice ?? this.threeInchShukudaiPrice,
      fiveInchShukudaiPrice:
          fiveInchShukudaiPrice ?? this.fiveInchShukudaiPrice,
      ticketUnitPrice: ticketUnitPrice ?? this.ticketUnitPrice,
      totalAmount: totalAmount ?? this.totalAmount,
    );
  }

  bool get isTicket => type == ActivityRecordType.ticket;

  int countForField(CounterCountField field) {
    switch (field.key) {
      case 'threeInchCount':
        return threeInchCount;
      case 'fiveInchCount':
        return fiveInchCount;
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
      groupCutCount +
      threeInchShukudaiCount +
      fiveInchShukudaiCount;

  int get totalUnits => isTicket ? ticketQuantity : counterCountTotal;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'record_type': type.dbValue,
      'source': source,
      'source_record_id': sourceRecordId,
      'counter_id': counterId,
      'subject_name': subjectName,
      'group_name': groupName,
      'session_label': sessionLabel,
      'note': note,
      'occurred_at': occurredAt.toIso8601String(),
      'pricing_label': pricingLabel,
      'three_inch_count': threeInchCount,
      'five_inch_count': fiveInchCount,
      'group_cut_count': groupCutCount,
      'three_inch_shukudai_count': threeInchShukudaiCount,
      'five_inch_shukudai_count': fiveInchShukudaiCount,
      'ticket_quantity': ticketQuantity,
      'three_inch_price': threeInchPrice,
      'five_inch_price': fiveInchPrice,
      'group_cut_price': groupCutPrice,
      'three_inch_shukudai_price': threeInchShukudaiPrice,
      'five_inch_shukudai_price': fiveInchShukudaiPrice,
      'ticket_unit_price': ticketUnitPrice,
      'total_amount': totalAmount,
    };
  }

  factory ActivityRecordModel.fromMap(Map<String, Object?> map) {
    return ActivityRecordModel(
      id: (map['id'] as num?)?.toInt(),
      type: ActivityRecordType.fromDb(
        (map['record_type'] ?? 'counter') as String,
      ),
      source: (map['source'] ?? 'local') as String,
      sourceRecordId: map['source_record_id'] as String?,
      counterId: (map['counter_id'] as num?)?.toInt(),
      subjectName: (map['subject_name'] ?? '') as String,
      groupName: (map['group_name'] ?? '') as String,
      sessionLabel: (map['session_label'] ?? '') as String,
      note: (map['note'] ?? '') as String,
      occurredAt: DateTime.tryParse((map['occurred_at'] ?? '') as String) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pricingLabel: (map['pricing_label'] ?? '') as String,
      threeInchCount: _readInt(map['three_inch_count']),
      fiveInchCount: _readInt(map['five_inch_count']),
      groupCutCount: _readInt(map['group_cut_count']),
      threeInchShukudaiCount: _readInt(map['three_inch_shukudai_count']),
      fiveInchShukudaiCount: _readInt(map['five_inch_shukudai_count']),
      ticketQuantity: _readInt(map['ticket_quantity']),
      threeInchPrice: _readDouble(map['three_inch_price']),
      fiveInchPrice: _readDouble(map['five_inch_price']),
      groupCutPrice: _readDouble(map['group_cut_price']),
      threeInchShukudaiPrice: _readDouble(map['three_inch_shukudai_price']),
      fiveInchShukudaiPrice: _readDouble(map['five_inch_shukudai_price']),
      ticketUnitPrice: _readDouble(map['ticket_unit_price']),
      totalAmount: _readDouble(map['total_amount']),
    );
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
