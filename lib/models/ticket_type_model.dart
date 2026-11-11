import 'activity_record_model.dart';

class TicketTypeModel {
  final int? id;
  final String name;
  final double defaultPrice;
  final bool isFree;
  final int sortOrder;
  final DateTime updatedAt;

  const TicketTypeModel({
    this.id,
    required this.name,
    this.defaultPrice = 0,
    this.isFree = false,
    this.sortOrder = 0,
    required this.updatedAt,
  });

  TicketTypeModel copyWith({
    int? id,
    String? name,
    double? defaultPrice,
    bool? isFree,
    int? sortOrder,
    DateTime? updatedAt,
  }) {
    return TicketTypeModel(
      id: id ?? this.id,
      name: name ?? this.name,
      defaultPrice: defaultPrice ?? this.defaultPrice,
      isFree: isFree ?? this.isFree,
      sortOrder: sortOrder ?? this.sortOrder,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'default_price': defaultPrice,
      'is_free': isFree ? 1 : 0,
      'sort_order': sortOrder,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory TicketTypeModel.fromMap(Map<String, Object?> map) {
    return TicketTypeModel(
      id: (map['id'] as num?)?.toInt(),
      name: (map['name'] ?? '') as String,
      defaultPrice: (map['default_price'] as num?)?.toDouble() ?? 0,
      isFree: ((map['is_free'] as num?)?.toInt() ?? 0) == 1,
      sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse('${map['updated_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class TicketPricePreset {
  final int? id;
  final String scopeKey;
  final String eventName;
  final String venueName;
  final String groupName;
  final String ticketType;
  final double unitPrice;
  final bool isFree;
  final DateTime updatedAt;

  const TicketPricePreset({
    this.id,
    required this.scopeKey,
    this.eventName = '',
    this.venueName = '',
    this.groupName = '',
    required this.ticketType,
    required this.unitPrice,
    required this.isFree,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'scope_key': scopeKey,
      'event_name': eventName,
      'venue_name': venueName,
      'group_name': groupName,
      'ticket_type': ticketType,
      'unit_price': unitPrice,
      'is_free': isFree ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory TicketPricePreset.fromMap(Map<String, Object?> map) {
    return TicketPricePreset(
      id: (map['id'] as num?)?.toInt(),
      scopeKey: (map['scope_key'] ?? '') as String,
      eventName: (map['event_name'] ?? '') as String,
      venueName: (map['venue_name'] ?? '') as String,
      groupName: (map['group_name'] ?? '') as String,
      ticketType: (map['ticket_type'] ?? '') as String,
      unitPrice: (map['unit_price'] as num?)?.toDouble() ?? 0,
      isFree: ((map['is_free'] as num?)?.toInt() ?? 0) == 1,
      updatedAt: DateTime.tryParse('${map['updated_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

class TicketPriceSuggestion {
  final double unitPrice;
  final bool isFree;
  final String source;

  const TicketPriceSuggestion({
    required this.unitPrice,
    required this.isFree,
    required this.source,
  });
}

class TicketStats {
  final int recordCount;
  final int ticketCount;
  final int freeTicketCount;
  final int paidTicketCount;
  final double amount;
  final Map<String, int> countByType;
  final Map<String, double> amountByType;

  const TicketStats({
    this.recordCount = 0,
    this.ticketCount = 0,
    this.freeTicketCount = 0,
    this.paidTicketCount = 0,
    this.amount = 0,
    this.countByType = const {},
    this.amountByType = const {},
  });

  static const empty = TicketStats();

  bool get isEmpty => recordCount == 0 && ticketCount == 0;

  factory TicketStats.fromRecords(
    Iterable<ActivityRecordModel> records, {
    double Function(ActivityRecordModel record)? amountResolver,
  }) {
    var recordCount = 0;
    var ticketCount = 0;
    var freeTicketCount = 0;
    var paidTicketCount = 0;
    var amount = 0.0;
    final countByType = <String, int>{};
    final amountByType = <String, double>{};

    for (final record in records) {
      if (!record.isTicket) {
        continue;
      }
      recordCount += 1;
      final quantity = record.ticketQuantity > 0 ? record.ticketQuantity : 0;
      ticketCount += quantity;
      if (record.resolvedTicketIsFree) {
        freeTicketCount += quantity;
      } else {
        paidTicketCount += quantity;
      }
      final recordAmount = amountResolver?.call(record) ?? record.totalAmount;
      amount += recordAmount;
      final type = record.ticketTypeLabel;
      countByType[type] = (countByType[type] ?? 0) + quantity;
      amountByType[type] = (amountByType[type] ?? 0) + recordAmount;
    }

    return TicketStats(
      recordCount: recordCount,
      ticketCount: ticketCount,
      freeTicketCount: freeTicketCount,
      paidTicketCount: paidTicketCount,
      amount: amount,
      countByType: countByType,
      amountByType: amountByType,
    );
  }
}
