import 'dart:math' as math;

/// Read helpers tolerant of both the app's camelCase `toMap()` output and the
/// snake_case rows used by SQLite / older backups.
String readString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String) {
      return value;
    }
    if (value != null) {
      return value.toString();
    }
  }
  return '';
}

int readInt(Map<dynamic, dynamic> map, List<String> keys, [int fallback = 0]) {
  for (final key in keys) {
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return fallback;
}

double readDouble(
  Map<dynamic, dynamic> map,
  List<String> keys, [
  double fallback = 0,
]) {
  for (final key in keys) {
    final value = map[key];
    if (value is num) return value.toDouble();
    if (value is String) {
      final parsed = double.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return fallback;
}

bool readBool(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is num) return value.toInt() != 0;
    if (value is String) {
      final normalized = value.toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
  }
  return false;
}

String normalizePart(String value) {
  return value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'), '');
}

const List<String> countKeys = [
  'threeInchCount',
  'fiveInchCount',
  'unsignedThreeInchCount',
  'unsignedFiveInchCount',
  'groupCutCount',
  'threeInchShukudaiCount',
  'fiveInchShukudaiCount',
];

const Map<String, String> countKeyAliases = {
  'three_inch': 'threeInchCount',
  'three_inch_count': 'threeInchCount',
  'five_inch': 'fiveInchCount',
  'five_inch_count': 'fiveInchCount',
  'unsigned_three_inch': 'unsignedThreeInchCount',
  'unsigned_three_inch_count': 'unsignedThreeInchCount',
  'unsigned_five_inch': 'unsignedFiveInchCount',
  'unsigned_five_inch_count': 'unsignedFiveInchCount',
  'group_cut': 'groupCutCount',
  'group_cut_count': 'groupCutCount',
  'three_inch_shukudai': 'threeInchShukudaiCount',
  'three_inch_shukudai_count': 'threeInchShukudaiCount',
  'five_inch_shukudai': 'fiveInchShukudaiCount',
  'five_inch_shukudai_count': 'fiveInchShukudaiCount',
};

Map<String, int> counterCounts(Map<dynamic, dynamic> counter) {
  return {
    for (final key in countKeys)
      key: readInt(counter, [
        key,
        key.replaceAllMapped(
          RegExp(r'[A-Z]'),
          (match) => '_${match.group(0)!.toLowerCase()}',
        ),
      ]),
  };
}

int counterTotal(Map<dynamic, dynamic> counter) {
  final explicit = readInt(counter, ['total_count', 'totalCount'], -1);
  if (explicit >= 0) {
    return explicit;
  }
  return counterCounts(counter)
          .values
          .fold<int>(0, (sum, value) => sum + value) +
      customTotal(counter);
}

int customTotal(Map<dynamic, dynamic> counter) {
  final value = counter['custom_counts'] ?? counter['customCounts'];
  if (value is! Map) {
    return 0;
  }
  return value.values.fold<int>(
    0,
    (sum, item) => sum + (item is num ? item.toInt() : 0),
  );
}

String counterName(Map<dynamic, dynamic> counter) =>
    readString(counter, ['name', 'member_name', 'memberName']);

String counterGroup(Map<dynamic, dynamic> counter) =>
    readString(counter, ['group_name', 'groupName']);

int? counterPersonId(Map<dynamic, dynamic> counter) {
  final value = counter['person_id'] ?? counter['personId'];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String counterPersonName(Map<dynamic, dynamic> counter) =>
    readString(counter, ['person_name', 'personName']);

bool counterHidden(Map<dynamic, dynamic> counter) =>
    readBool(counter, ['is_hidden', 'isHidden']);

String recordType(Map<dynamic, dynamic> record) {
  final value = readString(record, ['record_type', 'recordType', 'type']);
  if (value == 'multi' || value == 'duo') return 'multi';
  if (value == 'ticket') return 'ticket';
  return 'counter';
}

String recordDate(Map<dynamic, dynamic> record) {
  final raw = readString(record, ['occurred_at', 'occurredAt', 'date']);
  if (raw.isEmpty) return '';
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) return raw.length >= 10 ? raw.substring(0, 10) : raw;
  return formatDate(parsed);
}

String formatDate(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}';
}

String formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${formatDate(value)} ${two(value.hour)}:${two(value.minute)}';
}

