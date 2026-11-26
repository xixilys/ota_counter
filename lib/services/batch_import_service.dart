import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/face_sample_model.dart';
import '../models/group_pricing_model.dart';
import '../models/idol_activity_event_model.dart';
import 'album_orientation_service.dart';
import 'card_orientation.dart';
import 'database_service.dart';
import 'face/face_models.dart';
import 'face/face_recognition_rules.dart';
import 'face/face_sample_service.dart';
import 'idol_database_service.dart';
import 'record_scan_service.dart';

/// One original photo of a batch (camera shot or gallery pick).
class BatchSourcePhoto {
  final String path;

  /// Camera: shutter time. Gallery: EXIF DateTimeOriginal, null if absent.
  final DateTime? capturedAt;
  final bool fromCamera;

  const BatchSourcePhoto({
    required this.path,
    required this.capturedAt,
    required this.fromCamera,
  });
}

/// One polaroid cut out of a source photo.
class BatchCard {
  final Uint8List bytes;
  final String fileExtension;
  final ActivityRecordMediaProcessingMode processingMode;
  final RecordScanQuad quad;
  final RecordScanCardSize sizeClass;
  final double confidence;
  final bool splitFromMerged;

  /// Every detected face, best detector score first (embedding included).
  /// Empty when recognition is off.
  final List<FaceAnalysis> faces;

  /// 方向判断（白边厚的一侧 + 人脸）。null：旧数据或未判断。
  final CardOrientation? orientation;

  /// 方向证据缺失或互相矛盾，建议人工看一眼。
  bool get orientationLowConfidence => orientation?.lowConfidence ?? false;

  const BatchCard({
    required this.bytes,
    required this.fileExtension,
    required this.processingMode,
    required this.quad,
    required this.sizeClass,
    required this.confidence,
    required this.splitFromMerged,
    this.faces = const [],
    this.orientation,
  });
}

/// Processing result of one [BatchSourcePhoto].
class BatchSourceResult {
  final BatchSourcePhoto photo;
  final String sourceHash;
  final List<BatchCard> cards;
  final List<RecordScanMultiWarning> warnings;
  final int sourceWidth;
  final int sourceHeight;

  /// Media rows already imported from the same original.
  final int alreadyImported;
  final String? error;

  const BatchSourceResult({
    required this.photo,
    required this.sourceHash,
    required this.cards,
    this.warnings = const [],
    this.sourceWidth = 0,
    this.sourceHeight = 0,
    this.alreadyImported = 0,
    this.error,
  });
}

/// A session (场次) of the activity day: a ticket record and/or a public
/// event from 演出名单.
class BatchSession {
  final String title;
  final String subtitle;
  final ActivityRecordModel? ticket;
  final IdolActivityEvent? event;
  final List<String> groupNames;

  const BatchSession({
    required this.title,
    this.subtitle = '',
    this.ticket,
    this.event,
    this.groupNames = const [],
  });

  // Match using the same metadata that supplementary records will store.
  String get _activityName =>
      ticket?.resolvedActivityName.trim() ?? event?.eventName ?? '';
  String get _venueName =>
      ticket?.resolvedVenueName.trim() ?? event?.venue ?? '';
  String get _sessionLabel =>
      ticket?.sessionLabel.trim() ?? event?.sessionLabel ?? '';
  List<String> get _ledgerFields => [_activityName, _venueName, _sessionLabel]
      .map(BatchImportService._norm)
      .toList();
}

/// Ledger facts of one activity day.
class BatchDayContext {
  final DateTime day;
  final List<ActivityRecordModel> records;
  final List<BatchSession> sessions;
  final List<FaceMember> dayMembers;
  final List<CounterModel> counters;

  const BatchDayContext({
    required this.day,
    required this.records,
    required this.sessions,
    required this.dayMembers,
    required this.counters,
  });

  /// Member of a counter record (resolved through its counter).
  FaceMember? memberOfRecord(ActivityRecordModel record) {
    if (!record.isCounter) return null;
    CounterModel? counter;
    for (final c in counters) {
      if (c.id != null && c.id == record.counterId) counter = c;
    }
    counter ??= resolveCounterForActivityRecord(counters, record);
    if (counter != null) return FaceSampleService.memberFromCounter(counter);
    return FaceMember(
      personId: record.personId,
      name: record.subjectName,
      personName: record.personName,
      groupName: record.groupName,
    );
  }

  List<FaceMember> membersOfMulti(ActivityRecordModel record) {
    return [
      for (final p in record.effectiveParticipants)
        _resolveParticipant(p, counters),
    ];
  }

  static ChekiSize? _sizeOfMultiField(CounterCountField? field) {
    if (field == CounterCountField.threeInch ||
        field == CounterCountField.unsignedThreeInch) {
      return ChekiSize.threeInch;
    }
    if (field == CounterCountField.fiveInch ||
        field == CounterCountField.unsignedFiveInch) {
      return ChekiSize.fiveInch;
    }
    return null;
  }

  static int _countOfSize(ActivityRecordModel record, ChekiSize size) =>
      switch (size) {
        ChekiSize.threeInch => record.threeInchCount +
            record.unsignedThreeInchCount +
            record.threeInchShukudaiCount,
        ChekiSize.fiveInch => record.fiveInchCount +
            record.unsignedFiveInchCount +
            record.fiveInchShukudaiCount,
      };

  // Recognition intentionally shares a person across groups. Accounting must
  // also respect the affiliation selected on the card, and historic record
  // groups must not be overwritten by a counter's current affiliation.
  static FaceMember _withRecordedGroup(FaceMember member, String group) =>
      group.trim().isEmpty
          ? member
          : FaceMember(
              counterId: member.counterId,
              personId: member.personId,
              name: member.name,
              personName: member.personName,
              groupName: group,
            );

