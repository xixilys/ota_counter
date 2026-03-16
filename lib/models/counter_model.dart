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
    groupCut,
    threeInchShukudai,
    fiveInchShukudai,
  ];
}

class CounterModel {
  final int? id;
  final String name;
  final String color;
  final int threeInchCount;
  final int fiveInchCount;
  final int groupCutCount;
  final int threeInchShukudaiCount;
  final int fiveInchShukudaiCount;
  final String namePinyin;

  CounterModel({
    this.id,
    required this.name,
    required this.color,
    this.threeInchCount = 0,
    this.fiveInchCount = 0,
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
      groupCutCount +
      threeInchShukudaiCount +
      fiveInchShukudaiCount;

  CounterModel copyWith({
    int? id,
    String? name,
    String? color,
    int? threeInchCount,
    int? fiveInchCount,
    int? groupCutCount,
    int? threeInchShukudaiCount,
    int? fiveInchShukudaiCount,
  }) {
    return CounterModel(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      threeInchCount: threeInchCount ?? this.threeInchCount,
      fiveInchCount: fiveInchCount ?? this.fiveInchCount,
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
      'count': count,
      'color': color,
      'threeInchCount': threeInchCount,
      'fiveInchCount': fiveInchCount,
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
      color: (map['color'] ?? '#FFE135') as String,
      threeInchCount: _readInt(
        map,
        ['threeInchCount', 'three_inch_count'],
        fallback: legacyCount,
      ),
      fiveInchCount: _readInt(map, ['fiveInchCount', 'five_inch_count']),
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
}
