import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import 'album_orientation_service.dart';
import 'database_service.dart';
import 'face/face_enrollment_sync_service.dart'
    show FaceEnrollmentImageNotFound;
import 'face/face_recognition_rules.dart'
    show FaceMember, dateOnly, recordActivityDay;
import 'face/face_sample_service.dart';

/// Outcome of one `attach_cheki_photos` action.
///
/// [failure] with [retryable] = false is a final Chinese receipt for the
/// server; a retryable failure leaves the action pending for the next sync.
class ChekiPhotoSyncResult {
  final Map<String, dynamic>? summary;
  final String? failure;
  final bool retryable;

  const ChekiPhotoSyncResult.applied(Map<String, dynamic> this.summary)
      : failure = null,
        retryable = false;

  const ChekiPhotoSyncResult.failed(String this.failure)
      : summary = null,
        retryable = false;

  const ChekiPhotoSyncResult.retry(String this.failure)
      : summary = null,
        retryable = true;
}

/// Applies chat-sent cheki photos to a ledger record.
///
/// The photos enter the album exactly like 批量拍切 / 已核对切图: archived as
/// scan media of the record, then [DatabaseService.saveBatchImport] prepares
/// the rectified, de-glared rendition the 切册 shows.
class ChekiPhotoSyncService {
  static const mcpSource = 'mcp';

  /// Turns a stored card upright before face detection, as 批量拍切 does.
  /// Tests replace it; the album keeps the archived bytes either way.
  static Future<Uint8List> Function(Uint8List bytes) orient =
      AlbumOrientationService.orientScanBytes;

  /// [counter] is the member the action names (already resolved by the
  /// caller, null when the action names none or the card is unknown).
  /// [unsettledActionIds] are actions of this pull that have not been applied
  /// yet, so a photo can wait for its record_cheki instead of failing.
  static Future<ChekiPhotoSyncResult> apply({
    required String actionId,
    required Map<String, dynamic> payload,
    required List<CounterModel> counters,
    required CounterModel? counter,
    required Set<String> unsettledActionIds,
    required Future<Uint8List> Function(String imageId) fetchImage,
  }) async {
    final images = payload['images'] is List
        ? (payload['images'] as List).whereType<Map>().toList()
        : const <Map>[];
    if (images.isEmpty) {
      return const ChekiPhotoSyncResult.failed('照片操作里没有图片');
    }
    final memberLabel = _memberLabel(payload, counter);

    final records = await DatabaseService.getActivityRecords();
    final resolved = _resolveRecord(
      payload: payload,
      records: records,
      counters: counters,
      counter: counter,
      memberLabel: memberLabel,
      unsettledActionIds: unsettledActionIds,
    );
    if (resolved.$2 != null) return resolved.$2!;
    final record = resolved.$1!;

    final existing =
        await DatabaseService.getActivityRecordMedia(recordId: record.id);
    final knownHashes = {
      for (final media in existing)
        if (media.sourceHash.isNotEmpty) media.sourceHash,
    };
    final owner = _ownerFor(record, counter);
    final inputs = <BatchMediaInput>[];
    var duplicates = 0;
    for (var i = 0; i < images.length; i++) {
      final imageId = (images[i]['imageId'] ?? '').toString();
      if (imageId.isEmpty) {
        return ChekiPhotoSyncResult.failed('第 ${i + 1} 张照片缺少图片编号');
      }
      final Uint8List bytes;
      try {
        bytes = await fetchImage(imageId);
      } on FaceEnrollmentImageNotFound {
        return ChekiPhotoSyncResult.failed(
            '第 ${i + 1} 张照片在服务器上已过期或被清理（超过 7 天未同步），请重新发送');
      } catch (error) {
        return ChekiPhotoSyncResult.retry(
            '第 ${i + 1} 张照片下载失败，下次同步重试（$error）');
      }
      final extension = _validatedExtension(bytes);
      if (extension == null) {
        return ChekiPhotoSyncResult.failed(
            '第 ${i + 1} 张不是可读取的 JPEG 或 PNG 图片（或超过 2400 万像素）');
      }
      final hash = sha1.convert(bytes).toString();
      if (!knownHashes.add(hash)) {
        duplicates++;
        continue;
      }
      inputs.add(BatchMediaInput(
        bytes: bytes,
        fileExtension: extension,
        processingMode: ActivityRecordMediaProcessingMode.none,
        recordId: record.id,
        owner: owner,
        sourceHash: hash,
      ));
    }
    Map<String, dynamic> faces = const {};
    if (inputs.isNotEmpty) {
      final saved = await DatabaseService.saveBatchImport(
          newRecords: const [], media: inputs);
      faces = await _learnFaces(
        record: record,
        counter: counter ?? resolveCounterForActivityRecord(counters, record),
        photos: [
          for (var i = 0; i < inputs.length; i++)
            (
              mediaId: saved.mediaIds[i],
              bytes: Uint8List.fromList(inputs[i].bytes),
            ),
        ],
      );
    }
    return ChekiPhotoSyncResult.applied({
      'record_id': record.id,
      'photos_saved': inputs.length,
      'duplicates': duplicates,
      'member_name': record.subjectName,
      'occurred_at': _date(record.occurredAt),
      ...faces,
    });
  }

