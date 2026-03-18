import 'dart:math';

import 'package:flutter/material.dart';
import 'package:lpinyin/lpinyin.dart';

class CounterCountField {
  final String key;
  final String label;
  final String shortLabel;

  const CounterCountField._(this.key, this.label, this.shortLabel);

  static const threeInch = CounterCountField._(
    'threeInchCount',
    '3寸',
    '3寸',
  );
  static const fiveInch = CounterCountField._(
    'fiveInchCount',
    '5寸',
    '5寸',
  );
  static const groupCut = CounterCountField._(
    'groupCutCount',
    '团切',
    '团切',
  );
  static const unsignedThreeInch = CounterCountField._(
    'unsignedThreeInchCount',
    '无签3寸',
    '无签3',
  );
  static const unsignedFiveInch = CounterCountField._(
    'unsignedFiveInchCount',
    '无签5寸',
    '无签5',
  );
  static const threeInchShukudai = CounterCountField._(
    'threeInchShukudaiCount',
    '3寸宿题',
    '3寸宿',
  );
  static const fiveInchShukudai = CounterCountField._(
    'fiveInchShukudaiCount',
    '5寸宿题',
    '5寸宿',
  );

  static const List<CounterCountField> values = [
    threeInch,
    fiveInch,
    unsignedThreeInch,
    unsignedFiveInch,
    threeInchShukudai,
    fiveInchShukudai,
    groupCut,
  ];

  static const List<CounterCountField> signedPhotoValues = [
    threeInch,
    fiveInch,
  ];

  static const List<CounterCountField> unsignedPhotoValues = [
    unsignedThreeInch,
    unsignedFiveInch,
  ];

  static const List<CounterCountField> multiSelectableValues = [
    threeInch,
    fiveInch,
    unsignedThreeInch,
    unsignedFiveInch,
    groupCut,
  ];

  bool get isUnsigned => this == unsignedThreeInch || this == unsignedFiveInch;

  bool get isPhoto =>
      this == threeInch ||
      this == fiveInch ||
      this == unsignedThreeInch ||
      this == unsignedFiveInch ||
      this == threeInchShukudai ||
      this == fiveInchShukudai;

  CounterCountField get aggregatedBaseField {
    if (this == unsignedThreeInch) {
      return threeInch;
    }
    if (this == unsignedFiveInch) {
      return fiveInch;
    }
    return this;
  }

  static List<CounterCountField> visibleValues({
    required bool enableUnsigned,
    bool includeGroupCut = true,
  }) {
    return [
      threeInch,
      fiveInch,
      if (enableUnsigned) ...unsignedPhotoValues,
      threeInchShukudai,
      fiveInchShukudai,
      if (includeGroupCut) groupCut,
    ];
  }

  static List<CounterCountField> multiVisibleValues({
    required bool enableUnsigned,
  }) {
    return [
      ...signedPhotoValues,
      if (enableUnsigned) ...unsignedPhotoValues,
    ];
  }
}

class CounterModel {
  final int? id;
  final String name;
  final String groupName;
  final int? personId;
  final String personName;
  final String color;
  final bool isHidden;
  final int threeInchCount;
  final int fiveInchCount;
  final int unsignedThreeInchCount;
  final int unsignedFiveInchCount;
  final int groupCutCount;
  final int threeInchShukudaiCount;
  final int fiveInchShukudaiCount;
  final String namePinyin;

  CounterModel({
    this.id,
    required this.name,
    this.groupName = '',
    this.personId,
    this.personName = '',
    required this.color,
    this.isHidden = false,
    this.threeInchCount = 0,
    this.fiveInchCount = 0,
    this.unsignedThreeInchCount = 0,
    this.unsignedFiveInchCount = 0,
    this.groupCutCount = 0,
    this.threeInchShukudaiCount = 0,
    this.fiveInchShukudaiCount = 0,
  }) : namePinyin = PinyinHelper.getPinyinE(
          name,
          defPinyin: '#',
          format: PinyinFormat.WITHOUT_TONE,
        );

  int get count =>
      threeInchCount +
      fiveInchCount +
      unsignedThreeInchCount +
      unsignedFiveInchCount +
      groupCutCount +
      threeInchShukudaiCount +
      fiveInchShukudaiCount;

  int get aggregatedThreeInchCount => threeInchCount + unsignedThreeInchCount;

  int get aggregatedFiveInchCount => fiveInchCount + unsignedFiveInchCount;

  bool get hasUnsignedCounts =>
      unsignedThreeInchCount > 0 || unsignedFiveInchCount > 0;

