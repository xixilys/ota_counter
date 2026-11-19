/// Data model for 切册 (the cheki photo album).
///
/// The album groups three existing sources. Optimized display files are
/// derived from the archived media and do not change these records:
/// * `activity_record_media` rows (scan crops + memory photos; `ImageService`
///   images are a separate extraction gallery without member/date links),
/// * `activity_records` (member, activity, venue, session, spec, date),
/// * `counters` (member identity, 応援色 and display name).
///
/// Everything here is plain data so the grouping can be unit-tested without a
/// database or Flutter binding. UI lives in the other `album/` files.
library;

import '../../models/activity_record_media_model.dart';

/// Strips separators used by the existing record/media matching helpers so
/// "林 小满" and "林·小满" are the same member.
String normalizeAlbumPart(String value) {
  final trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  return trimmed.replaceAll(RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'), '');
}

String albumGroupKey(String value) => normalizeAlbumPart(value);

bool albumGroupsCanMatch(String first, String second) {
  final a = albumGroupKey(first);
  final b = albumGroupKey(second);
  return a.isEmpty || b.isEmpty || a == b;
}

String albumDateKey(DateTime day) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${day.year}-${two(day.month)}-${two(day.day)}';
}

/// A human 場次 title when the ledger never recorded an event name.
///
/// Fallback order, deliberately stable so the strip and the feature card name
/// the same session the same way:
/// 1. the recorded activity name,
/// 2. the group name(s) of its members, e.g. 「PokaPokaTime 场」,
/// 3. the venue,
/// 4. the member names,
/// 5. 「未记公演」 only when there is nothing else at all.
String albumSessionTitle({
  required String activityName,
  required String venueName,
  required List<AlbumMemberRef> members,
}) {
  final activity = activityName.trim();
  if (activity.isNotEmpty) return activity;

  final groups = <String>[];
  for (final member in members) {
    final group = member.groupName.trim();
    if (group.isEmpty || group == '未分组' || groups.contains(group)) continue;
    groups.add(group);
  }
  if (groups.isNotEmpty) return '${groups.join(' / ')} 场';

  final venue = venueName.trim();
  if (venue.isNotEmpty) return venue;

  final names = <String>[];
  for (final member in members) {
    final name = member.displayName.trim();
    if (name.isEmpty || name == '未署名成员' || names.contains(name)) continue;
    names.add(name);
  }
  if (names.isNotEmpty) return '${names.join(' / ')} 场';

  return '未记公演';
}

/// Stable identity of one person. [key] is `p:<personId>`, `c:<counterId>` or
/// `n:<normalized name>|<normalized group>` when only a name is known.
class AlbumMemberRef {
  final String key;
  final int? personId;
  final int? counterId;
  final String name;
  final String groupName;
  final String colorHex;
  final String sortKey;

  const AlbumMemberRef({
    required this.key,
    this.personId,
    this.counterId,
    required this.name,
    this.groupName = '',
    this.colorHex = '',
    this.sortKey = '',
  });

  String get displayName {
    final normalized = name.trim();
    return normalized.isEmpty ? '未署名成员' : normalized;
  }

  String get displayGroup {
    final normalized = groupName.trim();
    return normalized.isEmpty ? '未分组' : normalized;
  }

  String get initial {
    final normalized = name.trim();
    if (normalized.isEmpty) return '?';
    // A Dart string is UTF-16; take the first code point (Chinese names are
    // in the BMP, emoji fallbacks are not used for member names).
    return String.fromCharCode(normalized.runes.first);
  }

  /// A two-line-friendly short name for a small badge. Many names start with
  /// 小 or a Latin letter, so a single character would make several members
  /// look identical. Badges use up to the first three characters; at two
  /// characters that is the whole short name in Chinese.
  String get shortBadge {
    final normalized = name.trim();
    if (normalized.isEmpty) return '?';
    final runes = normalized.runes.toList(growable: false);
    final take = runes.length <= 3 ? runes.length : 3;
    return String.fromCharCodes(runes.take(take));
  }