  /// The photos are already saved; face learning only adds samples and never
  /// fails the action. A 团切, or a 多切 without a named member, has no single
  /// owner, so it teaches nothing.
  static Future<Map<String, dynamic>> _learnFaces({
    required ActivityRecordModel record,
    required CounterModel? counter,
    required List<({int mediaId, Uint8List bytes})> photos,
  }) async {
    if (counter == null ||
        (record.isMulti &&
            record.multiCountField == CounterCountField.groupCut)) {
      return {'face_samples_added': 0, 'face_skipped_no_owner': photos.length};
    }
    try {
      final upright = <({int mediaId, Uint8List bytes})>[];
      for (final photo in photos) {
        Uint8List bytes;
        try {
          bytes = await orient(photo.bytes);
        } catch (_) {
          bytes = photo.bytes;
        }
        upright.add((mediaId: photo.mediaId, bytes: bytes));
      }
      final result = await FaceSampleService.learnFromAttached(
        upright,
        owner: FaceMember(
          counterId: counter.id,
          personId: counter.personId,
          name: counter.name,
          personName: counter.personName,
          groupName: counter.groupName,
        ),
      );
      return result.toJson();
    } catch (_) {
      return {'face_samples_added': 0, 'face_failed': photos.length};
    }
  }

  static (ActivityRecordModel?, ChekiPhotoSyncResult?) _resolveRecord({
    required Map<String, dynamic> payload,
    required List<ActivityRecordModel> records,
    required List<CounterModel> counters,
    required CounterModel? counter,
    required String memberLabel,
    required Set<String> unsettledActionIds,
  }) {
    final recordId = _readInt(payload['record_id']);
    if (recordId != null) {
      final record = records.where((r) => r.id == recordId).firstOrNull;
      if (record == null) {
        return (null, ChekiPhotoSyncResult.failed('流水 #$recordId 已不存在，照片未挂'));
      }
      if (record.type == ActivityRecordType.ticket) {
        return (
          null,
          ChekiPhotoSyncResult.failed('流水 #$recordId 是门票，切奇照片只能挂到切奇流水')
        );
      }
      return (record, null);
    }

    ActivityRecordModel? createdBy(String actionId) => records
        .where((r) => r.source == mcpSource && r.sourceRecordId == actionId)
        .firstOrNull;

    final linked = (payload['record_action_id'] ?? '').toString().trim();
    if (linked.isNotEmpty) {
      final record = createdBy(linked);
      if (record != null) return (record, null);
      if (unsettledActionIds.contains(linked)) {
        return (null, const ChekiPhotoSyncResult.retry('关联的计数还没记上，下次同步再挂照片'));
      }
      return (
        null,
        const ChekiPhotoSyncResult.failed('关联的 record_cheki 没有生成流水（可能已失败），照片未挂')
      );
    }

    final hint = (payload['record_action_hint'] ?? '').toString().trim();
    final hinted = hint.isEmpty ? null : createdBy(hint);
    final occurred =
        DateTime.tryParse((payload['occurred_at'] ?? '').toString().trim());
    if (occurred == null) {
      return (null, const ChekiPhotoSyncResult.failed('照片操作缺少拍切日期'));
    }
    final day = dateOnly(occurred);
    if (counter == null) {
      if (hinted != null) return (hinted, null);
      return (
        null,
        ChekiPhotoSyncResult.failed('本地找不到成员「$memberLabel」，请先在 App 里建卡，照片未挂')
      );
    }
    var candidates = records
        .where((r) =>
            r.type != ActivityRecordType.ticket &&
            recordActivityDay(r.occurredAt) == day &&
            _belongsTo(r, counter, counters))
        .toList();
    final activity = _normalize((payload['activity_name'] ?? '').toString());
    if (activity.isNotEmpty) {
      final named = candidates.where((r) {
        final name = _normalize(r.activityName);
        return name.isNotEmpty &&
            (name.contains(activity) || activity.contains(name));
      }).toList();
      if (named.isNotEmpty) candidates = named;
    }
    if (candidates.isNotEmpty) {
      if (hinted != null && candidates.any((r) => r.id == hinted.id)) {
        return (hinted, null);
      }
      candidates.sort((a, b) {
        final byTime = b.occurredAt.compareTo(a.occurredAt);
        return byTime != 0 ? byTime : (b.id ?? 0).compareTo(a.id ?? 0);
      });
      return (candidates.first, null);
    }
    if (hinted != null) return (hinted, null);
    if (hint.isNotEmpty && unsettledActionIds.contains(hint)) {
      return (null, const ChekiPhotoSyncResult.retry('同一天的计数还没记上，下次同步再挂照片'));
    }
    return (
      null,
      ChekiPhotoSyncResult.failed('找不到「$memberLabel」在 ${_date(day)} 的切奇流水，照片未挂。'
          '请先用 record_cheki 记一笔（可直接带 images），或用 record_id 指定流水')
    );
  }

