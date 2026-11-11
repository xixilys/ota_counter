import 'dart:convert';

bool _readBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value.toInt() != 0;
  final normalized = '${value ?? ''}'.trim().toLowerCase();
  return normalized == 'true' || normalized == '1';
}

class IdolActivityGroup {
  final String name;
  final String uid;

  const IdolActivityGroup({
    required this.name,
    this.uid = '',
  });

  factory IdolActivityGroup.fromMap(Map<String, Object?> map) {
    return IdolActivityGroup(
      name: '${map['name'] ?? ''}'.trim(),
      uid: '${map['uid'] ?? ''}'.trim(),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'name': name,
      'uid': uid,
    };
  }
}

class IdolTicketTier {
  final String name;
  final double price;

  const IdolTicketTier({
    required this.name,
    required this.price,
  });

  Map<String, Object?> toMap() {
    return {'name': name, 'price': price};
  }

  factory IdolTicketTier.fromMap(Map<String, Object?> map) {
    return IdolTicketTier(
      name: '${map['name'] ?? ''}'.trim(),
      price: (map['price'] as num?)?.toDouble() ?? 0,
    );
  }
}

class IdolActivityEvent {
  final int? id;
  final String source;
  final String sourceEventId;
  final DateTime eventDate;
  final String city;
  final String venue;
  final String eventName;
  final String openTime;
  final String startTime;
  final String description;
  final String sourceLink;
  final String posterUrl;
  final List<IdolActivityGroup> groups;
  final bool isFree;
  final List<IdolTicketTier> ticketTiers;
  final DateTime syncedAt;

  const IdolActivityEvent({
    this.id,
    this.source = 'minecool',
    required this.sourceEventId,
    required this.eventDate,
    this.city = '',
    this.venue = '',
    required this.eventName,
    this.openTime = '',
    this.startTime = '',
    this.description = '',
    this.sourceLink = '',
    this.posterUrl = '',
    this.groups = const [],
    this.isFree = false,
    this.ticketTiers = const [],
    required this.syncedAt,
  });

  String get sessionLabel {
    final time =
        startTime.trim().isNotEmpty ? startTime.trim() : openTime.trim();
    if (time.isEmpty) {
      return '';
    }
    return time;
  }

  String get groupLabel {
    return groups
        .map((group) => group.name.trim())
        .where((name) => name.isNotEmpty)
        .take(4)
        .join(' / ');
  }

  String get displaySubtitle {
    return [
      if (city.trim().isNotEmpty) city.trim(),
      if (venue.trim().isNotEmpty) venue.trim(),
      if (sessionLabel.isNotEmpty) sessionLabel,
      if (groupLabel.isNotEmpty) groupLabel,
    ].join(' · ');
  }

  IdolActivityEvent copyWithSyncedAt(DateTime value) {
    return IdolActivityEvent(
      id: id,
      source: source,
      sourceEventId: sourceEventId,
      eventDate: eventDate,
      city: city,
      venue: venue,
      eventName: eventName,
      openTime: openTime,
      startTime: startTime,
      description: description,
      sourceLink: sourceLink,
      posterUrl: posterUrl,
      groups: groups,
      isFree: isFree,
      ticketTiers: ticketTiers,
      syncedAt: value,
    );
  }

  String get ticketSummary {
    final tiers = ticketTiers
        .where((tier) => tier.name.isNotEmpty && tier.price > 0)
        .take(4)
        .map((tier) => '${tier.name} ¥${_formatPrice(tier.price)}')
        .toList(growable: false);
    if (tiers.isEmpty) {
      return isFree ? '免费入场' : '';
    }
    final joined = tiers.join(' / ');
    return isFree ? '免费入场 · $joined' : joined;
  }

  static String _formatPrice(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }

