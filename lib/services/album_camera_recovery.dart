import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/activity_record_media_model.dart';
import '../models/activity_record_model.dart';
import 'album_card_matcher.dart';
import 'album_camera_access.dart';
import 'album_clarity_service.dart';
import 'face/face_recognition_rules.dart';
import 'record_scan_service.dart';

/// Recover clipped archives from a different, identifiable observation of the
/// same signed print. Camera roll stays on device; the ledger is never written.
class AlbumCameraRecovery {
  static const _channel = MethodChannel('ota_counter/album_camera_sources');
  static final _queue = <DateTime, Map<String, ActivityRecordMediaModel>>{};
  static bool _active = false;
  static final progress = ValueNotifier<String?>(null);

  /// A hand-framed attachment is still a scan; a matched camera rendition
  /// can repair its geometry without changing the archived framing.
  static DateTime? recoveryDay(
      ActivityRecordMediaModel media, DateTime? recordDay) {
    if (!media.isScan ||
        media.path.isEmpty ||
        media.cropQuadJson.contains('"_checked_card_id"')) {
      return null;
    }
    return media.capturedAt == null
        ? recordDay
        : activityDayOf(media.capturedAt!);
  }

  static void schedule(
      List<ActivityRecordMediaModel> media, List<ActivityRecordModel> records) {
    if (!Platform.isAndroid) return;
    final dates = {
      for (final r in records) r.id: recordActivityDay(r.occurredAt)
    };
    for (final m in media) {
      final day = recoveryDay(m, dates[m.recordId]);
      if (day == null) continue;
      (_queue[day] ??= {})[m.path] = m;
    }
    if (!_active) unawaited(_drain());
  }

  static Future<void> _drain() async {
    _active = true;
    try {
      if (_queue.isEmpty) return;
      if (await AlbumCameraAccess.check() != AlbumCameraAccessStatus.full) {
        _queue.clear();
        return;
      }
      while (_queue.isNotEmpty) {
        // Process recent activity groups first; do not mix cards between days.
        final day = _queue.keys.reduce((a, b) => a.isAfter(b) ? a : b);
        final rows = _queue.remove(day)!;
        try {
          await recoverDay(day, rows.values);
        } catch (error) {
          debugPrint('切册原拍重扫未完成：$error');
        }
      }
    } on PlatformException catch (error) {
      debugPrint('切册无法读取相机原拍：$error');
    } finally {
      _active = false;
      progress.value = null;
    }
  }