  CounterModel copyWith({
    int? id,
    String? name,
    String? groupName,
    int? personId,
    String? personName,
    String? color,
    bool? isHidden,
    int? threeInchCount,
    int? fiveInchCount,
    int? unsignedThreeInchCount,
    int? unsignedFiveInchCount,
    int? groupCutCount,
    int? threeInchShukudaiCount,
    int? fiveInchShukudaiCount,
  }) {
    return CounterModel(
      id: id ?? this.id,
      name: name ?? this.name,
      groupName: groupName ?? this.groupName,
      personId: personId ?? this.personId,
      personName: personName ?? this.personName,
      color: color ?? this.color,
      isHidden: isHidden ?? this.isHidden,
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
    );
  }

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

  CounterModel updateCount(CounterCountField field, int value) {
    final safeValue = max(0, value);
    switch (field.key) {
      case 'threeInchCount':
        return copyWith(threeInchCount: safeValue);
      case 'fiveInchCount':
        return copyWith(fiveInchCount: safeValue);
      case 'unsignedThreeInchCount':
        return copyWith(unsignedThreeInchCount: safeValue);
      case 'unsignedFiveInchCount':
        return copyWith(unsignedFiveInchCount: safeValue);
      case 'groupCutCount':
        return copyWith(groupCutCount: safeValue);
      case 'threeInchShukudaiCount':
        return copyWith(threeInchShukudaiCount: safeValue);
      case 'fiveInchShukudaiCount':
        return copyWith(fiveInchShukudaiCount: safeValue);
      default:
        return this;
    }
  }

  CounterModel changeCount(CounterCountField field, int delta) {
    return updateCount(field, countForField(field) + delta);
  }

  List<MapEntry<CounterCountField, int>> get countEntries {
    return CounterCountField.values
        .map((field) => MapEntry(field, countForField(field)))
        .toList();
  }

  Color get colorValue {
    if (!color.startsWith('#') || color.length != 7) {
      return Colors.yellow;
    }
    try {
      final colorValue = int.parse('FF${color.substring(1)}', radix: 16);
      return Color(colorValue);
    } catch (e) {
      return Colors.yellow;
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'groupName': groupName,
      'personId': personId,
      'personName': personName,
      'count': count,
      'color': color,
      'isHidden': isHidden,
      'threeInchCount': threeInchCount,
      'fiveInchCount': fiveInchCount,
      'unsignedThreeInchCount': unsignedThreeInchCount,
      'unsignedFiveInchCount': unsignedFiveInchCount,
      'groupCutCount': groupCutCount,
      'threeInchShukudaiCount': threeInchShukudaiCount,
      'fiveInchShukudaiCount': fiveInchShukudaiCount,
    };
  }

  factory CounterModel.fromMap(Map<String, dynamic> map) {
    final legacyCount = _readInt(map, ['count']);

    return CounterModel(
      id: _readNullableInt(map, ['id']),
      name: (map['name'] ?? '') as String,
      groupName: (map['groupName'] ?? map['group_name'] ?? '') as String,
      personId: _readNullableInt(map, ['personId', 'person_id']),
      personName: (map['personName'] ?? map['person_name'] ?? '') as String,
      color: (map['color'] ?? '#FFE135') as String,
      isHidden: _readBool(map, ['isHidden', 'is_hidden']),
      threeInchCount: _readInt(
        map,
        ['threeInchCount', 'three_inch_count'],
        fallback: legacyCount,
      ),
      fiveInchCount: _readInt(map, ['fiveInchCount', 'five_inch_count']),
      unsignedThreeInchCount: _readInt(
        map,
        ['unsignedThreeInchCount', 'unsigned_three_inch_count'],
      ),
      unsignedFiveInchCount: _readInt(
        map,
        ['unsignedFiveInchCount', 'unsigned_five_inch_count'],
      ),
      groupCutCount: _readInt(map, ['groupCutCount', 'group_cut_count']),
      threeInchShukudaiCount: _readInt(
        map,
        ['threeInchShukudaiCount', 'three_inch_shukudai_count'],
      ),
      fiveInchShukudaiCount: _readInt(
        map,
        ['fiveInchShukudaiCount', 'five_inch_shukudai_count'],
      ),
    );
  }

  HSVColor get hsvColor {
    return HSVColor.fromColor(colorValue);
  }

  static int _readInt(
    Map<String, dynamic> map,
    List<String> keys, {
    int fallback = 0,
  }) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) {
        continue;
      }
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return fallback;
  }

  static int? _readNullableInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) {
        continue;
      }
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
  }

  static bool _readBool(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) {
        continue;
      }
      if (value is bool) {
        return value;
      }
      if (value is int) {
        return value != 0;
      }
      if (value is num) {
        return value.toInt() != 0;
      }
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == '1') {
          return true;
        }
        if (normalized == 'false' || normalized == '0') {
          return false;
        }
      }
    }
    return false;
  }
}