  static bool _belongsTo(ActivityRecordModel record, CounterModel counter,
      List<CounterModel> counters) {
    if (record.isMulti && record.effectiveParticipants.isNotEmpty) {
      return record.effectiveParticipants.any((participant) =>
          DatabaseService.resolveCounterForParticipant(counters, participant)
              ?.id ==
          counter.id);
    }
    return resolveCounterForActivityRecord(counters, record)?.id == counter.id;
  }

  /// A photo attached to a 多切 record names whose photo it is; on a member's
  /// own record the record already does.
  static ActivityRecordMediaOwnerScope? _ownerFor(
      ActivityRecordModel record, CounterModel? counter) {
    if (counter == null || !record.isMulti) return null;
    final personName = counter.personName.trim().isEmpty
        ? counter.name.trim()
        : counter.personName.trim();
    return ActivityRecordMediaOwnerScope(
      personId: counter.personId,
      personName: personName,
      groupName: counter.groupName,
    );
  }

  static String? _validatedExtension(Uint8List bytes) {
    final img.Decoder decoder;
    final String extension;
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      decoder = img.JpegDecoder();
      extension = '.jpg';
    } else if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      decoder = img.PngDecoder();
      extension = '.png';
    } else {
      return null;
    }
    try {
      final info = decoder.startDecode(bytes);
      if (info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width * info.height > 24000000) {
        return null;
      }
    } catch (_) {
      return null;
    }
    return extension;
  }

  static String _memberLabel(
      Map<String, dynamic> payload, CounterModel? counter) {
    if (counter != null) return counter.name;
    final name =
        (payload['member_name'] ?? payload['name'] ?? '').toString().trim();
    return name.isEmpty ? '未知成员' : name;
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String _normalize(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s·•・_\-~/\\()\[\]{}（）【】「」『』]+'), '');

  static String _date(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