  bool matchesIdentity({
    int? personId,
    String? name,
    String? groupName,
  }) {
    if (personId != null && this.personId != null) {
      return personId == this.personId;
    }
    final targetName = normalizeAlbumPart(name ?? '');
    if (targetName.isEmpty) return false;
    final sameName = normalizeAlbumPart(this.name) == targetName ||
        normalizeAlbumPart(displayName) == targetName;
    return sameName && albumGroupsCanMatch(this.groupName, groupName ?? '');
  }

  @override
  bool operator ==(Object other) => other is AlbumMemberRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'AlbumMemberRef($key, $name/$groupName)';
}

/// One archived cheki / memory photo.
class AlbumPhoto {
  final int? mediaId;
  final String path;

  /// 切图 (scan crop) or 纪念照 (memory photo).
  final bool isScan;
  final String mediaLabel;
  final String processingLabel;
  final bool canAutoRectify;

  /// Record-level spec, e.g. "3寸 2" or "团切 · 2张".
  final String specLabel;

  /// Activity day of the photo (06:00 boundary), or null when unknown.
  final DateTime? activityDay;

  /// True when [activityDay] came from the camera/EXIF capture time.
  final bool dateFromPhoto;
  final DateTime? capturedAt;
  final DateTime? recordDay;

  /// True for multi-person cuts (团切 / 双人切) without a single owner.
  final bool isGroup;
  final List<AlbumMemberRef> members;

  final String activityName;
  final String venueName;
  final String cityName;
  final String sessionLabel;
  final String sessionKey;
  final DateTime? sessionDay;

  /// Event start/open time from the idol activity event cache, when matched.
  final String eventTimeLabel;

  const AlbumPhoto({
    this.mediaId,
    required this.path,
    required this.isScan,
    required this.mediaLabel,
    this.processingLabel = '',
    this.canAutoRectify = false,
    required this.specLabel,
    this.activityDay,
    this.dateFromPhoto = false,
    this.capturedAt,
    this.recordDay,
    this.isGroup = false,
    this.members = const [],
    this.activityName = '',
    this.venueName = '',
    this.cityName = '',
    this.sessionLabel = '',
    this.sessionKey = 'unknown',
    this.sessionDay,
    this.eventTimeLabel = '',
  });

  /// An attachment preview outside the album's member/day grouping.
  factory AlbumPhoto.attachment(ActivityRecordMediaModel media,
      {String specLabel = ''}) {
    final owner = media.ownerPersonName.trim();
    return AlbumPhoto(
      mediaId: media.id,
      path: media.path,
      isScan: media.isScan,
      mediaLabel: media.mediaType.label,
      processingLabel: media.processingMode.label,
      canAutoRectify: media.isScan && !media.processingMode.isProcessed,
      specLabel: specLabel,
      members: [
        if (owner.isNotEmpty)
          AlbumMemberRef(
            key: 'attachment:${media.id ?? media.path}',
            name: owner,
            groupName: media.ownerGroupName,
            personId: media.ownerPersonId,
          ),
      ],
    );
  }

  String get heroTag =>
      mediaId != null ? 'album-photo-$mediaId' : 'album-path-${path.hashCode}';

  String get memberCaption {
    if (members.isEmpty) return '未归属';
    if (isGroup) {
      if (members.length == 1) return members.first.displayName;
      return '团切 · ${members.length}人';
    }
    return members.first.displayName;
  }

  String get dayCaption {
    final day = activityDay;
    if (day == null) return '日期不明';
    return '${day.month}.${day.day}';
  }

  AlbumMemberRef? get primaryMember => members.isEmpty ? null : members.first;

  /// Human name for the session this photo belongs to, using the shared
  /// fallback order (activity → groups → venue → member names → 未记公演).
  String get sessionTitle => albumSessionTitle(
        activityName: activityName,
        venueName: venueName,
        members: members,
      );

