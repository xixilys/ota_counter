import '../../models/activity_record_media_model.dart';
import '../../models/activity_record_model.dart';
import '../../models/counter_model.dart';
import '../../services/face/face_recognition_rules.dart';
import 'album_models.dart';

/// Builds the album from the same rows the rest of the app already persists.
///
/// Mapping rules (see also the report / docs):
/// * member: media owner label → record's counter / person → multi participants
///   (one participant = solo, several = 团切 / 多人, none = 未归属).
/// * date: camera/EXIF capture time (06:00 activity-day boundary) → ledger
///   record day. Date-only records (00:00) keep their date.
/// * session: ledger activity name + venue + session label on the record day.
///   Records sharing those fields on the same day are one 场次; photos without
///   a matching record fall into an "unknown" bucket.
/// * spec: ledger count field(s) for 切图; memory photos carry their media type.
AlbumData buildAlbumData({
  required List<CounterModel> counters,
  required List<ActivityRecordModel> records,
  required List<ActivityRecordMediaModel> media,
  Iterable<AlbumEventHint> eventHints = const [],
}) {
  final recordsById = <int, ActivityRecordModel>{
    for (final record in records)
      if (record.id != null) record.id!: record,
  };
  final lookup = _AlbumMemberLookup(counters);
  final hints = <String, AlbumEventHint>{
    for (final hint in eventHints) hint.key: hint,
  };
  final photos = <AlbumPhoto>[];

  for (final item in media) {
    if (item.path.trim().isEmpty) continue;
    final record = recordsById[item.recordId];
    final capturedAt = _usableDate(item.capturedAt) ? item.capturedAt : null;
    final captureDay = capturedAt == null ? null : activityDayOf(capturedAt);
    final recordDay = record == null || !_usableDate(record.occurredAt)
        ? null
        : recordActivityDay(record.occurredAt);
    final activityDay = captureDay ?? recordDay;

    final owner = lookup.ownerRef(item);
    final _MemberAssignment assignment;
    if (owner != null) {
      assignment = _MemberAssignment(members: [owner], isGroup: false);
    } else {
      assignment = lookup.assignmentForRecord(record);
    }

    final sessionDay = recordDay ?? activityDay;
    final activityName = record?.resolvedActivityName.trim() ?? '';
    var venueName = record?.resolvedVenueName ?? '';
    var cityName = '';
    var eventTimeLabel = '';
    if (recordDay != null && activityName.isNotEmpty) {
      final hint = hints['${albumDateKey(recordDay)}|'
          '${normalizeAlbumPart(activityName)}'];
      if (hint != null) {
        if (venueName.trim().isEmpty) venueName = hint.venue;
        cityName = hint.city;
        eventTimeLabel = hint.startTime;
      }
    }

    final sessionLabel = record?.sessionLabel.trim() ?? '';
    // The event cache has one time per event, not per 部; showing it next to a
    // ledger "第一部/第二部" label would pair the wrong time. Only use it when
    // the ledger has no session label to describe the slot.
    if (sessionLabel.isNotEmpty) eventTimeLabel = '';
    final sessionKey = _sessionKey(
      record: record,
      sessionDay: sessionDay,
      activityName: activityName,
      venueName: venueName,
      sessionLabel: sessionLabel,
    );

    photos.add(
      AlbumPhoto(
        mediaId: item.id,
        path: item.path,
        isScan: item.isScan,
        mediaLabel: item.mediaType.label,
        processingLabel: item.processingMode.label,
        canAutoRectify: item.isScan && !item.processingMode.isProcessed,
        specLabel: _specLabel(item, record),
        activityDay: activityDay,
        dateFromPhoto: captureDay != null,
        capturedAt: capturedAt,
        recordDay: recordDay,
        isGroup: assignment.isGroup,
        members: assignment.members,
        activityName: activityName,
        venueName: venueName,
        cityName: cityName,
        sessionLabel: sessionLabel,
        sessionKey: sessionKey,
        sessionDay: sessionDay,
        eventTimeLabel: eventTimeLabel,
      ),
    );
  }

  return assembleAlbumData(photos);
}

