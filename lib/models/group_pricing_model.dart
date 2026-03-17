import 'counter_model.dart';

class GroupPricingModel {
  final int? id;
  final String groupName;
  final String label;
  final double threeInchPrice;
  final double fiveInchPrice;
  final double groupCutPrice;
  final double doubleCutPrice;
  final double threeInchShukudaiPrice;
  final double fiveInchShukudaiPrice;
  final DateTime updatedAt;

  const GroupPricingModel({
    this.id,
    required this.groupName,
    required this.label,
    this.threeInchPrice = 0,
    this.fiveInchPrice = 0,
    this.groupCutPrice = 0,
    this.doubleCutPrice = 0,
    this.threeInchShukudaiPrice = 0,
    this.fiveInchShukudaiPrice = 0,
    required this.updatedAt,
  });

  factory GroupPricingModel.unconfigured(String groupName) {
    return GroupPricingModel(
      groupName: groupName,
      label: '未配置价格',
      updatedAt: DateTime.now(),
    );
  }

  GroupPricingModel copyWith({
    int? id,
    String? groupName,
    String? label,
    double? threeInchPrice,
    double? fiveInchPrice,
    double? groupCutPrice,
    double? doubleCutPrice,
    double? threeInchShukudaiPrice,
    double? fiveInchShukudaiPrice,
    DateTime? updatedAt,
  }) {
    return GroupPricingModel(
      id: id ?? this.id,
      groupName: groupName ?? this.groupName,
      label: label ?? this.label,
      threeInchPrice: threeInchPrice ?? this.threeInchPrice,
      fiveInchPrice: fiveInchPrice ?? this.fiveInchPrice,
      groupCutPrice: groupCutPrice ?? this.groupCutPrice,
      doubleCutPrice: doubleCutPrice ?? this.doubleCutPrice,
      threeInchShukudaiPrice:
          threeInchShukudaiPrice ?? this.threeInchShukudaiPrice,
      fiveInchShukudaiPrice:
          fiveInchShukudaiPrice ?? this.fiveInchShukudaiPrice,
      updatedAt: updatedAt ?? this.updatedAt,
    );
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

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'group_name': groupName,
      'label': label,
      'three_inch_price': threeInchPrice,
      'five_inch_price': fiveInchPrice,
      'group_cut_price': groupCutPrice,
      'double_cut_price': doubleCutPrice,
      'three_inch_shukudai_price': threeInchShukudaiPrice,
      'five_inch_shukudai_price': fiveInchShukudaiPrice,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory GroupPricingModel.fromMap(Map<String, Object?> map) {
    return GroupPricingModel(
      id: (map['id'] as num?)?.toInt(),
      groupName: (map['group_name'] ?? map['groupName'] ?? '') as String,
      label: (map['label'] ?? '') as String,
      threeInchPrice: _readDouble(map, 'three_inch_price'),
      fiveInchPrice: _readDouble(map, 'five_inch_price'),
      groupCutPrice: _readDouble(map, 'group_cut_price'),
      doubleCutPrice: _readDouble(map, 'double_cut_price'),
      threeInchShukudaiPrice: _readDouble(map, 'three_inch_shukudai_price'),
      fiveInchShukudaiPrice: _readDouble(map, 'five_inch_shukudai_price'),
      updatedAt: DateTime.tryParse((map['updated_at'] ?? '') as String) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  static double _readDouble(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value) ?? 0;
    }
    return 0;
  }
}