  static bool _sameLedgerMember(FaceMember a, FaceMember b) =>
      a.sameAs(b) &&
      (a.groupName.trim().isEmpty ||
          b.groupName.trim().isEmpty ||
          BatchImportService._norm(a.groupName) ==
              BatchImportService._norm(b.groupName));

  bool _sameSet(List<FaceMember> a, List<FaceMember> b) =>
      a.length == b.length &&
      a.every((x) => b.any((y) => _sameLedgerMember(y, x))) &&
      b.every((y) => a.any((x) => _sameLedgerMember(y, x)));

  bool _matchesSession(ActivityRecordModel record, BatchSession? session) {
    if (session == null) return true;
    final actual = [
      record.resolvedActivityName,
      record.resolvedVenueName,
      record.sessionLabel
    ].map(BatchImportService._norm).toList();
    // Legacy undifferentiated day records remain usable. A known conflicting
    // field, however, must never be hidden by another matching/empty field.
    if (actual.every((field) => field.isEmpty)) return true;
    final selected = session._ledgerFields;
    var shared = false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i].isEmpty) continue;
      if (selected[i].isNotEmpty) {
        if (actual[i] != selected[i]) return false;
        shared = true;
      } else {
        // A partially labelled selection cannot pick between two known
        // same-day sessions that differ precisely in this missing field.
        final alternatives = sessions
            .where((other) {
              final fields = other._ledgerFields;
              return List.generate(3, (j) => j).every((j) =>
                  selected[j].isEmpty ||
                  fields[j].isEmpty ||
                  selected[j] == fields[j]);
            })
            .map((other) => other._ledgerFields[i])
            .where((field) => field.isNotEmpty)
            .toSet();
        if (alternatives.length > 1) return false;
      }
    }
    return shared;
  }

  /// Same-day ledger records for the selected members, affiliations and optional
  /// session. Missing legacy metadata is compatible; known conflicts are not.
  List<ActivityRecordModel> recordsFor(List<FaceMember> members,
      {ChekiSize? size, bool? multiCut, BatchSession? session}) {
    if (members.isEmpty) return const [];
    if (!(multiCut ?? members.length > 1)) {
      return [
        for (final r in records)
          if (r.isCounter && _matchesSession(r, session))
            if (memberOfRecord(r) case final member?)
              if (_sameLedgerMember(_withRecordedGroup(member, r.groupName),
                      members.single) &&
                  (size == null || _countOfSize(r, size) > 0))
                r,
      ];
    }
    return [
      for (final r in records)
        if (r.isMulti &&
            _matchesSession(r, session) &&
            r.multiCountField != CounterCountField.groupCut &&
            (size == null || _sizeOfMultiField(r.multiCountField) == size) &&
            _sameSet([
              for (final p in r.effectiveParticipants)
                _withRecordedGroup(
                    _resolveParticipant(p, counters), p.groupName),
            ], members))
          r,
    ];
  }

  int existingCount(List<FaceMember> members, ChekiSize size,
      {bool? multiCut, BatchSession? session}) {
    final isMulti = multiCut ?? members.length > 1;
    var total = 0;
    for (final r in recordsFor(members,
        size: size, multiCut: isMulti, session: session)) {
      total += isMulti ? r.effectiveMultiQuantity : _countOfSize(r, size);
    }
    return total;
  }

  List<ActivityRecordModel> groupRecordsFor(String groupName,
          {BatchSession? session}) =>
      [
        for (final r in records)
          if (r.isMulti &&
              _matchesSession(r, session) &&
              r.multiCountField == CounterCountField.groupCut &&
              groupLedgerLineKey(r.groupName) == groupLedgerLineKey(groupName))
            r,
      ];

  int existingGroupCount(String groupName, {BatchSession? session}) =>
      groupRecordsFor(groupName, session: session)
          .fold(0, (sum, record) => sum + record.effectiveMultiQuantity);

  /// All polaroids of [member] that day (own records + multi cuts), or null
  /// when the ledger has none (= no soft cap).
  int? dayCap(FaceMember member) {
    var total = 0;
    for (final r in records) {
      if (r.isCounter && (memberOfRecord(r)?.sameAs(member) ?? false)) {
        total += _countOfSize(r, ChekiSize.threeInch) +
            _countOfSize(r, ChekiSize.fiveInch);
      } else if (r.isMulti && membersOfMulti(r).any((m) => m.sameAs(member))) {
        total += r.effectiveMultiQuantity;
      }
    }
    return total > 0 ? total : null;
  }
}

FaceMember _resolveParticipant(
  ActivityParticipant participant,
  List<CounterModel> counters,
) {
  final counter = DatabaseService.resolveCounterForParticipant(
    counters,
    participant,
  );
  if (counter != null) return FaceSampleService.memberFromCounter(counter);
  return FaceMember(
    personId: participant.personId,
    name: participant.memberName,
    personName: participant.personName,
    groupName: participant.groupName,
  );
}

/// One polaroid in the review grid. Mutable: the review page edits it.
class BatchReviewCard {
  final BatchSourceResult source;
  final BatchCard card;

  Uint8List bytes;
  String fileExtension;
  ActivityRecordMediaProcessingMode processingMode;
  RecordScanQuad quad;

  /// Assigned members (several = multi-member cut).
  List<FaceMember> members;
  FaceMatchStatus status;

  // Only recognition auto-matches downgraded solely for unresolved affiliation
  // can become auto again when the user picks the group. A similarity review
  // still needs its own confirmation.
  bool _autoAfterAffiliation = false;

  /// Up to three suggestions for 待确认 / 未认出.
  final List<FaceMember> suggestions;
  ChekiSize size;
  bool sizeUncertain;