class _MemberAssignment {
  final List<AlbumMemberRef> members;
  final bool isGroup;

  const _MemberAssignment({required this.members, required this.isGroup});
}

bool _usableDate(DateTime? value) {
  if (value == null) return false;
  // Models fall back to DateTime(0) for unreadable timestamps; an album with a
  // year-0 month is noise, so treat pre-1970 values as "unknown".
  return value.year >= 1971 && value.year <= 3000;
}

String _specLabel(ActivityRecordMediaModel media, ActivityRecordModel? record) {
  if (!media.isScan) return media.mediaType.label;
  if (record == null) return '切图';
  if (record.isTicket) return '门票';
  if (record.isMulti) {
    final field = record.multiCountField;
    if (field == null) return '多人切';
    final quantity = record.effectiveMultiQuantity;
    if (field == CounterCountField.groupCut) return '团切 · $quantity张';
    return '${field.label} · $quantity张';
  }
  final parts = record.counterSpecSummaryParts;
  return parts.isEmpty ? '切图' : parts.join(' · ');
}

String _sessionKey({
  required ActivityRecordModel? record,
  required DateTime? sessionDay,
  required String activityName,
  required String venueName,
  required String sessionLabel,
}) {
  if (record == null) return 'orphan';
  if (sessionDay == null) {
    return 'undated-record-${record.id ?? record.occurredAt.microsecondsSinceEpoch}';
  }
  return [
    'day:${albumDateKey(sessionDay)}',
    normalizeAlbumPart(activityName),
    normalizeAlbumPart(venueName),
    normalizeAlbumPart(sessionLabel),
  ].join('|');
}

class _AlbumMemberLookup {
  final List<CounterModel> _counters;
  final Map<int, List<CounterModel>> _byPersonId = {};
  final Map<int, CounterModel> _byCounterId = {};

  _AlbumMemberLookup(List<CounterModel> counters)
      : _counters = counters.toList(growable: false) {
    for (final counter in _counters) {
      final id = counter.id;
      if (id != null) _byCounterId[id] = counter;
      final personId = counter.personId;
      if (personId != null) {
        _byPersonId.putIfAbsent(personId, () => <CounterModel>[]).add(counter);
      }
    }
  }

  CounterModel? _preferred(Iterable<CounterModel> candidates) {
    final list = candidates.toList(growable: false);
    if (list.isEmpty) return null;
    list.sort((a, b) {
      final countCompare = b.count.compareTo(a.count);
      if (countCompare != 0) return countCompare;
      return (a.id ?? 1 << 30).compareTo(b.id ?? 1 << 30);
    });
    return list.first;
  }

  AlbumMemberRef _fromCounter(CounterModel counter) {
    final personId = counter.personId;
    final key = personId != null
        ? 'p:$personId'
        : counter.id != null
            ? 'c:${counter.id}'
            : 'n:${normalizeAlbumPart(counter.name)}|'
                '${normalizeAlbumPart(counter.groupName)}';
    final displayName = counter.name.trim().isNotEmpty
        ? counter.name.trim()
        : counter.personName;
    return AlbumMemberRef(
      key: key,
      personId: personId,
      counterId: counter.id,
      name: displayName,
      groupName: counter.groupName,
      colorHex: counter.color,
      sortKey: counter.namePinyin,
    );
  }

  AlbumMemberRef _synthetic({
    int? personId,
    String name = '',
    String groupName = '',
  }) {
    final normalizedName = normalizeAlbumPart(name);
    final key = personId != null
        ? 'p:$personId'
        : 'n:$normalizedName|${normalizeAlbumPart(groupName)}';
    return AlbumMemberRef(
      key: key,
      personId: personId,
      name: name.trim(),
      groupName: groupName.trim(),
      colorHex: _fallbackColor(key),
      sortKey: normalizedName,
    );
  }