  String get sessionSubtitle {
    final parts = <String>[
      if (cityName.trim().isNotEmpty) cityName.trim(),
      if (venueName.trim().isNotEmpty && venueName.trim() != sessionTitle)
        venueName.trim(),
      if (sessionLabel.trim().isNotEmpty) sessionLabel.trim(),
      if (eventTimeLabel.trim().isNotEmpty &&
          !sessionLabel.contains(eventTimeLabel))
        '${eventTimeLabel.trim()} 开演',
    ];
    return parts.join(' · ');
  }

  bool matchesMember({
    int? personId,
    String? name,
    String? groupName,
  }) {
    return members.any(
      (member) => member.matchesIdentity(
        personId: personId,
        name: name,
        groupName: groupName,
      ),
    );
  }
}

/// One activity day in the timeline. [day] is null for "日期不明".
class AlbumDay {
  final DateTime? day;
  final List<AlbumPhoto> photos;

  const AlbumDay({this.day, required this.photos});

  int get count => photos.length;
}

class AlbumMonth {
  final DateTime month; // first day of the month
  final List<AlbumDay> days;

  const AlbumMonth({required this.month, required this.days});

  int get count => days.fold<int>(0, (sum, day) => sum + day.count);
}

class AlbumSession {
  final String key;
  final DateTime? day;
  final String title;
  final String venueName;
  final String cityName;
  final String sessionLabel;
  final String eventTimeLabel;
  final List<AlbumPhoto> photos;
  final List<AlbumMemberRef> members;

  const AlbumSession({
    required this.key,
    this.day,
    required this.title,
    required this.venueName,
    required this.cityName,
    required this.sessionLabel,
    required this.eventTimeLabel,
    required this.photos,
    required this.members,
  });

  int get count => photos.length;

  String get subtitle {
    final parts = <String>[
      if (cityName.trim().isNotEmpty) cityName.trim(),
      if (venueName.trim().isNotEmpty && venueName.trim() != title)
        venueName.trim(),
      if (sessionLabel.trim().isNotEmpty) sessionLabel.trim(),
      if (eventTimeLabel.trim().isNotEmpty &&
          !sessionLabel.contains(eventTimeLabel))
        '${eventTimeLabel.trim()} 开演',
    ];
    return parts.join(' · ');
  }
}

/// One member's cover and photos in the 人物 view.
class AlbumMemberAlbum {
  final AlbumMemberRef member;
  final List<AlbumPhoto> soloPhotos;
  final List<AlbumPhoto> groupPhotos;

  const AlbumMemberAlbum({
    required this.member,
    required this.soloPhotos,
    required this.groupPhotos,
  });

  int get soloCount => soloPhotos.length;
  int get groupCount => groupPhotos.length;
  int get total => soloPhotos.length + groupPhotos.length;

  List<AlbumPhoto> get photos => [...soloPhotos, ...groupPhotos];

  AlbumPhoto? get cover =>
      soloPhotos.isNotEmpty ? soloPhotos.first : groupPhotos.firstOrNull;

  DateTime? get latestDay {
    final photo = cover;
    return photo?.activityDay;
  }
}

/// Hint from the cached idol activity events (演出名单), used only to fill an
/// empty venue/time on a ledger record whose activity name and date match
/// exactly. Never guesses across differently named events.
class AlbumEventHint {
  final DateTime day;
  final String eventName;
  final String venue;
  final String city;
  final String startTime;

  const AlbumEventHint({
    required this.day,
    required this.eventName,
    this.venue = '',
    this.city = '',
    this.startTime = '',
  });

  String get key => '${albumDateKey(day)}|${normalizeAlbumPart(eventName)}';
}

/// Fully grouped album. Views read from here; no view recomputes grouping.
class AlbumData {
  final List<AlbumPhoto> photos;
  final List<AlbumMonth> months;
  final AlbumDay? undatedDay;
  final List<AlbumSession> sessions;
  final List<AlbumMemberAlbum> members;
  final List<AlbumPhoto> unattributedPhotos;

  const AlbumData({
    required this.photos,
    required this.months,
    required this.members,
    required this.sessions,
    required this.unattributedPhotos,
    this.undatedDay,
  });