  /// The user changed the members.
  bool edited = false;
  final List<FaceMember> removedRecognizedMembers = [];

  /// All cards of the same real person across groups (兼任 / 转团), keyed by
  /// [FaceMember.key]. Recognition scores one person once, but saving needs
  /// one concrete group card.
  final Map<String, List<FaceMember>> affiliationOptions;

  /// Person keys whose group the user explicitly chose (or that had only one
  /// possible card), so the save flow does not need to ask again.
  final Set<String> confirmedAffiliationKeys = <String>{};

  void rememberRemovedRecognitions(
      List<FaceMember> before, List<FaceMember> after) {
    for (final match in faceMatches) {
      final member = match.member;
      if (member != null &&
          before.any((m) => m.sameAs(member)) &&
          !after.any((m) => m.sameAs(member)) &&
          !removedRecognizedMembers.any((m) => m.sameAs(member))) {
        removedRecognizedMembers.add(member);
      }
    }
  }

  BatchCutType? _cutType;
  String groupName = '';
  final bool groupSuggested;
  final String? suggestedGroupName;
  bool groupSuggestionDismissed = false;

  BatchCutType get cutType =>
      _cutType ??
      (members.length > 1 ? BatchCutType.multi : BatchCutType.single);
  set cutType(BatchCutType value) => _cutType = value;

  bool get hasRequiredDetails => cutType == BatchCutType.group
      ? groupName.trim().isNotEmpty
      : members.isNotEmpty &&
          (cutType != BatchCutType.single || members.length == 1);

  List<FaceMember> affiliationsFor(FaceMember member) =>
      affiliationOptions[member.key] ?? [member];

  /// True when one person has cards in several groups and the batch context
  /// (session / day's groups) did not pick exactly one. Saving must not guess.
  bool isAffiliationAmbiguous(FaceMember member) {
    if (confirmedAffiliationKeys.contains(member.key)) return false;
    final groups = affiliationsFor(member)
        .map((m) => m.groupName.trim().toLowerCase())
        .where((group) => group.isNotEmpty)
        .toSet();
    return groups.length > 1;
  }

  List<FaceMember> get unresolvedAffiliationMembers => [
        for (final member in members)
          if (isAffiliationAmbiguous(member)) member,
      ];

  void confirmAffiliation(FaceMember selected) {
    confirmedAffiliationKeys.add(selected.key);
    final index = members.indexWhere((m) => m.key == selected.key);
    if (index >= 0) {
      members[index] = selected;
      if (_autoAfterAffiliation &&
          status == FaceMatchStatus.review &&
          unresolvedAffiliationMembers.isEmpty) {
        status = FaceMatchStatus.auto;
        _autoAfterAffiliation = false;
      }
    }
  }

  /// Non-self faces and the member each was matched to (null = none).
  final List<({FaceAnalysis face, FaceMember? member})> faceMatches;

  BatchReviewCard({
    required this.source,
    required this.card,
    required this.members,
    required this.status,
    required this.suggestions,
    required this.size,
    required this.sizeUncertain,
    required this.faceMatches,
    this.affiliationOptions = const {},
    this.groupSuggested = false,
    this.suggestedGroupName,
  })  : bytes = card.bytes,
        fileExtension = card.fileExtension,
        processingMode = card.processingMode,
        quad = card.quad;

  /// Faces the user confirmed by saving, as (face, member): auto or
  /// suggested matches left as they were, or the only face of a single-face
  /// card the user assigned to one member. Ambiguous edits teach nothing.
  List<({FaceAnalysis face, FaceMember member})> get confirmedFaces {
    if (cutType == BatchCutType.group || !edited) {
      return [
        for (final m in faceMatches)
          if (m.member != null &&
              members.any((x) => x.sameAs(m.member!)) &&
              !removedRecognizedMembers.any((x) => x.sameAs(m.member!)))
            (face: m.face, member: m.member!),
      ];
    }
    if (faceMatches.length == 1 && members.length == 1) {
      return [(face: faceMatches.single.face, member: members.single)];
    }
    return const [];
  }
}

/// A [LedgerLine] with what it refers to.
class BatchLedgerEntry {
  final LedgerLine line;
  final List<FaceMember> members;

  /// Cards of this line, in review order.
  final List<BatchReviewCard> cards;

  const BatchLedgerEntry({
    required this.line,
    required this.members,
    required this.cards,
  });

  String get label => line.isGroup
      ? line.groupName
      : members.map((m) => m.name.trim()).join(' + ');
}

class BatchSavePlan {
  final List<ActivityRecordModel> newRecords;
  final List<BatchMediaInput> media;

  /// Review card of each [media] entry.
  final List<BatchReviewCard> mediaCards;

  const BatchSavePlan({
    required this.newRecords,
    required this.media,
    required this.mediaCards,
  });
}

class BatchSaveSummary {
  final int photos;
  final int newRecords;
  final int learnedFaces;

  const BatchSaveSummary({
    required this.photos,
    required this.newRecords,
    required this.learnedFaces,
  });
}

/// 批量拍切: cut → recognise → assign → save.
class BatchImportService {
  BatchImportService._();

  static const String supplementNote = '批量拍切补记';

  static ChekiSize sizeOf(RecordScanCardSize size) =>
      size == RecordScanCardSize.wide
          ? ChekiSize.fiveInch
          : ChekiSize.threeInch;

  // ---------------------------------------------------------------------
  // Per photo

  static Future<String> sha1OfFile(String path) => Isolate.run(
      () async => sha1.convert(await File(path).readAsBytes()).toString());