  factory IdolActivityEvent.fromJson(Map<String, Object?> json) {
    final groups = (json['groups'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) => IdolActivityGroup.fromMap(item.cast<String, Object?>()))
        .where((item) => item.name.isNotEmpty)
        .toList(growable: false);
    final tiers = (json['ticketTiers'] ?? json['ticket_tiers']);
    final ticketTiers = tiers is List
        ? tiers
            .whereType<Map>()
            .map(
              (item) => IdolTicketTier.fromMap(
                item.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .where((tier) => tier.name.isNotEmpty && tier.price > 0)
            .toList(growable: false)
        : const <IdolTicketTier>[];

    return IdolActivityEvent(
      sourceEventId:
          '${json['sourceEventId'] ?? json['source_event_id'] ?? ''}'.trim(),
      eventDate: DateTime.parse('${json['date'] ?? json['event_date']}'),
      city: '${json['city'] ?? ''}'.trim(),
      venue: '${json['venue'] ?? ''}'.trim(),
      eventName: '${json['eventName'] ?? json['event_name'] ?? ''}'.trim(),
      openTime: '${json['openTime'] ?? json['open_time'] ?? ''}'.trim(),
      startTime: '${json['startTime'] ?? json['start_time'] ?? ''}'.trim(),
      description: '${json['description'] ?? ''}'.trim(),
      sourceLink: '${json['sourceLink'] ?? json['source_link'] ?? ''}'.trim(),
      posterUrl: '${json['posterUrl'] ?? json['poster_url'] ?? ''}'.trim(),
      groups: groups,
      isFree: _readBool(json['isFree'] ?? json['is_free']),
      ticketTiers: ticketTiers,
      syncedAt: DateTime.now(),
    );
  }

  factory IdolActivityEvent.fromMap(Map<String, Object?> map) {
    return IdolActivityEvent(
      id: (map['id'] as num?)?.toInt(),
      source: '${map['source'] ?? 'minecool'}'.trim(),
      sourceEventId: '${map['source_event_id'] ?? ''}'.trim(),
      eventDate: DateTime.parse('${map['event_date']}'),
      city: '${map['city'] ?? ''}'.trim(),
      venue: '${map['venue'] ?? ''}'.trim(),
      eventName: '${map['event_name'] ?? ''}'.trim(),
      openTime: '${map['open_time'] ?? ''}'.trim(),
      startTime: '${map['start_time'] ?? ''}'.trim(),
      description: '${map['description'] ?? ''}'.trim(),
      sourceLink: '${map['source_link'] ?? ''}'.trim(),
      posterUrl: '${map['poster_url'] ?? ''}'.trim(),
      groups: (map['groups_json'] as String?) == null
          ? const []
          : _decodeGroups(map['groups_json'] as String),
      isFree: _readBool(map['is_free']),
      ticketTiers: _decodeTicketTiers(map['ticket_tiers_json']),
      syncedAt: DateTime.tryParse('${map['synced_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Map<String, Object?> toDbMap() {
    return {
      'source': source,
      'source_event_id': sourceEventId,
      'event_date': _formatDate(eventDate),
      'city': city,
      'venue': venue,
      'event_name': eventName,
      'open_time': openTime,
      'start_time': startTime,
      'description': description,
      'source_link': sourceLink,
      'poster_url': posterUrl,
      'groups_json': _encodeGroups(groups),
      'is_free': isFree ? 1 : 0,
      'ticket_tiers_json': jsonEncode(
        ticketTiers.map((tier) => tier.toMap()).toList(growable: false),
      ),
      'synced_at': syncedAt.toIso8601String(),
    };
  }

  static String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }

  static String _encodeGroups(List<IdolActivityGroup> groups) {
    final encoded =
        groups.map((group) => group.toMap()).toList(growable: false);
    return jsonEncode(encoded);
  }

  static List<IdolTicketTier> _decodeTicketTiers(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (item) => IdolTicketTier.fromMap(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .where((tier) => tier.name.isNotEmpty && tier.price > 0)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static List<IdolActivityGroup> _decodeGroups(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .whereType<Map>()
          .map(
              (item) => IdolActivityGroup.fromMap(item.cast<String, Object?>()))
          .where((item) => item.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

class IdolActivityEventBundle {
  final String sourceUrl;
  final String sourceLabel;
  final String generatedAt;
  final List<IdolActivityEvent> events;

  const IdolActivityEventBundle({
    required this.sourceUrl,
    required this.sourceLabel,
    required this.generatedAt,
    required this.events,
  });

  factory IdolActivityEventBundle.fromJson(Map<String, Object?> json) {
    final events = <IdolActivityEvent>[];
    for (final item in json['events'] as List<dynamic>? ?? const []) {
      if (item is! Map) {
        continue;
      }
      try {
        final event = IdolActivityEvent.fromJson(
          item.cast<String, Object?>(),
        );
        if (event.sourceEventId.isNotEmpty &&
            event.eventName.trim().isNotEmpty) {
          events.add(event);
        }
      } catch (_) {
        // A single bad row must not discard the rest of the roster.
      }
    }

    return IdolActivityEventBundle(
      sourceUrl: '${json['sourceUrl'] ?? json['source_url'] ?? ''}'.trim(),
      sourceLabel:
          '${json['sourceLabel'] ?? json['source_label'] ?? ''}'.trim(),
      generatedAt:
          '${json['generatedAt'] ?? json['generated_at'] ?? ''}'.trim(),
      events: events,
    );
  }
}