String recordTitle(Map<dynamic, dynamic> record) {
  final name = readString(record, [
    'subject_name',
    'subjectName',
    'member_name',
    'person_name',
  ]);
  final group = counterGroup(record);
  if (group.isEmpty) return name;
  return '$name · $group';
}

String recordDisplayName(Map<dynamic, dynamic> record) {
  final type = recordType(record);
  if (type == 'ticket') {
    return readString(record, ['subject_name', 'subjectName', 'event_name']);
  }
  final subject = readString(record, ['subject_name', 'subjectName']);
  final secondary = readString(record, [
    'secondary_subject_name',
    'secondarySubjectName',
  ]);
  if (secondary.trim().isNotEmpty && recordType(record) == 'multi') {
    return '$subject × $secondary';
  }
  return subject;
}

class MemberAggregate {
  MemberAggregate(this.key);

  final String key;
  final List<Map<dynamic, dynamic>> counters = [];
  final Map<String, int> counts = {for (final key in countKeys) key: 0};
  int custom = 0;

  void add(Map<dynamic, dynamic> counter) {
    counters.add(counter);
    final values = counterCounts(counter);
    for (final entry in values.entries) {
      counts[entry.key] = (counts[entry.key] ?? 0) + entry.value;
    }
    custom += customTotal(counter);
  }

  int get total =>
      counts.values.fold<int>(0, (sum, value) => sum + value) + custom;

  String get name {
    final person = counters
        .map(counterPersonName)
        .map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    if (person.isNotEmpty) return person;
    return counterName(counters.isEmpty ? const {} : counters.first);
  }

  String get groupLabel {
    final groups = counters
        .map(counterGroup)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    if (groups.isEmpty) return '';
    if (groups.length <= 2) return groups.join(' / ');
    return '${groups.take(2).join(' / ')} 等${groups.length}团';
  }

  List<String> get groups {
    final result = counters
        .map(counterGroup)
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return result;
  }

  int? get primaryCounterId {
    int? bestId;
    var best = -1;
    for (final counter in counters) {
      final id = readInt(counter, ['id'], -1);
      if (id <= 0) continue;
      final total = counterTotal(counter);
      if (total > best) {
        best = total;
        bestId = id;
      }
    }
    return bestId;
  }

  int? get personId {
    for (final counter in counters) {
      final id = counterPersonId(counter);
      if (id != null) return id;
    }
    return null;
  }

  String get primaryGroup {
    if (counters.isEmpty) return '';
    var best = counters.first;
    var bestTotal = counterTotal(best);
    for (final counter in counters.skip(1)) {
      final total = counterTotal(counter);
      if (total > bestTotal) {
        best = counter;
        bestTotal = total;
      }
    }
    return counterGroup(best);
  }

  bool get hidden => counters.every(counterHidden);

  List<int> get counterIds => counters
      .map((counter) => readInt(counter, ['id'], -1))
      .where((id) => id > 0)
      .toList(growable: false);

  Map<String, dynamic> toJson({int total = 0}) {
    return {
      'member_id': primaryCounterId,
      'person_id': personId,
      'name': name,
      'group': groupLabel,
      'groups': groups,
      'total_count': this.total,
      'percentage': total <= 0 ? 0 : (this.total / total * 1000).round() / 10,
      'counts': {
        'three_inch': counts['threeInchCount'] ?? 0,
        'five_inch': counts['fiveInchCount'] ?? 0,
        'unsigned_three_inch': counts['unsignedThreeInchCount'] ?? 0,
        'unsigned_five_inch': counts['unsignedFiveInchCount'] ?? 0,
        'group_cut': counts['groupCutCount'] ?? 0,
        'three_inch_shukudai': counts['threeInchShukudaiCount'] ?? 0,
        'five_inch_shukudai': counts['fiveInchShukudaiCount'] ?? 0,
      },
      'custom_total': custom,
      'counter_ids': counterIds,
      'hidden': hidden,
    };
  }
}

/// A read-only projection over one app snapshot.
class SnapshotView {
  SnapshotView(this.raw);

  final Map<String, dynamic> raw;

  List<Map<dynamic, dynamic>> get counters {
    final value = raw['counters'] ?? raw['members'];
    if (value is! List) return const [];
    return value.whereType<Map>().toList(growable: false);
  }