  static Future<void> recoverDay(
    DateTime day,
    Iterable<ActivityRecordMediaModel> rows, {
    Future<void> Function(String, FileStat, Uint8List) store =
        AlbumPhotoFiles.saveCameraScan,
  }) async {
    final pending = <String, (ActivityRecordMediaModel, FileStat)>{};
    for (final row in rows) {
      final stat = await File(row.path).stat();
      if (stat.type == FileSystemEntityType.file) {
        pending[row.path] = (row, stat);
      }
    }
    if (pending.isEmpty) return;
    final start = DateTime(day.year, day.month, day.day, 6);
    final end = DateTime(day.year, day.month, day.day + 1, 6);
    Future<List<Map<String, dynamic>>> cameraRoll() async {
      final raw = await _channel.invokeListMethod<Object?>('list', {
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
      });
      return [
        for (final row in raw ?? []) Map<String, dynamic>.from(row as Map)
      ]..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    }

    String version(List<Map<String, dynamic>> roll) => jsonEncode([
          for (final s in roll) [s['path'], s['size'], s['modified']],
        ]);
    final sources = await cameraRoll();
    if (sources.isEmpty) return;
    final folder = p.dirname(pending.keys.first);
    final journal = File(p.join(folder, '.album-camera-v1', 'journal',
        '${day.year}-${day.month}-${day.day}.json'));
    final inventory = version(sources);
    final previous = await journal.exists()
        ? jsonDecode(await journal.readAsString()) as Map
        : const {};
    final sameInventory = previous['inventory'] == inventory;
    final oldChoices =
        Map<String, String?>.from(previous['choices'] as Map? ?? {});
    final choices = sameInventory ? Map.of(oldChoices) : <String, String?>{};
    String stamp(String path) {
      final stat = pending[path]!.$2;
      return '${p.basename(path)}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    }

    final targets = <String>[];
    for (final path in pending.keys) {
      final key = stamp(path);
      if (choices.containsKey(key) &&
          (choices[key] == null || await AlbumPhotoFiles.hasCameraScan(path))) {
        continue;
      }
      targets.add(path);
    }
    if (targets.isEmpty) return;

    // Stage complete prints in app-private cache, not in the camera roll.
    // Completed camera frames can be reused if Android suspends the process.
    final scratch = Directory(p.join((await getTemporaryDirectory()).path,
        'album-camera-scan-v1', p.basenameWithoutExtension(journal.path)));
    await scratch.create(recursive: true);
    final inventoryFile = File(p.join(scratch.path, 'inventory.json'));
    if (!await inventoryFile.exists() ||
        await inventoryFile.readAsString() != inventory) {
      await scratch.delete(recursive: true);
      await scratch.create(recursive: true);
      await inventoryFile.writeAsString(inventory, flush: true);
    }
    final candidates = <String>[];
    final origins = <String>[];
    var complete = true;
    final caption = '${day.month} 月 ${day.day} 日';
    for (final (index, source) in sources.indexed) {
      final path = source['path'] as String;
      final memo = File(p.join(scratch.path, '$index.json'));
      progress.value = '正在校正 $caption 的切图 · 原拍 ${index + 1}/${sources.length}';
      try {
        List<String>? frame;
        if (await memo.exists()) {
          final saved =
              (jsonDecode(await memo.readAsString()) as List).cast<String>();
          if (saved.every((f) => File(p.join(scratch.path, f)).existsSync())) {
            frame = saved;
          }
        }
        if (frame == null) {
          final scan =
              await RecordScanService.createMultiScan(sourceFile: File(path));
          frame = [];
          for (final (i, card) in scan.cards.indexed) {
            if (card.sizeClass == RecordScanCardSize.uncertain) continue;
            final name = '$index-$i.jpg';
            await File(p.join(scratch.path, name)).writeAsBytes(card.bytes);
            frame.add(name);
          }
          final temp = File('${memo.path}.tmp');
          await temp.writeAsString(jsonEncode(frame));
          await temp.rename(memo.path);
        }
        for (final name in frame) {
          candidates.add(p.join(scratch.path, name));
          origins.add(jsonEncode([
            path,
            source['modified'],
            source['size'],
            name.split('-').last
          ]));
        }
      } on FormatException {
        // Unsupported/damaged camera file has no usable pixels.
        continue;
      } on FileSystemException catch (error) {
        complete = false;
        debugPrint('切册原拍读取失败：$error');
      }
    }
    // An unread competitor can change the identity decision.
    if (!complete) return;
    progress.value = '正在核对 $caption 的 ${targets.length} 张切图';
    final matches = await recoverAlbumCardFiles(targets, candidates);
    // Photos or permissions may change during a long on-device scan.
    if (version(await cameraRoll()) != inventory) {
      (_queue[day] ??= {})
          .addEntries(pending.entries.map((e) => MapEntry(e.key, e.value.$1)));
      return;
    }
    for (final (i, match) in matches.indexed) {
      final target = targets[i];
      if (match == null) {
        await AlbumPhotoFiles.withdrawCameraScan(target, pending[target]!.$2);
        choices[stamp(target)] = null;
        continue;
      }
      final origin = switch (match) {
        AlbumCardRescan(:final candidateIndex) => origins[candidateIndex],
        AlbumCardReprojection() => '原件像素按原拍纸框校正',
      };
      if (match is AlbumCardRescan &&
          oldChoices[stamp(target)] == origin &&
          await AlbumPhotoFiles.hasCameraScan(target)) {
        choices[stamp(target)] = origin;
        continue;
      }
      try {
        final bytes = switch (match) {
          AlbumCardRescan(:final candidateIndex) =>
            await File(candidates[candidateIndex]).readAsBytes(),
          AlbumCardReprojection(:final pngBytes) => pngBytes,
        };
        await store(target, pending[target]!.$2, bytes);
        choices[stamp(target)] = origin;
        debugPrint('切册原拍重扫：附件 ${pending[target]!.$1.id} ← $origin');
      } catch (error) {
        complete = false;
        debugPrint('切册原拍成品暂不可用：$error');
      }
    }
    if (complete) {
      await journal.parent.create(recursive: true);
      final tmp = File('${journal.path}.tmp');
      await tmp.writeAsString(
          jsonEncode({'inventory': inventory, 'choices': choices}));
      await tmp.rename(journal.path);
      await scratch.delete(recursive: true);
    }
  }
}
