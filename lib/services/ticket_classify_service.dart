import '../models/activity_record_model.dart';
import '../models/ticket_type_model.dart';

class TicketTypeSuggestion {
  final String typeName;
  final String reason;

  const TicketTypeSuggestion({
    required this.typeName,
    required this.reason,
  });
}

/// One batch of uncategorised tickets that can be classified in a single tap.
///
/// Tickets are grouped by suggested type first and unit price second, so a
/// ledger of 26 tickets from 25 different events collapses into a handful of
/// "this price is the early-bird ticket" groups. The event / venue / date of
/// each ticket stays visible as row details inside the group.
class TicketClassifyGroup {
  final String eventName;
  final String venueName;
  final DateTime occurredAt;
  final double unitPrice;
  final List<ActivityRecordModel> records;
  final TicketTypeSuggestion? suggestion;
  final String suggestionReason;
  final Map<int, TicketTypeSuggestion> suggestionsByRecordId;

  /// The suggested type shared by this group, or null when the user must pick.
  final String? suggestedTypeName;

  const TicketClassifyGroup({
    required this.eventName,
    required this.venueName,
    required this.occurredAt,
    required this.unitPrice,
    required this.records,
    this.suggestion,
    this.suggestionReason = '按场次和票价手动选择',
    this.suggestionsByRecordId = const {},
    this.suggestedTypeName,
  });

  /// Distinct event labels inside this group, newest first. Shown as a
  /// one-line summary so several events per group stay understandable.
  List<String> get eventLabels {
    final labels = <String>[];
    for (final record in records) {
      final label = record.resolvedActivityName.trim().isEmpty
          ? (record.subjectName.trim().isEmpty
              ? '未命名场次'
              : record.subjectName.trim())
          : record.resolvedActivityName.trim();
      if (!labels.contains(label)) {
        labels.add(label);
      }
    }
    return labels;
  }

  List<String> get dateLabels {
    final labels = <String>[];
    for (final record in records) {
      final date = record.occurredAt;
      final label = '${date.year}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
      if (!labels.contains(label)) {
        labels.add(label);
      }
    }
    return labels;
  }

  int get quantity => records.fold<int>(
        0,
        (sum, record) =>
            sum + (record.ticketQuantity > 0 ? record.ticketQuantity : 0),
      );

  double get amount =>
      records.fold<double>(0, (sum, record) => sum + record.totalAmount);

  bool get hasSuggestion => suggestion != null;

  List<int> get suggestedRecordIds {
    final suggested = suggestion?.typeName;
    if (suggested == null) return const [];
    return records
        .map((record) => record.id)
        .whereType<int>()
        .where((id) => suggestionsByRecordId[id]?.typeName == suggested)
        .toList(growable: false);
  }

  TicketTypeSuggestion? suggestionForRecord(int? id) {
    if (id == null) return null;
    return suggestionsByRecordId[id];
  }
}

/// Pure, synchronous ticket-type suggestion and grouping helpers.
///
/// The rules are intentionally conservative: an empty result means "let the
/// user choose", never a silently wrong classification. The order is
/// free/nominal → text keywords → matching default price.
class TicketClassifyService {
  static const Map<String, List<String>> keywordRules = {
    '免费票': ['免费', '无料', '赠票', '招待', '0元'],
    '早鸟票': ['早鸟'],
    '预售票': ['预售', '预购', '提前'],
    '现场票': ['现场', '当日'],
    '学生票': ['学生', '学票'],
    '女性票': ['女性', '女生', '女士', 'girls'],
    '特典票': ['特典', '福利', '限定'],
    'VIP票': ['vip', '贵宾', '前排', '优先'],
    '双人票': ['双人', '情侣', '二人'],
    '通票': ['通票', '两日', '双日'],
  };

  static TicketTypeSuggestion? suggestType(
    ActivityRecordModel record,
    List<TicketTypeModel> types,
  ) {
    if (!record.isTicket) return null;
    final explicit = record.ticketType.trim();
    if (explicit.isNotEmpty) {
      final existing = _findType(types, explicit);
      if (existing != null) {
        return TicketTypeSuggestion(typeName: existing.name, reason: '已填票种');
      }
    }

    if (record.resolvedTicketIsFree) {
      final freeType = _firstFreeType(types);
      if (freeType != null) {
        return TicketTypeSuggestion(typeName: freeType.name, reason: '免费场次');
      }
    }

    final haystack = [
      record.resolvedActivityName,
      record.subjectName,
      record.venueName,
      record.sessionLabel,
      record.note,
    ].join(' ').toLowerCase();
    for (final entry in keywordRules.entries) {
      final type = _findType(types, entry.key);
      if (type == null) continue;
      for (final keyword in entry.value) {
        if (haystack.contains(keyword.toLowerCase())) {
          return TicketTypeSuggestion(
            typeName: type.name,
            reason: '文字含「$keyword」',
          );
        }
      }
    }

    final unitPrice = record.ticketUnitPrice;
    if (unitPrice > 0) {
      for (final type in types) {
        if (type.isFree) continue;
        if (_samePrice(type.defaultPrice, unitPrice)) {
          return TicketTypeSuggestion(
            typeName: type.name,
            reason: '价格等于「${type.name}」默认价',
          );
        }
      }
    }

    return null;
  }

