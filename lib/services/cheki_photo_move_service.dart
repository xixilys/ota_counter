import 'dart:io';
import 'dart:typed_data';

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import 'cheki_photo_sync_service.dart';
import 'database_service.dart';
import 'face/face_recognition_rules.dart';

/// Where a 切册 photo should go: a member's activity day, optionally a
/// named record. Activity, venue and session only describe a record that
/// has to be created; an existing record keeps its own.
class PhotoMoveRequest {
  final int mediaId;
  final int counterId;
  final DateTime day;
  final int? targetRecordId;
  final String activityName;
  final String venueName;
  final String sessionLabel;

  const PhotoMoveRequest({
    required this.mediaId,
    required this.counterId,
    required this.day,
    this.targetRecordId,
    this.activityName = '',
    this.venueName = '',
    this.sessionLabel = '',
  });
}

/// What moving a photo would do, computed before anything is written so the
/// app can show it and ask, and the sync action can check it.
class PhotoMovePlan {
  final PhotoMoveRequest request;
  final ActivityRecordMediaModel media;
  final ActivityRecordModel source;
  final CounterModel counter;

  /// The member's record that day the photo would join; null when a new
  /// record has to be created.
  final ActivityRecordModel? existingTarget;

  /// The count field that moves along with the photo (source −1, target
  /// +1); null when the photo carries no count, [countSkipReason] says why.
  final CounterCountField? countField;
  final String? countSkipReason;

  /// The source record is left with no count, photo or note after the move
  /// and is removed with it.
  final bool removesEmptySource;

  /// The photo belongs to someone else after the move: its learned face
  /// samples go and are learned again for [counter].
  final bool memberChanged;

  /// The photo's camera time puts it on another day than the target's; it
  /// is cleared, otherwise the 切册 would keep showing the old day.
  final bool clearsCapturedAt;

  const PhotoMovePlan({
    required this.request,
    required this.media,
    required this.source,
    required this.counter,
    required this.existingTarget,
    required this.countField,
    required this.countSkipReason,
    required this.removesEmptySource,
    required this.memberChanged,
    required this.clearsCapturedAt,
  });

  bool get createsTarget => existingTarget == null;
  bool get movesCount => countField != null;
}

/// Result of [ChekiPhotoMoveService.apply], as reported to the user and to
/// the chat assistant.
class PhotoMoveResult {
  final MediaMoveOutcome outcome;
  final bool countMoved;
  final CounterCountField? countField;
  final String? countSkipReason;
  final bool capturedAtCleared;
  final Map<String, dynamic> faces;

  const PhotoMoveResult({
    required this.outcome,
    required this.countMoved,
    required this.countField,
    required this.countSkipReason,
    required this.capturedAtCleared,
    required this.faces,
  });

  Map<String, dynamic> toJson() => {
        'media_id': outcome.mediaId,
        'moved': true,
        'from_record_id': outcome.source.id,
        'record_id': outcome.target.id,
        'created_record': outcome.createdTarget,
        'count_moved': countMoved,
        if (countMoved)
          'count_field': DatabaseService.countColumnFor(countField!),
        if (!countMoved && countSkipReason != null)
          'count_not_moved_reason': countSkipReason,
        if (outcome.sourceRemoved) 'from_record_removed': true,
        'from_record_counts': _counts(outcome.source),
        'record_counts': _counts(outcome.target),
        'member_name': outcome.target.subjectName,
        'occurred_at': _date(outcome.target.occurredAt),
        if (capturedAtCleared) 'captured_at_cleared': true,
        'face_samples_removed': outcome.facesRemoved,
        ...faces,
      };

  static Map<String, int> _counts(ActivityRecordModel record) => {
        for (final field in CounterCountField.values)
          if (record.countForField(field) > 0)
            DatabaseService.countColumnFor(field): record.countForField(field),
      };
}

/// Moves one 切册 photo to another member or day: the shared logic of the
/// album's 「调整信息」 sheet and the chat action `move_cheki_photo`.
///
/// The target is the member's record on that activity day (the same rule
/// `attach_cheki_photos` uses: prefer a record whose activity matches),
/// otherwise a new record is created like 记一笔 does: today's group
/// pricing, date only. Moving counts reuses the ledger edit path, so the
/// member counters stay equal to the sum of their records.
class ChekiPhotoMoveService {
  ChekiPhotoMoveService._();

  /// Face learning after a move; tests replace it to avoid the face engine.
  static Future<Map<String, dynamic>> Function({
    required ActivityRecordModel record,
    required CounterModel? counter,
    required List<({int mediaId, Uint8List bytes})> photos,
  }) learnFaces = ChekiPhotoSyncService.learnFaces;

