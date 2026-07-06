import 'dart:convert';

class CustomChekiTypeModel {
  final String id;
  final String label;
  final double unitPrice;

  const CustomChekiTypeModel({
    required this.id,
    required this.label,
    required this.unitPrice,
  });

  CustomChekiTypeModel copyWith({
    String? id,
    String? label,
    double? unitPrice,
  }) {
    return CustomChekiTypeModel(
      id: id ?? this.id,
      label: label ?? this.label,
      unitPrice: unitPrice ?? this.unitPrice,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'label': label,
      'unit_price': unitPrice,
    };
  }

  factory CustomChekiTypeModel.fromMap(Map<String, Object?> map) {
    return CustomChekiTypeModel(
      id: (map['id'] ?? '') as String,
      label: (map['label'] ?? '') as String,
      unitPrice: _readDouble(map['unit_price']),
    );
  }

  static List<CustomChekiTypeModel> fromJsonString(Object? rawJson) {
    if (rawJson is! String || rawJson.trim().isEmpty) {
      return const <CustomChekiTypeModel>[];
    }

    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) {
        return const <CustomChekiTypeModel>[];
      }

      return decoded.whereType<Map>().map((item) {
        return CustomChekiTypeModel.fromMap(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
      }).where((item) {
        return item.id.trim().isNotEmpty && item.label.trim().isNotEmpty;
      }).toList(growable: false);
    } catch (_) {
      return const <CustomChekiTypeModel>[];
    }
  }

  static String encodeList(List<CustomChekiTypeModel> items) {
    return jsonEncode(items.map((item) => item.toMap()).toList());
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

class ActivityRecordCustomChekiCount {
  final String typeId;
  final String label;
  final int count;
  final double unitPrice;

  const ActivityRecordCustomChekiCount({
    required this.typeId,
    required this.label,
    required this.count,
    required this.unitPrice,
  });

  ActivityRecordCustomChekiCount copyWith({
    String? typeId,
    String? label,
    int? count,
    double? unitPrice,
  }) {
    return ActivityRecordCustomChekiCount(
      typeId: typeId ?? this.typeId,
      label: label ?? this.label,
      count: count ?? this.count,
      unitPrice: unitPrice ?? this.unitPrice,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'type_id': typeId,
      'label': label,
      'count': count,
      'unit_price': unitPrice,
    };
  }

  factory ActivityRecordCustomChekiCount.fromMap(Map<String, Object?> map) {
    return ActivityRecordCustomChekiCount(
      typeId: (map['type_id'] ?? map['typeId'] ?? '') as String,
      label: (map['label'] ?? '') as String,
      count: _readInt(map['count']),
      unitPrice: _readDouble(map['unit_price'] ?? map['unitPrice']),
    );
  }

  static List<ActivityRecordCustomChekiCount> fromJsonString(Object? rawJson) {
    if (rawJson is! String || rawJson.trim().isEmpty) {
      return const <ActivityRecordCustomChekiCount>[];
    }

    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! List) {
        return const <ActivityRecordCustomChekiCount>[];
      }

      return decoded.whereType<Map>().map((item) {
        return ActivityRecordCustomChekiCount.fromMap(
          item.map((key, value) => MapEntry(key.toString(), value)),
        );
      }).where((item) {
        return item.typeId.trim().isNotEmpty && item.count > 0;
      }).toList(growable: false);
    } catch (_) {
      return const <ActivityRecordCustomChekiCount>[];
    }
  }

  static String encodeList(List<ActivityRecordCustomChekiCount> items) {
    return jsonEncode(items.map((item) => item.toMap()).toList());
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