  List<Map<dynamic, dynamic>> get records {
    final value = raw['records'] ?? raw['activity_records'];
    if (value is! List) return const [];
    return value.whereType<Map>().toList(growable: false);
  }

  List<Map<dynamic, dynamic>> get pricings {
    final value = raw['pricings'] ?? raw['group_pricings'];
    if (value is! List) return const [];
    return value.whereType<Map>().toList(growable: false);
  }

  Map<dynamic, dynamic>? get summary {
    final value = raw['summary'];
    return value is Map ? value : null;
  }

  List<MemberAggregate> members({bool includeHidden = true}) {
    final grouped = <String, MemberAggregate>{};
    for (final counter in counters) {
      if (!includeHidden && counterHidden(counter)) {
        continue;
      }
      final personId = counterPersonId(counter);
      final personName = normalizePart(counterPersonName(counter));
      final String key;
      if (personId != null) {
        key = 'person-id:$personId';
      } else if (personName.isNotEmpty) {
        key = 'person-name:$personName';
      } else {
        key =
            'counter:${normalizePart(counterGroup(counter))}|${normalizePart(counterName(counter))}';
      }
      grouped.putIfAbsent(key, () => MemberAggregate(key)).add(counter);
    }
    final result = grouped.values.toList()
      ..sort((a, b) {
        final countCompare = b.total.compareTo(a.total);
        if (countCompare != 0) return countCompare;
        return a.name.compareTo(b.name);
      });
    return result;
  }

  int get totalCount {
    final value = summary?['total_count'];
    if (value is num) return value.toInt();
    return members(includeHidden: false)
        .fold<int>(0, (sum, member) => sum + member.total);
  }

  Map<String, int> get byType {
    final import = summary?['by_type'];
    if (import is Map) {
      return {
        for (final key in countKeys) key: readInt(import, [key], 0),
      };
    }
    final totals = {for (final key in countKeys) key: 0};
    for (final member in members(includeHidden: false)) {
      for (final key in countKeys) {
        totals[key] = (totals[key] ?? 0) + (member.counts[key] ?? 0);
      }
    }
    return totals;
  }

  Map<String, dynamic> ticketSummary() {
    final import = summary?['ticket_count'];
    if (import is num) {
      return {
        'ticket_count': import.toInt(),
        'amount': readDouble(summary ?? const {}, ['ticket_amount']),
        'free_ticket_count':
            readInt(summary ?? const {}, ['free_ticket_count']),
        'paid_ticket_count':
            readInt(summary ?? const {}, ['paid_ticket_count']),
        'by_type': summary?['ticket_types'] is Map
            ? summary!['ticket_types']
            : <String, dynamic>{},
      };
    }
    var count = 0;
    var amount = 0.0;
    var free = 0;
    var paid = 0;
    final byType = <String, int>{};
    for (final record in records) {
      if (recordType(record) != 'ticket') continue;
      final quantity = readInt(record, ['ticket_quantity', 'ticketQuantity']);
      count += quantity;
      amount += readDouble(record, ['total_amount', 'totalAmount']);
      final explicitFree = record['ticket_is_free'];
      final unitPrice =
          readDouble(record, ['ticket_unit_price', 'ticketUnitPrice']);
      final recordAmount = readDouble(record, ['total_amount', 'totalAmount']);
      final isFree = explicitFree == null
          ? (unitPrice <= 0 && recordAmount <= 0)
          : readBool(record, ['ticket_is_free']);
      if (isFree) {
        free += quantity;
      } else {
        paid += quantity;
      }
      final type = readString(record, ['ticket_type', 'ticketType']).trim();
      final label = type.isEmpty ? (isFree ? '免费票' : '未分类') : type;
      byType[label] = (byType[label] ?? 0) + quantity;
    }
    return {
      'ticket_count': count,
      'amount': amount,
      'free_ticket_count': free,
      'paid_ticket_count': paid,
      'by_type': byType,
    };
  }

  double get revenue {
    final value = summary?['revenue'];
    if (value is num) return value.toDouble();
    var total = 0.0;
    for (final record in records) {
      total += readDouble(record, ['total_amount', 'totalAmount']);
    }
    return total;
  }

  int get hiddenMembers => counters.where(counterHidden).length;