  /// Whether moving [media] off [source] moves a count, and which one.
  ///
  /// Counts follow the photo automatically, but only a count the photo
  /// stands for: a 切图 on a member's own record whose counts cover its
  /// 切图 (each archived 切图 is one counted cheki). The field is the first
  /// non-zero one in ledger order (3寸, 5寸, 无签…). Otherwise only the photo
  /// moves, and the reason is returned:
  /// * 纪念照 are not cheki;
  /// * 多人切 / 门票 records split counts per participant, not per photo;
  /// * a record with more 切图 than counts has photos that were never
  ///   counted (re-scans, extras), so taking a count would undercount it;
  /// * a 多人切 target cannot take a single member's count.
  static (CounterCountField?, String?) countToMove({
    required ActivityRecordMediaModel media,
    required ActivityRecordModel source,
    required ActivityRecordModel? target,
    required int sourceScanCount,
  }) {
    if (!media.isScan) return (null, '纪念照不计张数');
    if (!source.isCounter) {
      return (null, '原流水是${source.isMulti ? '多人切' : '门票'}，张数按人分摊，不跟照片走');
    }
    if (target != null && !target.isCounter) {
      return (null, '目标是多人切流水，张数不跟照片走');
    }
    final total = source.counterCountTotal;
    if (total <= 0) return (null, '原流水张数是 0');
    if (total < sourceScanCount) {
      return (null, '原流水 $total 张却有 $sourceScanCount 张切图，多出来的照片不计张数');
    }
    final field = CounterCountField.values
        .where((f) => source.countForField(f) > 0)
        .firstOrNull;
    if (field == null) return (null, '原流水只有自定义规格，不跟照片走');
    return (field, null);
  }

  static Future<PhotoMovePlan> plan(
    PhotoMoveRequest request, {
    List<CounterModel>? counters,
    List<ActivityRecordModel>? records,
  }) async {
    final media = (await DatabaseService.getActivityRecordMedia())
        .where((m) => m.id == request.mediaId)
        .firstOrNull;
    if (media == null) {
      throw MediaMoveException('照片 #${request.mediaId} 已不在切册里（可能已删除）');
    }
    final allCounters = counters ?? await DatabaseService.getCounters();
    final allRecords = records ?? await DatabaseService.getActivityRecords();
    final source = allRecords.where((r) => r.id == media.recordId).firstOrNull;
    if (source == null) {
      throw MediaMoveException('照片所在的流水 #${media.recordId} 已不存在');
    }
    final counter =
        allCounters.where((c) => c.id == request.counterId).firstOrNull;
    if (counter == null) {
      throw MediaMoveException('找不到要挪去的成员卡片 #${request.counterId}');
    }
    final day = dateOnly(request.day);

    ActivityRecordModel? target;
    if (request.targetRecordId != null) {
      target =
          allRecords.where((r) => r.id == request.targetRecordId).firstOrNull;
      if (target == null) {
        throw MediaMoveException('目标流水 #${request.targetRecordId} 已不存在');
      }
      if (target.type == ActivityRecordType.ticket) {
        throw MediaMoveException(
            '目标流水 #${request.targetRecordId} 是门票，切奇照片只能挂到切奇流水');
      }
    } else {
      target = findTarget(
        records: allRecords,
        counters: allCounters,
        counter: counter,
        day: day,
        activityName: request.activityName,
        excludeRecordId: source.id,
      );
    }
    if (target?.id == source.id) {
      throw MediaMoveException('照片已经在这条流水上了，没有要挪的');
    }

    final sourceMedia =
        await DatabaseService.getActivityRecordMedia(recordId: source.id);
    final (field, skip) = countToMove(
      media: media,
      source: source,
      target: target,
      sourceScanCount: sourceMedia.where((m) => m.isScan).length,
    );
    final sourceAfterTotal = source.counterCountTotal - (field == null ? 0 : 1);
    final removesEmptySource = source.isCounter &&
        sourceAfterTotal <= 0 &&
        sourceMedia.length == 1 &&
        source.note.trim().isEmpty;

    final sourceOwner = _ownerCounterId(media, source, allCounters);
    final capturedAt = media.capturedAt;
    final targetDay =
        target == null ? day : recordActivityDay(target.occurredAt);
    return PhotoMovePlan(
      request: request,
      media: media,
      source: source,
      counter: counter,
      existingTarget: target,
      countField: field,
      countSkipReason: skip,
      removesEmptySource: removesEmptySource,
      memberChanged: sourceOwner != counter.id,
      clearsCapturedAt:
          capturedAt != null && activityDayOf(capturedAt) != targetDay,
    );
  }

