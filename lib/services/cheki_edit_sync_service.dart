import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import 'cheki_photo_move_service.dart';
import 'cheki_photo_sync_service.dart';
import 'database_service.dart';
import 'face/face_enrollment_sync_service.dart'
    show FaceEnrollmentImageNotFound;

/// Applies chat-queued corrections to the 切册 and the ledger:
/// `delete_cheki_photo`, `replace_cheki_photo`, `edit_record` and
/// `move_cheki_photo`.
///
/// Every action is safe to apply twice (a lost receipt replays it), and
/// none overwrites something changed on the phone since the assistant
/// looked: the action carries what the assistant saw, and a mismatch fails
/// with a Chinese reason instead.
class ChekiEditSyncService {
  ChekiEditSyncService._();

  /// Ledger fields `edit_record` may change, as stored on the record.
  static const countFields = [
    'three_inch_count',
    'five_inch_count',
    'unsigned_three_inch_count',
    'unsigned_five_inch_count',
    'group_cut_count',
    'three_inch_shukudai_count',
    'five_inch_shukudai_count',
  ];
  static const textFields = [
    'note',
    'activity_name',
    'venue_name',
    'session_label',
  ];

  static Future<ChekiPhotoSyncResult> deletePhoto(
      Map<String, dynamic> payload) async {
    final mediaId = _readInt(payload['media_id']);
    if (mediaId == null) {
      return const ChekiPhotoSyncResult.failed('删除照片缺少照片编号 media_id');
    }
    final media = (await DatabaseService.getActivityRecordMedia())
        .where((m) => m.id == mediaId)
        .firstOrNull;
    if (media == null) {
      // Already gone (deleted on the phone, or this action replayed).
      return ChekiPhotoSyncResult.applied(
          {'media_id': mediaId, 'deleted': false, 'already_gone': true});
    }
    final expected = (payload['sha1'] ?? '').toString().trim();
    if (expected.isNotEmpty &&
        media.sourceHash.isNotEmpty &&
        media.sourceHash != expected) {
      return ChekiPhotoSyncResult.failed(
          '照片 #$mediaId 在手机上已被换过（和你看到的不是同一张），未删除。请重新查询后再操作');
    }
    await DatabaseService.deleteActivityRecordMedia(mediaId);
    return ChekiPhotoSyncResult.applied({
      'media_id': mediaId,
      'record_id': media.recordId,
      'deleted': true,
    });
  }

  static Future<ChekiPhotoSyncResult> replacePhoto(
    Map<String, dynamic> payload, {
    required List<CounterModel> counters,
    required Future<Uint8List> Function(String imageId) fetchImage,
  }) async {
    final mediaId = _readInt(payload['media_id']);
    final images = payload['images'] is List
        ? (payload['images'] as List).whereType<Map>().toList()
        : const <Map>[];
    final imageId =
        images.isEmpty ? '' : (images.first['imageId'] ?? '').toString();
    if (mediaId == null || imageId.isEmpty) {
      return const ChekiPhotoSyncResult.failed('替换照片缺少照片编号或新图片');
    }
    final media = (await DatabaseService.getActivityRecordMedia())
        .where((m) => m.id == mediaId)
        .firstOrNull;
    if (media == null) {
      return ChekiPhotoSyncResult.failed('照片 #$mediaId 已不在切册里（可能已删除），未替换');
    }
    final Uint8List bytes;
    try {
      bytes = await fetchImage(imageId);
    } on FaceEnrollmentImageNotFound {
      return const ChekiPhotoSyncResult.failed(
          '新照片在服务器上已过期或被清理（超过 7 天未同步），请重新发送');
    } catch (error) {
      return ChekiPhotoSyncResult.retry('新照片下载失败，下次同步重试（$error）');
    }
    final extension = ChekiPhotoSyncService.validatedExtension(bytes);
    if (extension == null) {
      return const ChekiPhotoSyncResult.failed(
          '新照片不是可读取的 JPEG 或 PNG 图片（或超过 2400 万像素）');
    }
    final hash = sha1.convert(bytes).toString();
    if (media.sourceHash == hash) {
      return ChekiPhotoSyncResult.applied(
          {'media_id': mediaId, 'record_id': media.recordId, 'replaced': false});
    }
    final expected = (payload['sha1'] ?? '').toString().trim();
    if (expected.isNotEmpty &&
        media.sourceHash.isNotEmpty &&
        media.sourceHash != expected) {
      return ChekiPhotoSyncResult.failed(
          '照片 #$mediaId 在手机上已被换过（和你看到的不是同一张），未替换。请重新查询后再操作');
    }
    final replaced = await DatabaseService.replaceActivityRecordMedia(
      mediaId,
      bytes: bytes,
      fileExtension: extension,
      sourceHash: hash,
    );
    if (!replaced) {
      return ChekiPhotoSyncResult.failed('照片 #$mediaId 已不在切册里（可能已删除），未替换');
    }
    final record = (await DatabaseService.getActivityRecords())
        .where((r) => r.id == media.recordId)
        .firstOrNull;
    final faces = record == null
        ? const <String, dynamic>{}
        : await ChekiPhotoSyncService.learnFaces(
            record: record,
            counter: resolveCounterForActivityRecord(counters, record),
            photos: [(mediaId: mediaId, bytes: bytes)],
          );
    return ChekiPhotoSyncResult.applied({
      'media_id': mediaId,
      'record_id': media.recordId,
      'replaced': true,
      ...faces,
    });
  }