  AlbumMemberRef? ownerRef(ActivityRecordMediaModel media) {
    if (!media.hasOwnerScope) return null;
    final ownerPersonId = media.ownerPersonId;
    final ownerName = media.ownerPersonName.trim();
    final ownerGroup = media.ownerGroupName.trim();

    if (ownerPersonId != null) {
      final counter = _preferred(_byPersonId[ownerPersonId] ?? const []);
      if (counter != null) return _fromCounter(counter);
    }

    if (ownerName.isNotEmpty) {
      final matched = _preferred(_counters.where((counter) {
        if (!albumGroupsCanMatch(counter.groupName, ownerGroup)) return false;
        return normalizeAlbumPart(counter.name) ==
                normalizeAlbumPart(ownerName) ||
            normalizeAlbumPart(counter.personName) ==
                normalizeAlbumPart(ownerName);
      }));
      if (matched != null) return _fromCounter(matched);
    }

    if (ownerPersonId == null && ownerName.isEmpty) return null;
    return _synthetic(
      personId: ownerPersonId,
      name: ownerName,
      groupName: ownerGroup,
    );
  }

  AlbumMemberRef? refForRecord(ActivityRecordModel record) {
    final counter = resolveCounterForActivityRecord(_counters, record);
    if (counter != null) return _fromCounter(counter);
    if (record.personId != null ||
        record.personName.trim().isNotEmpty ||
        record.subjectName.trim().isNotEmpty) {
      return _synthetic(
        personId: record.personId,
        name: record.personName.trim().isNotEmpty
            ? record.personName
            : record.subjectName,
        groupName: record.groupName,
      );
    }
    return null;
  }

  AlbumMemberRef? refForParticipant(ActivityParticipant participant) {
    final personId = participant.personId;
    if (personId != null) {
      final counter = _preferred(_byPersonId[personId] ?? const []);
      if (counter != null) return _fromCounter(counter);
    }
    final groupName = participant.groupName.trim();
    final names = {
      normalizeAlbumPart(participant.memberName),
      normalizeAlbumPart(participant.personName),
    }..remove('');
    if (names.isNotEmpty) {
      final matched = _preferred(_counters.where((counter) {
        if (!albumGroupsCanMatch(counter.groupName, groupName)) return false;
        final counterNames = {
          normalizeAlbumPart(counter.name),
          normalizeAlbumPart(counter.personName),
        }..remove('');
        return names.any(counterNames.contains);
      }));
      if (matched != null) return _fromCounter(matched);
    }
    final displayName = participant.resolvedPersonName.trim().isNotEmpty
        ? participant.resolvedPersonName
        : participant.memberName;
    if (personId == null && displayName.trim().isEmpty) return null;
    return _synthetic(
      personId: personId,
      name: displayName,
      groupName: groupName,
    );
  }

  _MemberAssignment assignmentForRecord(ActivityRecordModel? record) {
    if (record == null) {
      return const _MemberAssignment(members: [], isGroup: false);
    }
    if (record.isTicket) {
      return const _MemberAssignment(members: [], isGroup: false);
    }
    if (record.isMulti) {
      final participants = record.effectiveParticipants;
      final members = <AlbumMemberRef>[
        for (final participant in participants)
          if (refForParticipant(participant) case final ref?) ref,
      ];
      if (members.length > 1) {
        return _MemberAssignment(
          members: List<AlbumMemberRef>.unmodifiable(members),
          isGroup: true,
        );
      }
      if (members.length == 1) {
        return _MemberAssignment(members: members, isGroup: false);
      }
      // A multi record without participants still names its subject in old
      // data; fall back to the record identity rather than dropping the photo.
      final fallback = refForRecord(record);
      return _MemberAssignment(
        members: fallback == null ? const [] : [fallback],
        isGroup: false,
      );
    }
    final ref = refForRecord(record);
    return _MemberAssignment(
      members: ref == null ? const [] : [ref],
      isGroup: false,
    );
  }
}

const _fallbackColors = <String>[
  '#FF7A9E',
  '#4E8DF5',
  '#21B6A8',
  '#F4A63A',
  '#8A63E8',
  '#E45C8A',
  '#0F9E8E',
  '#F2A93B',
];

String _fallbackColor(String key) {
  var hash = 0;
  for (final unit in key.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _fallbackColors[hash % _fallbackColors.length];
}
