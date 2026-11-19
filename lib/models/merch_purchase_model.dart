class MerchKindModel {
  final int? id;
  final String name;
  final double defaultPrice;
  final bool isPreset;
  final int sortOrder;
  final DateTime updatedAt;

  const MerchKindModel({
    this.id,
    required this.name,
    this.defaultPrice = 0,
    this.isPreset = false,
    this.sortOrder = 0,
    required this.updatedAt,
  });

  MerchKindModel copyWith({
    int? id,
    String? name,
    double? defaultPrice,
    bool? isPreset,
    int? sortOrder,
    DateTime? updatedAt,
  }) {
    return MerchKindModel(
      id: id ?? this.id,
      name: name ?? this.name,
      defaultPrice: defaultPrice ?? this.defaultPrice,
      isPreset: isPreset ?? this.isPreset,
      sortOrder: sortOrder ?? this.sortOrder,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'default_price': defaultPrice,
      'is_preset': isPreset ? 1 : 0,
      'sort_order': sortOrder,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory MerchKindModel.fromMap(Map<String, Object?> map) {
    return MerchKindModel(
      id: (map['id'] as num?)?.toInt(),
      name: (map['name'] ?? '') as String,
      defaultPrice: _readDouble(map['default_price'] ?? map['defaultPrice']),
      isPreset: _readBool(map['is_preset'] ?? map['isPreset']),
      sortOrder: _readInt(map['sort_order'] ?? map['sortOrder']),
      updatedAt:
          DateTime.tryParse('${map['updated_at'] ?? map['updatedAt'] ?? ''}') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// One 周边 purchase. Amounts are kept as entered; [totalAmount] falls back to
/// quantity × unit price for older/hand-written rows.
class MerchPurchaseModel {
  final int? id;
  final String kind;
  final String memberName;
  final String groupName;
  final String eventName;
  final String venueName;
  final String sessionLabel;
  final String note;
  final int quantity;
  final double unitPrice;
  final double totalAmount;
  final String photoPath;
  final DateTime occurredAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const MerchPurchaseModel({
    this.id,
    required this.kind,
    this.memberName = '',
    this.groupName = '',
    this.eventName = '',
    this.venueName = '',
    this.sessionLabel = '',
    this.note = '',
    this.quantity = 1,
    this.unitPrice = 0,
    this.totalAmount = 0,
    this.photoPath = '',
    required this.occurredAt,
    this.createdAt,
    this.updatedAt,
  });

  factory MerchPurchaseModel.purchase({
    int? id,
    required String kind,
    required DateTime occurredAt,
    String memberName = '',
    String groupName = '',
    String eventName = '',
    String venueName = '',
    String sessionLabel = '',
    String note = '',
    int quantity = 1,
    double unitPrice = 0,
    double? totalAmount,
    String photoPath = '',
  }) {
    final normalizedQuantity = quantity > 0 ? quantity : 1;
    final normalizedUnitPrice = unitPrice < 0 ? 0.0 : unitPrice;
    final computedTotal = totalAmount == null || totalAmount <= 0
        ? normalizedQuantity * normalizedUnitPrice
        : totalAmount;
    final now = DateTime.now();
    return MerchPurchaseModel(
      id: id,
      kind: kind.trim(),
      memberName: memberName.trim(),
      groupName: groupName.trim(),
      eventName: eventName.trim(),
      venueName: venueName.trim(),
      sessionLabel: sessionLabel.trim(),
      note: note.trim(),
      quantity: normalizedQuantity,
      unitPrice: normalizedUnitPrice,
      totalAmount: computedTotal,
      photoPath: photoPath,
      occurredAt: occurredAt,
      createdAt: now,
      updatedAt: now,
    );
  }

  MerchPurchaseModel copyWith({
    int? id,
    String? kind,
    String? memberName,
    String? groupName,
    String? eventName,
    String? venueName,
    String? sessionLabel,
    String? note,
    int? quantity,
    double? unitPrice,
    double? totalAmount,
    String? photoPath,
    DateTime? occurredAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MerchPurchaseModel(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      memberName: memberName ?? this.memberName,
      groupName: groupName ?? this.groupName,
      eventName: eventName ?? this.eventName,
      venueName: venueName ?? this.venueName,
      sessionLabel: sessionLabel ?? this.sessionLabel,
      note: note ?? this.note,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      totalAmount: totalAmount ?? this.totalAmount,
      photoPath: photoPath ?? this.photoPath,
      occurredAt: occurredAt ?? this.occurredAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  String get kindLabel {
    final normalized = kind.trim();
    return normalized.isEmpty ? '未分类周边' : normalized;
  }

  String get memberLabel {
    final member = memberName.trim();
    final group = groupName.trim();
    if (member.isEmpty) return group;
    if (group.isEmpty) return member;
    return '$member · $group';
  }

  String get eventLabel {
    final event = eventName.trim();
    final venue = venueName.trim();
    if (event.isEmpty) return venue;
    if (venue.isEmpty) return event;
    return '$event · $venue';
  }

  double get resolvedTotalAmount {
    if (totalAmount > 0) return totalAmount;
    return quantity * unitPrice;
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'kind': kind,
      'member_name': memberName,
      'group_name': groupName,
      'event_name': eventName,
      'venue_name': venueName,
      'session_label': sessionLabel,
      'note': note,
      'quantity': quantity,
      'unit_price': unitPrice,
      'total_amount': totalAmount,
      'photo_path': photoPath,
      'occurred_at': occurredAt.toIso8601String(),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  factory MerchPurchaseModel.fromMap(Map<String, Object?> map) {
    return MerchPurchaseModel(
      id: (map['id'] as num?)?.toInt(),
      kind: (map['kind'] ?? map['type'] ?? '') as String,
      memberName: (map['member_name'] ??
          map['memberName'] ??
          map['member'] ??
          '') as String,
      groupName: (map['group_name'] ?? map['groupName']) as String? ?? '',
      eventName: (map['event_name'] ??
          map['eventName'] ??
          map['activity_name'] ??
          '') as String,
      venueName: (map['venue_name'] ?? map['venueName']) as String? ?? '',
      sessionLabel:
          (map['session_label'] ?? map['sessionLabel']) as String? ?? '',
      note: (map['note'] ?? '') as String? ?? '',
      quantity: _readInt(map['quantity']) <= 0 ? 1 : _readInt(map['quantity']),
      unitPrice: _readDouble(map['unit_price'] ?? map['unitPrice']),
      totalAmount: _readDouble(
        map['total_amount'] ?? map['totalAmount'] ?? map['total'],
      ),
      photoPath: (map['photo_path'] ?? map['photoPath']) as String? ?? '',
      occurredAt: DateTime.tryParse(
              '${map['occurred_at'] ?? map['occurredAt'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      createdAt: DateTime.tryParse(
        '${map['created_at'] ?? map['createdAt'] ?? ''}',
      ),
      updatedAt: DateTime.tryParse(
        '${map['updated_at'] ?? map['updatedAt'] ?? ''}',
      ),
    );
  }
}

class MerchStats {
  final int purchaseCount;
  final int itemCount;
  final double amount;
  final Map<String, int> countByKind;
  final Map<String, double> amountByKind;
  final Map<String, int> countByMember;
  final Map<String, double> amountByMember;
  final Map<String, int> countByMonth;
  final Map<String, double> amountByMonth;

  const MerchStats({
    this.purchaseCount = 0,
    this.itemCount = 0,
    this.amount = 0,
    this.countByKind = const {},
    this.amountByKind = const {},
    this.countByMember = const {},
    this.amountByMember = const {},
    this.countByMonth = const {},
    this.amountByMonth = const {},
  });

  static const empty = MerchStats();

  bool get isEmpty => purchaseCount == 0;

  factory MerchStats.fromPurchases(Iterable<MerchPurchaseModel> purchases) {
    var purchaseCount = 0;
    var itemCount = 0;
    var amount = 0.0;
    final countByKind = <String, int>{};
    final amountByKind = <String, double>{};
    final countByMember = <String, int>{};
    final amountByMember = <String, double>{};
    final countByMonth = <String, int>{};
    final amountByMonth = <String, double>{};

    for (final purchase in purchases) {
      final quantity = purchase.quantity > 0 ? purchase.quantity : 1;
      final total = purchase.resolvedTotalAmount;
      purchaseCount += 1;
      itemCount += quantity;
      amount += total;

      final kind = purchase.kindLabel;
      countByKind[kind] = (countByKind[kind] ?? 0) + quantity;
      amountByKind[kind] = (amountByKind[kind] ?? 0) + total;

      final member = purchase.memberName.trim().isEmpty
          ? '未关联成员'
          : purchase.memberName.trim();
      countByMember[member] = (countByMember[member] ?? 0) + quantity;
      amountByMember[member] = (amountByMember[member] ?? 0) + total;

      final month = _monthKey(purchase.occurredAt);
      countByMonth[month] = (countByMonth[month] ?? 0) + quantity;
      amountByMonth[month] = (amountByMonth[month] ?? 0) + total;
    }

    return MerchStats(
      purchaseCount: purchaseCount,
      itemCount: itemCount,
      amount: amount,
      countByKind: countByKind,
      amountByKind: amountByKind,
      countByMember: countByMember,
      amountByMember: amountByMember,
      countByMonth: countByMonth,
      amountByMonth: amountByMonth,
    );
  }

  static String _monthKey(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    return '${value.year}-$month';
  }
}

int _readInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

double _readDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

bool _readBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }
  return false;
}