  bool get isEmpty => photos.isEmpty;

  int get photoCount => photos.length;
  int get scanCount => photos.where((photo) => photo.isScan).length;
  int get memoryCount => photos.length - scanCount;

  int get dayCount => photos
      .map((photo) => photo.activityDay)
      .whereType<DateTime>()
      .toSet()
      .length;

  int get memberCount => members.length;

  List<int> get years {
    final values = months.map((month) => month.month.year).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return values;
  }

  int photosInYear(int year) =>
      photos.where((photo) => photo.activityDay?.year == year).length;

  int monthCountInYear(int year) =>
      months.where((month) => month.month.year == year).length;

  /// A member-filtered copy, used by `AlbumPage.openForMember` and by tapping
  /// a cover in the 人物 view.
  AlbumData filteredToMember({
    int? personId,
    String? name,
    String? groupName,
  }) {
    final filtered = photos
        .where(
          (photo) => photo.matchesMember(
            personId: personId,
            name: name,
            groupName: groupName,
          ),
        )
        .toList(growable: false);
    return assembleAlbumData(filtered);
  }

  /// Groups plain photo rows into months / members / sessions. Kept public so
  /// filtered copies reuse exactly the same ordering and bucketing.
  static AlbumData assemble(List<AlbumPhoto> photos) {
    final ordered = List<AlbumPhoto>.from(photos)..sort(compareAlbumPhotos);

    final dayBuckets = <DateTime, List<AlbumPhoto>>{};
    final undated = <AlbumPhoto>[];
    for (final photo in ordered) {
      final day = photo.activityDay;
      if (day == null) {
        undated.add(photo);
      } else {
        dayBuckets.putIfAbsent(day, () => <AlbumPhoto>[]).add(photo);
      }
    }

    final monthBuckets = <DateTime, List<AlbumDay>>{};
    for (final entry in dayBuckets.entries) {
      final month = DateTime(entry.key.year, entry.key.month);
      monthBuckets
          .putIfAbsent(month, () => <AlbumDay>[])
          .add(AlbumDay(day: entry.key, photos: entry.value));
    }
    final months = monthBuckets.entries
        .map(
          (entry) => AlbumMonth(
            month: entry.key,
            days: entry.value..sort((a, b) => b.day!.compareTo(a.day!)),
          ),
        )
        .toList()
      ..sort((a, b) => b.month.compareTo(a.month));

    final sessionBuckets = <String, _SessionBucket>{};
    final memberSolo = <String, List<AlbumPhoto>>{};
    final memberGroup = <String, List<AlbumPhoto>>{};
    final memberRefs = <String, AlbumMemberRef>{};
    final unattributed = <AlbumPhoto>[];

    for (final photo in ordered) {
      final bucket = sessionBuckets.putIfAbsent(
        photo.sessionKey,
        () => _SessionBucket(photo),
      );
      bucket.add(photo);

      if (photo.members.isEmpty) {
        unattributed.add(photo);
        continue;
      }
      for (final member in photo.members) {
        memberRefs[member.key] = member;
        final target = photo.isGroup ? memberGroup : memberSolo;
        target.putIfAbsent(member.key, () => <AlbumPhoto>[]).add(photo);
      }
    }

    final sessions = sessionBuckets.values
        .map((bucket) => bucket.toSession())
        .toList()
      ..sort(compareAlbumSessions);

    final members = memberRefs.values
        .map(
          (member) => AlbumMemberAlbum(
            member: member,
            soloPhotos: memberSolo[member.key] ?? const <AlbumPhoto>[],
            groupPhotos: memberGroup[member.key] ?? const <AlbumPhoto>[],
          ),
        )
        .toList()
      ..sort((a, b) {
        final countCompare = b.total.compareTo(a.total);
        if (countCompare != 0) return countCompare;
        final soloCompare = b.soloCount.compareTo(a.soloCount);
        if (soloCompare != 0) return soloCompare;
        final sortCompare = a.member.sortKey.compareTo(b.member.sortKey);
        if (sortCompare != 0) return sortCompare;
        return a.member.key.compareTo(b.member.key);
      });

    return AlbumData(
      photos: ordered,
      months: months,
      undatedDay: undated.isEmpty ? null : AlbumDay(day: null, photos: undated),
      members: members,
      sessions: sessions,
      unattributedPhotos: unattributed,
    );
  }
}