  static Future<ChekiPhotoSyncResult> editRecord(
      Map<String, dynamic> payload) async {
    final recordId = _readInt(payload['record_id']);
    final changes = payload['changes'] is Map
        ? Map<String, dynamic>.from(payload['changes'] as Map)
        : const <String, dynamic>{};
    final expected = payload['expected'] is Map
        ? Map<String, dynamic>.from(payload['expected'] as Map)
        : const <String, dynamic>{};
    if (recordId == null || changes.isEmpty) {
      return const ChekiPhotoSyncResult.failed('修改流水缺少 record_id 或要改的内容');
    }
    final unknown = changes.keys
        .where((k) => !countFields.contains(k) && !textFields.contains(k));
    if (unknown.isNotEmpty) {
      return ChekiPhotoSyncResult.failed('不支持修改这些字段：${unknown.join('、')}');
    }
    final record = (await DatabaseService.getActivityRecords())
        .where((r) => r.id == recordId)
        .firstOrNull;
    if (record == null) {
      return ChekiPhotoSyncResult.failed('流水 #$recordId 已不存在，未修改');
    }
    final hasCounts = changes.keys.any(countFields.contains);
    if (hasCounts &&
        (record.type == ActivityRecordType.ticket || record.isMulti)) {
      return ChekiPhotoSyncResult.failed(
          '流水 #$recordId 是${record.type == ActivityRecordType.ticket ? '门票' : '多人切'}，'
          '这里只能改单人切奇的张数；备注和活动信息可以改');
    }
    final current = record.toMap();
    final before = {for (final key in changes.keys) key: current[key]};
    if (changes.entries.every((e) => _same(current[e.key], e.value))) {
      // Already as requested (replayed action, or changed by hand).
      return ChekiPhotoSyncResult.applied(
          {'record_id': recordId, 'changed': false, 'before': before});
    }
    final drift = [
      for (final e in expected.entries)
        if (!_same(current[e.key], e.value))
          '${e.key} 现在是 ${current[e.key] ?? '空'}，你看到的是 ${e.value ?? '空'}',
    ];
    if (drift.isNotEmpty) {
      return ChekiPhotoSyncResult.failed(
          '流水 #$recordId 在手机上已改过，未覆盖：${drift.join('；')}。请重新查询后再改');
    }
    for (final key in countFields) {
      final value = changes[key];
      if (value != null && (value is! int || value < 0)) {
        return ChekiPhotoSyncResult.failed('$key 必须是不小于 0 的整数');
      }
    }
    final updated = ActivityRecordModel.fromMap({...current, ...changes});
    await DatabaseService.updateActivityRecordWithCounterImpact(
        recordId, updated);
    return ChekiPhotoSyncResult.applied({
      'record_id': recordId,
      'changed': true,
      'before': before,
      'after': {for (final key in changes.keys) key: changes[key]},
    });
  }