  /// The member's own record on [day] a moved photo joins: same rule as
  /// attaching a chat photo, limited to records whose counts can follow.
  static ActivityRecordModel? findTarget({
    required List<ActivityRecordModel> records,
    required List<CounterModel> counters,
    required CounterModel counter,
    required DateTime day,
    String activityName = '',
    int? excludeRecordId,
  }) {
    var candidates = records
        .where((r) =>
            r.id != excludeRecordId &&
            r.isCounter &&
            recordActivityDay(r.occurredAt) == dateOnly(day) &&
            resolveCounterForActivityRecord(counters, r)?.id == counter.id)
        .toList();
    final activity = _normalize(activityName);
    if (activity.isNotEmpty) {
      final named = candidates.where((r) {
        final name = _normalize(r.activityName);
        return name.isNotEmpty &&
            (name.contains(activity) || activity.contains(name));
      }).toList();
      if (named.isNotEmpty) candidates = named;
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final byTime = b.occurredAt.compareTo(a.occurredAt);
      return byTime != 0 ? byTime : (b.id ?? 0).compareTo(a.id ?? 0);
    });
    return candidates.first;
  }

  /// Carries out [plan]. [sourceTag] / [sourceActionId] mark a record
  /// created by a chat action, so replaying the action finds it instead of
  /// adding another.
  static Future<PhotoMoveResult> apply(
    PhotoMovePlan plan, {
    String? sourceTag,
    String? sourceActionId,
  }) async {
    final field = plan.countField;
    ActivityRecordModel? newTarget;
    if (plan.existingTarget == null) {
      final pricings = await DatabaseService.getGroupPricings();
      final group = plan.counter.groupName.trim();
      final pricing =
          pricings.where((p) => p.groupName.trim() == group).firstOrNull ??
              GroupPricingModel.unconfigured(group);
      newTarget = ActivityRecordModel.counterAdjustment(
        counter: plan.counter,
        occurredAt: dateOnly(plan.request.day),
        deltas: {if (field != null) field: 1},
        pricing: pricing,
        activityName: plan.request.activityName.trim(),
        venueName: plan.request.venueName.trim(),
        sessionLabel: plan.request.sessionLabel.trim(),
      );
      if (sourceTag != null && sourceActionId != null) {
        newTarget = newTarget.copyWith(
            source: sourceTag, sourceRecordId: sourceActionId);
      }
    }
    final target = plan.existingTarget;
    final owner = target != null && target.isMulti
        ? ActivityRecordMediaOwnerScope(
            personId: plan.counter.personId,
            personName: plan.counter.personName.trim().isEmpty
                ? plan.counter.name.trim()
                : plan.counter.personName.trim(),
            groupName: plan.counter.groupName,
          )
        : null;
    final outcome = await DatabaseService.moveActivityRecordMedia(
      plan.media.id!,
      targetRecordId: target?.id,
      newTarget: newTarget,
      countField: field,
      owner: owner,
      clearCapturedAt: plan.clearsCapturedAt,
      forgetFaces: plan.memberChanged,
      removeEmptySource: plan.removesEmptySource,
    );
    if (outcome == null) {
      throw MediaMoveException('照片 #${plan.media.id} 已不在切册里（可能已删除）');
    }
    var faces = const <String, dynamic>{};
    if (plan.memberChanged) {
      try {
        final bytes = await File(plan.media.path).readAsBytes();
        faces = await learnFaces(
          record: outcome.target,
          counter: plan.counter,
          photos: [(mediaId: plan.media.id!, bytes: bytes)],
        );
      } catch (_) {
        faces = {'face_samples_added': 0, 'face_failed': 1};
      }
    }
    return PhotoMoveResult(
      outcome: outcome,
      countMoved: field != null,
      countField: field,
      countSkipReason: plan.countSkipReason,
      capturedAtCleared: plan.clearsCapturedAt,
      faces: faces,
    );
  }

  static int? _ownerCounterId(ActivityRecordMediaModel media,
      ActivityRecordModel record, List<CounterModel> counters) {
    if (media.hasOwnerScope) {
      final name = _normalize(media.ownerPersonName);
      final group = _normalize(media.ownerGroupName);
      for (final counter in counters) {
        final samePerson = media.ownerPersonId != null &&
            counter.personId == media.ownerPersonId;
        final sameName = name.isNotEmpty &&
            (_normalize(counter.personName) == name ||
                _normalize(counter.name) == name);
        if ((samePerson || sameName) &&
            (group.isEmpty || _normalize(counter.groupName) == group)) {
          return counter.id;
        }
      }
      return null;
    }
    if (!record.isCounter) return null;
    return resolveCounterForActivityRecord(counters, record)?.id;
  }

  static String _normalize(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

String _date(DateTime value) => '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