AlbumData assembleAlbumData(List<AlbumPhoto> photos) =>
    AlbumData.assemble(photos);

/// Newest first. Photos with a capture time are ordered by it; otherwise the
/// record time / createdAt order is preserved via the media id tie-breaker.
int compareAlbumPhotos(AlbumPhoto a, AlbumPhoto b) {
  final aDay = a.activityDay;
  final bDay = b.activityDay;
  if (aDay == null && bDay != null) return 1;
  if (aDay != null && bDay == null) return -1;
  if (aDay != null && bDay != null) {
    final dayCompare = bDay.compareTo(aDay);
    if (dayCompare != 0) return dayCompare;
  }
  final aTime = a.capturedAt;
  final bTime = b.capturedAt;
  if (aTime != null && bTime != null) {
    final timeCompare = bTime.compareTo(aTime);
    if (timeCompare != 0) return timeCompare;
  } else if (aTime != null && bTime == null) {
    return -1;
  } else if (aTime == null && bTime != null) {
    return 1;
  }
  final idCompare = (b.mediaId ?? -1).compareTo(a.mediaId ?? -1);
  if (idCompare != 0) return idCompare;
  return a.path.compareTo(b.path);
}

int compareAlbumSessions(AlbumSession a, AlbumSession b) {
  final aDay = a.day;
  final bDay = b.day;
  if (aDay == null && bDay != null) return 1;
  if (aDay != null && bDay == null) return -1;
  if (aDay != null && bDay != null) {
    final dayCompare = bDay.compareTo(aDay);
    if (dayCompare != 0) return dayCompare;
  }
  final labelCompare = a.sessionLabel.compareTo(b.sessionLabel);
  if (labelCompare != 0) return labelCompare;
  final titleCompare = a.title.compareTo(b.title);
  if (titleCompare != 0) return titleCompare;
  return a.key.compareTo(b.key);
}

class _SessionBucket {
  final DateTime? day;
  final String activityName;
  final String venueName;
  final String cityName;
  final String sessionLabel;
  final String eventTimeLabel;
  final List<AlbumPhoto> photos = [];
  final Map<String, AlbumMemberRef> members = {};
  final Map<String, int> memberCounts = {};

  _SessionBucket(AlbumPhoto first)
      : day = first.sessionDay,
        activityName = first.activityName,
        venueName = first.venueName,
        cityName = first.cityName,
        sessionLabel = first.sessionLabel,
        eventTimeLabel = first.eventTimeLabel;

  void add(AlbumPhoto photo) {
    photos.add(photo);
    for (final member in photo.members) {
      members[member.key] = member;
      memberCounts[member.key] = (memberCounts[member.key] ?? 0) + 1;
    }
  }

  AlbumSession toSession() {
    final memberList = members.values.toList()
      ..sort((a, b) {
        final countCompare =
            (memberCounts[b.key] ?? 0).compareTo(memberCounts[a.key] ?? 0);
        if (countCompare != 0) return countCompare;
        final sortCompare = a.sortKey.compareTo(b.sortKey);
        if (sortCompare != 0) return sortCompare;
        return a.key.compareTo(b.key);
      });
    final title = albumSessionTitle(
      activityName: activityName,
      venueName: venueName,
      members: memberList,
    );
    return AlbumSession(
      key: photos.first.sessionKey,
      day: day,
      title: title,
      venueName: venueName,
      cityName: cityName,
      sessionLabel: sessionLabel,
      eventTimeLabel: eventTimeLabel,
      photos: List<AlbumPhoto>.unmodifiable(photos),
      members: List<AlbumMemberRef>.unmodifiable(memberList),
    );
  }
}