  List<Map<dynamic, dynamic>> searchRecords({
    String? from,
    String? to,
    String? member,
    String? type,
    int limit = 50,
    int offset = 0,
  }) {
    final fromDate = from == null || from.trim().isEmpty
        ? null
        : DateTime.tryParse(from.trim());
    final toDate =
        to == null || to.trim().isEmpty ? null : DateTime.tryParse(to.trim());
    final query = normalizePart(member ?? '');
    final filtered = <Map<dynamic, dynamic>>[];
    for (final record in records) {
      if (type != null && type.isNotEmpty && type != 'all') {
        if (recordType(record) != type) continue;
      }
      final dateText = recordDate(record);
      final date = DateTime.tryParse(dateText);
      if (date != null) {
        if (fromDate != null &&
            date.isBefore(
                DateTime(fromDate.year, fromDate.month, fromDate.day))) {
          continue;
        }
        if (toDate != null &&
            date.isAfter(
                DateTime(toDate.year, toDate.month, toDate.day, 23, 59, 59))) {
          continue;
        }
      }
      if (query.isNotEmpty) {
        final haystack = normalizePart([
          readString(record, ['subject_name', 'subjectName']),
          readString(
              record, ['secondary_subject_name', 'secondarySubjectName']),
          counterGroup(record),
          counterPersonName(record),
          readString(record, ['activity_name', 'activityName']),
          readString(record, ['note']),
        ].join(' '));
        if (!haystack.contains(query)) continue;
      }
      filtered.add(record);
    }
    filtered.sort((a, b) {
      final aText = readString(a, ['occurred_at', 'occurredAt']);
      final bText = readString(b, ['occurred_at', 'occurredAt']);
      return bText.compareTo(aText);
    });
    final safeLimit = limit.clamp(1, 200);
    final safeOffset = math.max(0, offset);
    if (safeOffset >= filtered.length) return const [];
    return filtered.skip(safeOffset).take(safeLimit).toList(growable: false);
  }

  int get recordCount {
    final value = summary?['record_count'] ?? summary?['records'];
    if (value is num) return value.toInt();
    return records.length;
  }

  List<Map<String, dynamic>> groups() {
    final byName = <String, Map<String, dynamic>>{};
    for (final pricing in pricings) {
      final name = counterGroup(pricing);
      if (name.isEmpty) continue;
      byName[name] = {
        'name': name,
        'label': readString(pricing, ['label']),
        'three_inch_price':
            readDouble(pricing, ['three_inch_price', 'threeInchPrice']),
        'five_inch_price':
            readDouble(pricing, ['five_inch_price', 'fiveInchPrice']),
        'group_cut_price':
            readDouble(pricing, ['group_cut_price', 'groupCutPrice']),
      };
    }
    for (final counter in counters) {
      final name = counterGroup(counter);
      if (name.isEmpty) continue;
      byName.putIfAbsent(name, () => {'name': name});
    }
    final result = byName.values.toList()
      ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return result;
  }

  Map<String, dynamic> overview({int pendingActions = 0}) {
    final typeTotals = byType;
    return {
      'total_count': totalCount,
      'member_count': members(includeHidden: false).length,
      'hidden_member_count': hiddenMembers,
      'record_count': recordCount,
      'revenue': revenue,
      // These mirror the five home overview tiles. Unsigned photos are
      // included in three_inch/five_inch and also exposed separately below so
      // adding all five tiles never double counts.
      'by_type': {
        'three_inch': typeTotals['threeInchCount'] ?? 0,
        'five_inch': typeTotals['fiveInchCount'] ?? 0,
        'three_inch_shukudai': typeTotals['threeInchShukudaiCount'] ?? 0,
        'five_inch_shukudai': typeTotals['fiveInchShukudaiCount'] ?? 0,
        'group_cut': typeTotals['groupCutCount'] ?? 0,
      },
      'unsigned': {
        'three_inch': typeTotals['unsignedThreeInchCount'] ?? 0,
        'five_inch': typeTotals['unsignedFiveInchCount'] ?? 0,
      },
      'tickets': ticketSummary(),
      'pending_actions': pendingActions,
      'snapshot_exported_at': readString(raw, ['exported_at']),
      'snapshot_received_at': readString(raw, ['received_at']),
    };
  }
}