  /// Moves a photo to another member or day, through the same
  /// [ChekiPhotoMoveService] as the album's 「调整信息」 sheet. [counter] is
  /// the target member resolved from the payload; a record this action has
  /// to create is tagged with [actionId], so a replay finds the photo there
  /// and reports it as already done.
  static Future<ChekiPhotoSyncResult> movePhoto(
    Map<String, dynamic> payload, {
    required String actionId,
    required List<CounterModel> counters,
    required CounterModel? counter,
  }) async {
    final mediaId = _readInt(payload['media_id']);
    final fromRecordId = _readInt(payload['record_id']);
    final targetRecordId = _readInt(payload['target_record_id']);
    final date = DateTime.tryParse((payload['date'] ?? '').toString().trim());
    if (mediaId == null || fromRecordId == null) {
      return const ChekiPhotoSyncResult.failed('挪照片缺少照片编号 media_id 或原流水 record_id');
    }
    final media = (await DatabaseService.getActivityRecordMedia())
        .where((m) => m.id == mediaId)
        .firstOrNull;
    if (media == null) {
      return ChekiPhotoSyncResult.failed('照片 #$mediaId 已不在切册里（可能已删除），未挪动');
    }
    final records = await DatabaseService.getActivityRecords();
    if (media.recordId != fromRecordId) {
      final current = records.where((r) => r.id == media.recordId).firstOrNull;
      final mine = current != null &&
          (current.id == targetRecordId ||
              (current.source == ChekiPhotoSyncService.mcpSource &&
                  current.sourceRecordId == actionId));
      if (mine) {
        // Replayed: this action already moved it.
        return ChekiPhotoSyncResult.applied({
          'media_id': mediaId,
          'moved': false,
          'already_done': true,
          'record_id': media.recordId,
        });
      }
      return ChekiPhotoSyncResult.failed(
          '照片 #$mediaId 在手机上已挪到流水 #${media.recordId}（你看到的是 #$fromRecordId），'
          '未挪动。请重新查询后再操作');
    }
    final expected = (payload['sha1'] ?? '').toString().trim();
    if (expected.isNotEmpty &&
        media.sourceHash.isNotEmpty &&
        media.sourceHash != expected) {
      return ChekiPhotoSyncResult.failed(
          '照片 #$mediaId 在手机上已被换过（和你看到的不是同一张），未挪动。请重新查询后再操作');
    }
    CounterModel? member = counter;
    if (targetRecordId != null && member == null) {
      final target = records.where((r) => r.id == targetRecordId).firstOrNull;
      if (target != null) {
        member = resolveCounterForActivityRecord(counters, target);
      }
    }
    if (member?.id == null) {
      final label = (payload['member_name'] ?? '').toString().trim();
      return ChekiPhotoSyncResult.failed(
          '本地找不到成员「${label.isEmpty ? '?' : label}」，请先在 App 里建卡，照片未挪动');
    }
    if (date == null && targetRecordId == null) {
      return const ChekiPhotoSyncResult.failed('挪照片缺少目标日期 date');
    }
    final targetRecord = targetRecordId == null
        ? null
        : records.where((r) => r.id == targetRecordId).firstOrNull;
    try {
      final plan = await ChekiPhotoMoveService.plan(
        PhotoMoveRequest(
          mediaId: mediaId,
          counterId: member!.id!,
          day: date ?? targetRecord?.occurredAt ?? DateTime.now(),
          targetRecordId: targetRecordId,
          activityName: (payload['activity_name'] ?? '').toString(),
          venueName: (payload['venue_name'] ?? '').toString(),
          sessionLabel: (payload['session_label'] ?? '').toString(),
        ),
        counters: counters,
        records: records,
      );
      final result = await ChekiPhotoMoveService.apply(
        plan,
        sourceTag: ChekiPhotoSyncService.mcpSource,
        sourceActionId: actionId,
      );
      return ChekiPhotoSyncResult.applied(result.toJson());
    } on MediaMoveException catch (error) {
      return ChekiPhotoSyncResult.failed('${error.message}，照片未挪动');
    }
  }

  static bool _same(Object? a, Object? b) {
    if (a is num && b is num) return a == b;
    return (a ?? '').toString() == (b ?? '').toString();
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