  static List<TicketClassifyGroup> groupRecords(
    Iterable<ActivityRecordModel> records,
    List<TicketTypeModel> types,
  ) {
    final buckets = <String, _GroupBuilder>{};
    for (final record in records) {
      if (!record.isTicket) continue;
      final suggestion = suggestType(record, types);
      // Suggested type first, then the price it was paid for. Both are what
      // the user actually decides ("these ¥86 were early-bird"), while the
      // event and date only describe the individual ticket.
      final key = suggestion == null
          ? '|${(record.ticketUnitPrice * 100).round()}'
          : '${suggestion.typeName}|${(record.ticketUnitPrice * 100).round()}';
      buckets
          .putIfAbsent(key, () => _GroupBuilder(record, suggestion))
          .add(record);
    }

    final groups = <TicketClassifyGroup>[];
    for (final builder in buckets.values) {
      final groupRecords = List<ActivityRecordModel>.from(builder.records)
        ..sort((a, b) {
          final dateCompare = b.occurredAt.compareTo(a.occurredAt);
          if (dateCompare != 0) return dateCompare;
          return (b.id ?? 0).compareTo(a.id ?? 0);
        });
      final suggestions = <String, int>{};
      final reasons = <String, String>{};
      final suggestionsByRecordId = <int, TicketTypeSuggestion>{};
      for (final record in groupRecords) {
        final suggestion = suggestType(record, types);
        if (suggestion == null) continue;
        final id = record.id;
        if (id != null) suggestionsByRecordId[id] = suggestion;
        suggestions[suggestion.typeName] =
            (suggestions[suggestion.typeName] ?? 0) + 1;
        reasons.putIfAbsent(suggestion.typeName, () => suggestion.reason);
      }
      String? suggestedName;
      var suggestedCount = 0;
      for (final entry in suggestions.entries) {
        if (entry.value > suggestedCount) {
          suggestedCount = entry.value;
          suggestedName = entry.key;
        }
      }
      final newest = groupRecords.first;
      groups.add(TicketClassifyGroup(
        eventName: newest.resolvedActivityName,
        venueName: newest.venueName,
        occurredAt: newest.occurredAt,
        unitPrice: newest.ticketUnitPrice,
        records: groupRecords,
        suggestedTypeName: suggestedName,
        suggestion: suggestedName == null
            ? null
            : TicketTypeSuggestion(
                typeName: suggestedName,
                reason: reasons[suggestedName] ?? '按场次建议',
              ),
        suggestionReason: suggestedName == null
            ? '没有把握建议，先按票价分组'
            : (reasons[suggestedName] ?? '按场次建议'),
        suggestionsByRecordId: suggestionsByRecordId,
      ));
    }

    // Suggested groups first (biggest savings first), then price groups.
    groups.sort((a, b) {
      final aSuggested = a.suggestedTypeName != null ? 0 : 1;
      final bSuggested = b.suggestedTypeName != null ? 0 : 1;
      if (aSuggested != bSuggested) return aSuggested - bSuggested;
      final countCompare = b.records.length.compareTo(a.records.length);
      if (countCompare != 0) return countCompare;
      final priceCompare = b.unitPrice.compareTo(a.unitPrice);
      if (priceCompare != 0) return priceCompare;
      return a.suggestedTypeName
              ?.compareTo(b.suggestedTypeName ?? '') ??
          0;
    });
    return groups;
  }

  static TicketTypeModel? _findType(
    List<TicketTypeModel> types,
    String name,
  ) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    for (final type in types) {
      if (type.name.trim().toLowerCase() == normalized) return type;
    }
    return null;
  }

  static TicketTypeModel? _firstFreeType(List<TicketTypeModel> types) {
    for (final type in types) {
      if (type.isFree) return type;
    }
    return null;
  }

  static bool _samePrice(double a, double b) {
    return (a * 100).round() == (b * 100).round();
  }
}

class _GroupBuilder {
  final ActivityRecordModel record;
  final TicketTypeSuggestion? suggestion;
  final List<ActivityRecordModel> records = [];

  _GroupBuilder(this.record, this.suggestion);

  void add(ActivityRecordModel item) => records.add(item);
}