  /// EXIF DateTimeOriginal ("YYYY:MM:DD HH:MM:SS", local time), or null.
  static DateTime? readExifCaptureTime(Uint8List bytes) {
    try {
      final exif = img.decodeJpgExif(bytes);
      if (exif == null) return null;
      final value = exif.exifIfd[0x9003] ?? exif.getTag(0x9003);
      if (value == null) return null;
      return parseExifDateTime(value.toString());
    } catch (_) {
      return null;
    }
  }

  static DateTime? parseExifDateTime(String raw) {
    final m = RegExp(r'^\s*(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})')
        .firstMatch(raw);
    if (m == null) return null;
    final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    if (parts[0] < 1990 || parts[1] < 1 || parts[1] > 12 || parts[2] < 1) {
      return null;
    }
    return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
  }

  static Future<DateTime?> readExifCaptureTimeFromFile(String path) =>
      Isolate.run(
          () async => readExifCaptureTime(await File(path).readAsBytes()));

  /// Hash + missing gallery EXIF time from one read → cut → optional faces.
  /// The returned photo carries the resolved original capture time even when
  /// recognition is disabled; supplied times always take precedence.
  static Future<BatchSourceResult> processPhoto(
    BatchSourcePhoto photo, {
    FaceAnalyzer? analyzer,
  }) async {
    var hash = '';
    var resolvedPhoto = photo;
    try {
      final path = photo.path;
      final readCaptureTime = !photo.fromCamera && photo.capturedAt == null;
      final metadata = await Isolate.run(() async {
        final bytes = await File(path).readAsBytes();
        return (
          hash: sha1.convert(bytes).toString(),
          capturedAt: readCaptureTime ? readExifCaptureTime(bytes) : null,
        );
      });
      hash = metadata.hash;
      if (metadata.capturedAt != null) {
        resolvedPhoto = BatchSourcePhoto(
          path: photo.path,
          capturedAt: metadata.capturedAt,
          fromCamera: photo.fromCamera,
        );
      }
      final already =
          (await DatabaseService.countMediaBySourceHash([hash]))[hash] ?? 0;
      final scan =
          await RecordScanService.createMultiScan(sourceFile: File(photo.path));
      var scanCards = scan.cards;
      var warnings = scan.warnings;
      if (scanCards.isEmpty && scan.sourceWidth > 0 && scan.sourceHeight > 0) {
        // No polaroid border found — typically a photo that is already just
        // the picture (cropped earlier, or saved from a chat). Keep the whole
        // frame as one card instead of dropping it silently; the review page
        // shows it with an uncertain size and it can be re-cropped there.
        final w = scan.sourceWidth.toDouble(), h = scan.sourceHeight.toDouble();
        final quad = RecordScanQuad(
          topLeftX: 0,
          topLeftY: 0,
          topRightX: w,
          topRightY: 0,
          bottomLeftX: 0,
          bottomLeftY: h,
          bottomRightX: w,
          bottomRightY: h,
        );
        final whole = await RecordScanService.createManualScan(
          sourceBytes: await File(photo.path).readAsBytes(),
          quad: quad,
        );
        scanCards = [
          RecordScanMultiCard(
            bytes: Uint8List.fromList(whole.bytes),
            fileExtension: whole.fileExtension,
            processingMode: whole.processingMode,
            quad: quad,
            sizeClass: RecordScanCardSize.uncertain,
            aspectRatio: math.min(w, h) / math.max(w, h),
            confidence: 0,
            splitFromMerged: false,
          ),
        ];
        warnings = [
          for (final warning in warnings)
            if (warning != RecordScanMultiWarning.noneDetected) warning,
        ];
      }
      final cards = <BatchCard>[];
      for (final card in scanCards) {
        // Orientation belongs to the cut bytes, not the thumbnail. The
        // original source hash and source-space crop quad stay unchanged.
        // With a settled film format, the thick border and the faces decide
        // together; otherwise only faces can turn the card, and the result
        // is marked low-confidence (no border evidence).
        final Uint8List bytes;
        final CardOrientation orientation;
        if (card.layoutTurns != null) {
          (bytes, orientation) = await AlbumOrientationService.orientCardBytes(
            card.bytes,
            layoutTurns: card.layoutTurns!,
            miniFilm: card.miniFilm,
            layoutConfident: card.layoutConfident,
          );
        } else {
          final (oriented, angle) =
              await AlbumOrientationService.orientScanBytesWithAngle(
                  card.bytes);
          bytes = oriented;
          orientation = CardOrientation(
              (-angle ~/ 90) % 4, CardOrientationBasis.face,
              lowConfidence: true);
        }
        var faces = const <FaceAnalysis>[];
        if (analyzer != null) {
          try {
            faces = await analyzer(bytes);
          } catch (_) {
            faces = const [];
          }
        }
        cards.add(BatchCard(
          bytes: bytes,
          fileExtension: card.fileExtension,
          processingMode: card.processingMode,
          quad: card.quad,
          sizeClass: card.sizeClass,
          confidence: card.confidence,
          splitFromMerged: card.splitFromMerged,
          faces: faces,
          orientation: orientation,
        ));
      }
      return BatchSourceResult(
        photo: resolvedPhoto,
        sourceHash: hash,
        cards: cards,
        warnings: warnings,
        sourceWidth: scan.sourceWidth,
        sourceHeight: scan.sourceHeight,
        alreadyImported: already,
      );
    } catch (error) {
      return BatchSourceResult(
        photo: resolvedPhoto,
        sourceHash: hash,
        cards: const [],
        error: '$error',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Day / session / candidates

  static Future<Set<DateTime>> daysWithRecords() async {
    return {
      for (final t in await DatabaseService.getActivityRecordTimes())
        recordActivityDay(t),
    };
  }

  static Future<DateTime> suggestDay(Iterable<DateTime?> captureTimes) async {
    return inferDefaultActivityDay(
      captureTimes: captureTimes,
      daysWithData: await daysWithRecords(),
      now: DateTime.now(),
    );
  }

  static String _norm(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');

  static Future<BatchDayContext> loadDayContext(DateTime day) async {
    final start = dateOnly(day);
    final candidates = await DatabaseService.getActivityRecordsBetween(
      start,
      DateTime(start.year, start.month, start.day + 1, activityDayStartHour),
    );
    final records = candidates
        .where((r) => recordActivityDay(r.occurredAt) == start)
        .toList();
    final counters = await DatabaseService.getCounters();

    List<IdolActivityEvent> events = const [];
    try {
      events = await IdolDatabaseService.getActivityEvents(
        from: start,
        to: start,
        limit: 500,
      );
    } catch (_) {
      // 演出名单 is optional context.
    }

    final context = BatchDayContext(
      day: start,
      records: records,
      sessions: const [],
      dayMembers: const [],
      counters: counters,
    );
    final dayMembers = <FaceMember>[];
    for (final r in records) {
      if (r.isCounter) {
        final m = context.memberOfRecord(r);
        if (m != null) dayMembers.add(m);
      } else if (r.isMulti) {
        dayMembers.addAll(context.membersOfMulti(r));
      }
    }
    final dayGroups = {
      for (final m in dayMembers)
        if (m.groupName.trim().isNotEmpty) _norm(m.groupName),
    };

    final sessions = <BatchSession>[];
    final usedEvents = <IdolActivityEvent>{};
    for (final ticket
        in records.where((r) => r.type == ActivityRecordType.ticket)) {
      final name = ticket.resolvedActivityName.trim().isNotEmpty
          ? ticket.resolvedActivityName.trim()
          : ticket.subjectName.trim();
      IdolActivityEvent? event;
      for (final e in events) {
        if (_norm(e.eventName) == _norm(name)) event = e;
      }
      if (event != null) usedEvents.add(event);
      sessions.add(BatchSession(
        title: name.isEmpty ? '门票' : name,
        subtitle: [
          '门票',
          if (ticket.resolvedVenueName.isNotEmpty) ticket.resolvedVenueName,
          if (ticket.sessionLabel.trim().isNotEmpty) ticket.sessionLabel.trim(),
        ].join(' · '),
        ticket: ticket,
        event: event,
        groupNames: [
          if (event != null)
            for (final g in event.groups)
              if (g.name.isNotEmpty) g.name,
          if (ticket.groupName.trim().isNotEmpty) ticket.groupName.trim(),
        ],
      ));
    }
    // Public events: those of the day's groups; when the day has no ticket
    // and no related event, every event of that day.
    var related = events
        .where((e) =>
            !usedEvents.contains(e) &&
            e.groups.any((g) => dayGroups.contains(_norm(g.name))))
        .toList();
    if (sessions.isEmpty && related.isEmpty) {
      related = events.take(30).toList();
    }
    for (final e in related) {
      sessions.add(BatchSession(
        title: e.eventName,
        subtitle: e.displaySubtitle,
        event: e,
        groupNames: [
          for (final g in e.groups)
            if (g.name.isNotEmpty) g.name,
        ],
      ));
    }

    return BatchDayContext(
      day: start,
      records: records,
      sessions: sessions,
      dayMembers: dayMembers,
      counters: counters,
    );
  }

  /// Counters plus idol-database members of [groupNames].
  static Future<List<FaceMember>> membersOfGroups(
    Iterable<String> groupNames,
    List<CounterModel> counters,
  ) async {
    final wanted = {for (final g in groupNames) _norm(g)}..remove('');
    if (wanted.isEmpty) return const [];
    final out = <FaceMember>[
      for (final c in counters)
        if (wanted.contains(_norm(c.groupName)))
          FaceSampleService.memberFromCounter(c),
    ];
    try {
      final groups = await IdolDatabaseService.getGroups();
      for (final group in groups) {
        if (group.id == null || !wanted.contains(_norm(group.name))) continue;
        for (final m
            in await IdolDatabaseService.getMembers(groupId: group.id)) {
          if (m.isFormerAffiliation) continue;
          out.add(FaceMember(
            personId: m.personId,
            name: m.displayName,
            personName: m.personName,
            groupName: m.groupName,
          ));
        }
      }
    } catch (_) {
      // Idol database is optional context.
    }
    return out;
  }

  static List<FaceMember> allMembers(List<CounterModel> counters) => [
        for (final c in counters) FaceSampleService.memberFromCounter(c),
      ];

  // ---------------------------------------------------------------------
  // Recognition

  /// Builds the review cards: drops "我", scores every remaining face against
  /// the [candidates]' samples, and runs [assignFacesToMembers] with the
  /// day's counts as soft caps. Without samples (or with recognition off)
  /// every card is 未认出. [groupCandidates] retains the day's separate
  /// affiliations when a single recognised person belongs to several groups.
  /// Pass every member as [candidates] with the day's / session's members
  /// first; [preferredCount] of them may be auto-accepted, the rest only
  /// suggested for review.
  static List<BatchReviewCard> recognize({
    required List<BatchSourceResult> sources,
    required List<FaceMember> candidates,
    required List<FaceSampleModel> samples,
    List<FaceMember>? groupCandidates,
    BatchDayContext? day,
    int? preferredCount,
    List<String> preferredGroups = const [],
    List<String> sessionGroups = const [],
  }) {
    final selfSamples = [
      for (final s in samples)
        if (s.isSelf) s.embedding,
    ];
    final memberSamples =
        FaceSampleService.samplesByMember(candidates, samples);
    final rivalSamples = FaceSampleService.rivalSamples(candidates, samples);
    final sampledPeople =
        memberSamples.where((s) => s.isNotEmpty).length + rivalSamples.length;
    final caps = <int, int>{};
    if (day != null) {
      for (var i = 0; i < candidates.length; i++) {
        final cap = day.dayCap(candidates[i]);
        if (cap != null) caps[i] = cap;
      }
    }

    final flat = <({BatchSourceResult source, BatchCard card})>[];
    final faceLists = <List<FaceAnalysis>>[];
    final scoreLists = <List<List<double>>>[];
    final rivalLists = <List<double>>[];
    for (final source in sources) {
      for (final card in source.cards) {
        final faces = [
          for (final f in card.faces)
            if (!isSelfFace(f.embedding, selfSamples)) f,
        ];
        flat.add((source: source, card: card));
        faceLists.add(faces);
        scoreLists.add([
          for (final f in faces)
            [
              for (final s in memberSamples)
                s.isEmpty ? -1.0 : maxSimilarity(f.embedding, s),
            ],
        ]);
        rivalLists.add([
          for (final f in faces)
            rivalSamples.fold<double>(
              -1.0,
              (best, s) => math.max(best, maxSimilarity(f.embedding, s)),
            ),
        ]);
      }
    }
    final assignments = assignFacesToMembers(
      cards: scoreLists,
      candidateCount: candidates.length,
      caps: caps,
      rivals: rivalLists,
      sampledPeople: sampledPeople,
      preferredCount: preferredCount,
    );
    final affiliationPool = groupCandidates ?? candidates;
    List<FaceMember> affiliationsFor(FaceMember member) {
      final result = <FaceMember>[];
      for (final candidate in affiliationPool) {
        if (!candidate.sameAs(member)) continue;
        final groupKey = candidate.groupName.trim().toLowerCase();
        if (result.any((m) => m.groupName.trim().toLowerCase() == groupKey)) {
          continue;
        }
        result.add(candidate);
      }
      if (!result.any((m) =>
          m.groupName.trim().toLowerCase() ==
          member.groupName.trim().toLowerCase())) {
        result.insert(0, member);
      }
      return result;
    }

    FaceMember preferredAffiliation(
      List<FaceMember> options,
      FaceMember fallback,
    ) {
      for (final group in preferredGroups) {
        final normalized = group.trim().toLowerCase();
        if (normalized.isEmpty) continue;
        for (final option in options) {
          if (option.groupName.trim().toLowerCase() == normalized) {
            return option;
          }
        }
      }
      return options.firstWhere(
        (option) =>
            option.groupName.trim().toLowerCase() ==
            fallback.groupName.trim().toLowerCase(),
        orElse: () => options.first,
      );
    }

    final reviewCards = <BatchReviewCard>[];
    for (var i = 0; i < flat.length; i++) {
      final recognized = <FaceMember>[];
      final optionsByKey = <String, List<FaceMember>>{};
      final ambiguousKeys = <String>{};
      for (final c in assignments[i].candidates) {
        final person = candidates[c];
        final options = affiliationsFor(person);
        final chosen =
            options.length > 1 ? preferredAffiliation(options, person) : person;
        recognized.add(chosen);
        optionsByKey[chosen.key] = options;
        if (options.length > 1) {
          // The chosen session is the strongest signal. If it names exactly
          // one of this person's cards, no question is needed. Without a
          // session, only exactly one card active that day is safe; two day
          // groups / two session groups must ask instead of guessing.
          final normalizedSessionGroups = {
            for (final group in sessionGroups) group.trim().toLowerCase(),
          }..remove('');
          final sessionMatches = options
              .where((option) => normalizedSessionGroups.contains(
                    option.groupName.trim().toLowerCase(),
                  ))
              .length;
          final dayMatches = options
              .where((option) => preferredGroups.any(
                    (group) =>
                        group.trim().toLowerCase() ==
                        option.groupName.trim().toLowerCase(),
                  ))
              .length;
          final unambiguousSession = sessionMatches == 1;
          final unambiguousDay = sessionMatches == 0 && dayMatches == 1;
          if (!unambiguousSession && !unambiguousDay) {
            ambiguousKeys.add(chosen.key);
          }
        }
      }
      final group = suggestGroupCut(
        candidates: groupCandidates ?? candidates,
        recognized: recognized,
        nonSelfFaceCount: faceLists[i].length,
      );
      final card = BatchReviewCard(
        source: flat[i].source,
        card: flat[i].card,
        members: recognized,
        status: ambiguousKeys.isEmpty
            ? assignments[i].status
            : FaceMatchStatus.review,
        suggestions: [
          for (final c in assignments[i].topCandidates) candidates[c],
        ],
        size: sizeOf(flat[i].card.sizeClass),
        // A square print counts as neither 三寸 nor 五寸: ask.
        sizeUncertain: flat[i].card.sizeClass == RecordScanCardSize.uncertain ||
            flat[i].card.sizeClass == RecordScanCardSize.square,
        faceMatches: [
          for (var f = 0; f < faceLists[i].length; f++)
            (
              face: faceLists[i][f],
              member: assignments[i].faces[f].candidate == null
                  ? null
                  : (() {
                      final original =
                          candidates[assignments[i].faces[f].candidate!];
                      return recognized.firstWhere(
                        (m) => m.sameAs(original),
                        orElse: () => original,
                      );
                    })(),
            ),
        ],
        affiliationOptions: optionsByKey,
        groupSuggested: group.suggested,
        suggestedGroupName: group.groupName,
      );
      card._autoAfterAffiliation =
          assignments[i].status == FaceMatchStatus.auto &&
              ambiguousKeys.isNotEmpty;
      card.confirmedAffiliationKeys.addAll(
        optionsByKey.keys.where((key) => !ambiguousKeys.contains(key)),
      );
      reviewCards.add(card);
    }
    return reviewCards;
  }

  // ---------------------------------------------------------------------
  // Ledger + save

  static String _ledgerMemberKey(FaceMember member) =>
      member.groupName.trim().isEmpty
          ? member.key
          : '${member.key}|g:${_norm(member.groupName)}';

  /// Groups confirmed affiliations into lines, offset by the selected session.
  static List<BatchLedgerEntry> planEntries(
    List<BatchReviewCard> cards,
    BatchDayContext day, {
    BatchSession? session,
  }) {
    final groups = <String, List<BatchReviewCard>>{};
    final membersByKey = <String, List<FaceMember>>{};
    for (final card in cards) {
      if (!card.hasRequiredDetails) continue;
      final memberKeys = card.members.map(_ledgerMemberKey).toSet().toList()
        ..sort();
      final key = card.cutType == BatchCutType.group
          ? groupLedgerLineKey(card.groupName)
          : '${card.cutType == BatchCutType.multi && memberKeys.length == 1 ? 'multi:' : ''}${ledgerLineKey(memberKeys, card.size)}';
      groups.putIfAbsent(key, () => []).add(card);
      final members = membersByKey.putIfAbsent(key, () => []);
      for (final member in card.members) {
        if (!members.any((m) => BatchDayContext._sameLedgerMember(m, member))) {
          members.add(member);
        }
      }
    }
    final entries = <BatchLedgerEntry>[];
    for (final entry in groups.entries) {
      final first = entry.value.first;
      final members = membersByKey[entry.key]!;
      final memberKeys = members.map(_ledgerMemberKey).toSet().toList()..sort();
      final isGroup = first.cutType == BatchCutType.group;
      final isMulti = first.cutType == BatchCutType.multi;
      final line = LedgerLine(
        memberKeys: memberKeys,
        size: first.size,
        photoCount: entry.value.length,
        existingCount: isGroup
            ? day.existingGroupCount(first.groupName, session: session)
            : day.existingCount(members, first.size,
                multiCut: isMulti, session: session),
        multiCut: isMulti,
        groupName: isGroup ? first.groupName.trim() : '',
      );
      entries.add(BatchLedgerEntry(
        line: line,
        members: members,
        cards: entry.value,
      ));
    }
    return entries;
  }

  static DateTime _recordTime(BatchDayContext day, BatchSession? session) {
    final ticketTime = session?.ticket?.occurredAt;
    if (ticketTime != null && recordActivityDay(ticketTime) == day.day) {
      return ticketTime;
    }
    return day.day;
  }

  static ActivityRecordMediaOwnerScope _ownerScope(FaceMember m) =>
      ActivityRecordMediaOwnerScope(
        personId: m.personId,
        personName: m.identityName,
        groupName: m.groupName.trim(),
      );

  /// Records to add and where each photo goes. Per line: the first
  /// `existing` photos are attached to the member's existing record of that
  /// day, the rest to the supplementary `+N` record — unless the user
  /// switched it off ([disabledLines] holds [LedgerLine.lineKey]s), in which
  /// case they also go to the existing record, or to the chosen session's
  /// ticket when the member has none.
  static Future<BatchSavePlan> buildSavePlan({
    required List<BatchReviewCard> cards,
    required BatchDayContext day,
    BatchSession? session,
    Set<String> disabledLines = const {},
  }) async {
    final unassigned = cards.where((c) => !c.hasRequiredDetails).length;
    if (unassigned > 0) {
      throw StateError('还有 $unassigned 张没有指定成员或团体');
    }
    for (final card in cards) {
      final ambiguous = card.unresolvedAffiliationMembers;
      if (ambiguous.isNotEmpty) {
        throw StateError(
          '${ambiguous.map((m) => '${m.name}（${m.groupName}）').join('、')} '
          '在多个团都有卡片，请先在复核卡上选择这张算到哪个团',
        );
      }
    }
    final newRecords = <ActivityRecordModel>[];
    final media = <BatchMediaInput>[];
    final mediaCards = <BatchReviewCard>[];
    final occurredAt = _recordTime(day, session);
    final activityName = session?._activityName ?? '';
    final venueName = session?._venueName ?? '';
    final sessionLabel = session?._sessionLabel ?? '';

    for (final entry in planEntries(cards, day, session: session)) {
      final line = entry.line;
      final existingRecords = (line.isGroup
              ? day.groupRecordsFor(line.groupName, session: session)
              : day.recordsFor(entry.members,
                  size: line.size, multiCut: line.isMulti, session: session))
          .toList()
        ..sort((a, b) => _sizeCount(b, line.size, line.isMulti || line.isGroup)
            .compareTo(_sizeCount(a, line.size, line.isMulti || line.isGroup)));
      final existingRecord = existingRecords.isEmpty
          ? (line.isGroup
              ? null
              : day
                  .recordsFor(entry.members,
                      multiCut: line.isMulti, session: session)
                  .firstOrNull)
          : existingRecords.first;
      int? supplementIndex;
      final groupSupplementIndexes = <BatchReviewCard, int>{};
      if (line.supplement > 0 && !disabledLines.contains(line.lineKey)) {
        if (line.isGroup) {
          // A multi record adds its entire quantity to every participant.
          // Keep each unmatched photo's member set, rather than charging the
          // union of all faces on the group's photos for every photo.
          final byMembers = <String, List<BatchReviewCard>>{};
          for (final card in entry.cards.skip(line.existingCount)) {
            final keys = card.members.map((m) => m.key).toSet().toList()
              ..sort();
            byMembers.putIfAbsent(keys.join('+'), () => []).add(card);
          }
          for (final cards in byMembers.values) {
            final first = cards.first;
            final keys = first.members.map((m) => m.key).toSet().toList()
              ..sort();
            final index = newRecords.length;
            final supplement = BatchLedgerEntry(
              line: LedgerLine(
                memberKeys: keys,
                size: first.size,
                photoCount: cards.length,
                existingCount: 0,
                groupName: line.groupName,
              ),
              members: first.members,
              cards: cards,
            );
            newRecords.add(await _supplementRecord(
              supplement,
              occurredAt: occurredAt,
              activityName: activityName,
              venueName: venueName,
              sessionLabel: sessionLabel,
            ));
            for (final card in cards) {
              groupSupplementIndexes[card] = index;
            }
          }
        } else {
          supplementIndex = newRecords.length;
          newRecords.add(await _supplementRecord(
            entry,
            occurredAt: occurredAt,
            activityName: activityName,
            venueName: venueName,
            sessionLabel: sessionLabel,
          ));
        }
      }
      final owner = !line.isGroup && !line.isMulti && entry.members.length == 1
          ? _ownerScope(entry.members.single)
          : null;
      for (var i = 0; i < entry.cards.length; i++) {
        final card = entry.cards[i];
        int? recordId;
        int? newIndex;
        final groupSupplementIndex = groupSupplementIndexes[card];
        if (existingRecord != null &&
            (i < line.existingCount ||
                (supplementIndex == null && groupSupplementIndex == null))) {
          recordId = existingRecord.id;
        } else if (groupSupplementIndex != null) {
          newIndex = groupSupplementIndex;
        } else if (supplementIndex != null) {
          newIndex = supplementIndex;
        } else if (!line.isGroup && session?.ticket?.id != null) {
          recordId = session!.ticket!.id;
        } else {
          throw StateError(line.isGroup
              ? '${entry.label} 当天没有团切流水：请打开「补记」'
              : '${entry.label} 当天没有流水：请打开「补记」或选择一个有门票的场次');
        }
        media.add(BatchMediaInput(
          bytes: card.bytes,
          fileExtension: card.fileExtension,
          processingMode: card.processingMode,
          recordId: recordId,
          newRecordIndex: newIndex,
          owner: owner,
          capturedAt: card.source.photo.capturedAt,
          sourceHash: card.source.sourceHash,
          cropQuadJson: encodeQuad(card.quad),
        ));
        mediaCards.add(card);
      }
    }
    return BatchSavePlan(
      newRecords: newRecords,
      media: media,
      mediaCards: mediaCards,
    );
  }

  static int _sizeCount(ActivityRecordModel r, ChekiSize size, bool multi) =>
      multi ? r.effectiveMultiQuantity : BatchDayContext._countOfSize(r, size);

  static Future<ActivityRecordModel> _supplementRecord(
    BatchLedgerEntry entry, {
    required DateTime occurredAt,
    required String activityName,
    required String venueName,
    required String sessionLabel,
  }) async {
    final line = entry.line;
    final field = line.isGroup
        ? CounterCountField.groupCut
        : line.size == ChekiSize.fiveInch
            ? CounterCountField.fiveInch
            : CounterCountField.threeInch;
    if (!line.isGroup && !line.isMulti) {
      final m = entry.members.single;
      final counter = CounterModel(
        id: m.counterId,
        name: m.name,
        groupName: m.groupName,
        personId: m.personId,
        personName: m.personName,
        color: '#94A3B8',
      );
      GroupPricingModel? pricing;
      try {
        pricing = await DatabaseService.getGroupPricingByName(m.groupName);
      } catch (_) {
        pricing = null;
      }
      return ActivityRecordModel.counterAdjustment(
        counter: counter,
        occurredAt: occurredAt,
        deltas: {field: line.supplement},
        pricing: pricing,
        note: supplementNote,
        activityName: activityName,
        venueName: venueName,
        sessionLabel: sessionLabel,
      );
    }
    final record = ActivityRecordModel.multiCut(
      participants: [
        for (final m in entry.members)
          ActivityParticipant(
            memberName: m.name,
            groupName: m.groupName,
            personId: m.personId,
            personName: m.personName,
          ),
      ],
      field: field,
      occurredAt: occurredAt,
      activityName: activityName,
      venueName: venueName,
      sessionLabel: sessionLabel,
      note: supplementNote,
      quantity: line.supplement,
    );
    return line.isGroup ? record.copyWith(groupName: line.groupName) : record;
  }

  static String encodeQuad(RecordScanQuad q) => jsonEncode({
        'tlx': q.topLeftX,
        'tly': q.topLeftY,
        'trx': q.topRightX,
        'try': q.topRightY,
        'blx': q.bottomLeftX,
        'bly': q.bottomLeftY,
        'brx': q.bottomRightX,
        'bry': q.bottomRightY,
      });

  /// Saves [plan] in one transaction, then (when [learnFaces]) stores the
  /// confirmed faces as samples (source = confirmed).
  static Future<BatchSaveSummary> save(
    BatchSavePlan plan, {
    bool learnFaces = true,
  }) async {
    final result = await DatabaseService.saveBatchImport(
      newRecords: plan.newRecords,
      media: plan.media,
    );
    var learned = 0;
    if (learnFaces) {
      final samples = <FaceSampleModel>[];
      for (var i = 0; i < plan.mediaCards.length; i++) {
        for (final match in plan.mediaCards[i].confirmedFaces) {
          samples.add(FaceSampleService.sampleFromAnalysis(
            match.face,
            source: FaceSampleSource.confirmed,
            owner: match.member,
            mediaId: result.mediaIds[i],
          ));
        }
      }
      learned = await FaceSampleService.addSamples(samples);
    }
    return BatchSaveSummary(
      photos: result.mediaIds.length,
      newRecords: result.recordIds.length,
      learnedFaces: learned,
    );
  }
}
