import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../models/ticket_type_model.dart';
import 'cheki_edit_sync_service.dart';
import 'cheki_photo_sync_service.dart';
import 'database_service.dart';
import 'merch_service.dart';
import 'ticket_pricing_service.dart';
import 'face/face_enrollment_sync_service.dart';

class SyncSettings {
  const SyncSettings({
    required this.baseUrl,
    required this.token,
    required this.deviceId,
    required this.autoSync,
    required this.lastSyncAt,
  });

  final String baseUrl;
  final String token;
  final String deviceId;
  final bool autoSync;
  final String lastSyncAt;

  bool get isConfigured => baseUrl.trim().isNotEmpty && token.trim().isNotEmpty;

  String get normalizedBaseUrl {
    var value = baseUrl.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  SyncSettings copyWith({
    String? baseUrl,
    String? token,
    String? deviceId,
    bool? autoSync,
    String? lastSyncAt,
  }) {
    return SyncSettings(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      deviceId: deviceId ?? this.deviceId,
      autoSync: autoSync ?? this.autoSync,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }
}

class SyncException implements Exception {
  SyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

class SyncActionFailure {
  final String actionId;
  final String message;

  const SyncActionFailure({required this.actionId, required this.message});
}

class SyncApplyResult {
  final int applied;
  final int skipped;
  final List<SyncActionFailure> failures;

  const SyncApplyResult({
    required this.applied,
    required this.skipped,
    this.failures = const [],
  });

  bool get hasFailures => failures.isNotEmpty;
}

class SyncRunResult {
  final int pulled;
  final int applied;
  final int pending;
  final int? rev;
  final List<SyncActionFailure> failures;

  const SyncRunResult({
    required this.pulled,
    required this.applied,
    required this.pending,
    required this.rev,
    this.failures = const [],
  });

  bool get hasFailures => failures.isNotEmpty;
}

class SyncService {
  static const String _baseUrlKey = 'mcp_sync_base_url';
  static const String _tokenKey = 'mcp_sync_token';
  static const String _deviceIdKey = 'mcp_sync_device_id';
  /// 「自动同步」: on open, on return to the foreground and every
  /// [SyncScheduler] tick while in the foreground. A new key on purpose: the
  /// old `mcp_sync_auto` only meant "sync once at startup" and was off by
  /// default, which left chat-queued actions waiting for a manual sync.
  static const String _autoSyncKey = 'mcp_sync_auto_v2';
  static const String _lastSyncKey = 'mcp_sync_last_at';
  static const String mcpSource = 'mcp';

  /// Server gate: v1.6.0 apps never receive `enroll_face` pending actions.
  static const String capabilitiesHeader = 'x-ota-capabilities';
  static const String faceEnrollmentCapability = 'face-enroll-v1';

  /// Server gate: apps without it never receive `attach_cheki_photos`.
  static const String chekiPhotoCapability = 'cheki-photo-v1';
  static const String chekiPhotoActionKind = 'attach_cheki_photos';
  /// Server gate for the 切册 / ledger corrections below.
  static const String chekiEditCapability = 'cheki-edit-v1';
  static const String deletePhotoActionKind = 'delete_cheki_photo';
  static const String replacePhotoActionKind = 'replace_cheki_photo';
  static const String editRecordActionKind = 'edit_record';
  static const String capabilities =
      '$faceEnrollmentCapability,$chekiPhotoCapability,$chekiEditCapability';

  static Future<SyncSettings> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey) ?? '';
    if (deviceId.trim().isEmpty) {
      deviceId = _newDeviceId();
      await prefs.setString(_deviceIdKey, deviceId);
    }
    return SyncSettings(
      baseUrl: prefs.getString(_baseUrlKey) ?? '',
      token: prefs.getString(_tokenKey) ?? '',
      deviceId: deviceId,
      autoSync: prefs.getBool(_autoSyncKey) ?? true,
      lastSyncAt: prefs.getString(_lastSyncKey) ?? '',
    );
  }

  static Future<SyncSettings> saveSettings(SyncSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, settings.baseUrl.trim());
    await prefs.setString(_tokenKey, settings.token.trim());
    await prefs.setString(_deviceIdKey, settings.deviceId);
    await prefs.setBool(_autoSyncKey, settings.autoSync);
    if (settings.lastSyncAt.isNotEmpty) {
      await prefs.setString(_lastSyncKey, settings.lastSyncAt);
    }
    return loadSettings();
  }

  static Future<void> markSynced([DateTime? at]) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _lastSyncKey,
      (at ?? DateTime.now()).toIso8601String(),
    );
  }

  static Future<Map<String, dynamic>> testConnection(
    SyncSettings settings,
  ) async {
    _requireConfigured(settings);
    return _request(settings, 'GET', '/api/v1/status');
  }

  /// Syncs one at a time: the automatic and the manual sync must never apply
  /// the same pulled actions concurrently.
  static Future<void> _tail = Future<void>.value();
  static int _running = 0;

  /// Whether a sync is running or waiting for one.
  static bool get isSyncing => _running > 0;

  static Future<T> _exclusive<T>(Future<T> Function() task) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    _running++;
    return previous.then((_) => task()).whenComplete(() {
      _running--;
      done.complete();
    });
  }

  static Future<SyncRunResult> syncNow(SyncSettings settings) {
    _requireConfigured(settings);
    return _exclusive(() async {
      final pulled = await pullActions(settings);
      final apply = await _applyActions(settings, pulled);
      final push = await pushSnapshot(settings);
      await markSynced();
      return SyncRunResult(
        pulled: pulled.length,
        applied: apply.applied,
        pending: _readInt(push['pending_actions']),
        rev: _readNullableInt(push['rev']),
        failures: apply.failures,
      );
    });
  }

  /// The cheap periodic check: one GET of pending actions. Only when there
  /// are some are they applied and a fresh snapshot uploaded. Returns null
  /// when nothing was pending.
  static Future<SyncRunResult?> syncIfPending(SyncSettings settings) {
    _requireConfigured(settings);
    return _exclusive(() async {
      final pulled = await pullActions(settings);
      if (pulled.isEmpty) return null;
      final apply = await _applyActions(settings, pulled);
      final push = await pushSnapshot(settings);
      await markSynced();
      return SyncRunResult(
        pulled: pulled.length,
        applied: apply.applied,
        pending: _readInt(push['pending_actions']),
        rev: _readNullableInt(push['rev']),
        failures: apply.failures,
      );
    });
  }

  static Future<Map<String, dynamic>> pushSnapshot(
    SyncSettings settings,
  ) async {
    _requireConfigured(settings);
    final snapshot = await buildSnapshot(settings);
    final result = await _request(
      settings,
      'POST',
      '/api/v1/snapshot',
      body: {
        'device_id': settings.deviceId,
        'snapshot': snapshot,
      },
    );
    await markSynced();
    return result;
  }

  static Future<List<Map<String, dynamic>>> pullActions(
    SyncSettings settings,
  ) async {
    _requireConfigured(settings);
    final response = await _request(
      settings,
      'GET',
      '/api/v1/actions?status=pending&limit=100',
    );
    final actions = response['actions'];
    if (actions is! List) {
      return const [];
    }
    return actions
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  static Future<SyncApplyResult> applyActions(
    SyncSettings settings,
    List<Map<String, dynamic>> actions,
  ) =>
      _exclusive(() => _applyActions(settings, actions));

  static Future<SyncApplyResult> _applyActions(
    SyncSettings settings,
    List<Map<String, dynamic>> actions,
  ) async {
    if (actions.isEmpty) {
      return const SyncApplyResult(applied: 0, skipped: 0);
    }
    final existingIds = await DatabaseService.getActivityRecordSourceIds(
      mcpSource,
    );
    final counters = await DatabaseService.getCounters();
    final pricings = await DatabaseService.getGroupPricings();
    final pricingByGroup = {
      for (final pricing in pricings) pricing.groupName.trim(): pricing,
    };
    final appliedIds = <String>[];
    final failures = <SyncActionFailure>[];
    final actionFailures = <String, String>{};
    final enrollmentResults = <String, Map<String, dynamic>>{};
    // Tried but kept pending for a later sync; the server records why.
    final deferred = <String, String>{};
    var skipped = 0;
    // Pulled actions that have not been applied: a photo action can wait for
    // its record_cheki of the same pull instead of failing.
    Set<String> unsettled() => {
          for (final action in actions)
            if (!appliedIds.contains((action['id'] ?? '').toString().trim()))
              (action['id'] ?? '').toString().trim(),
        };

    for (final action in actions) {
      final actionId = (action['id'] ?? '').toString().trim();
      if (actionId.isEmpty) {
        skipped += 1;
        continue;
      }
      if (existingIds.contains(actionId)) {
        appliedIds.add(actionId);
        skipped += 1;
        continue;
      }
      final kind = (action['kind'] ?? action['type'] ?? '').toString();
      final payload = action['payload'] is Map
          ? Map<String, dynamic>.from(action['payload'] as Map)
          : const <String, dynamic>{};
      try {
        if (kind == 'enroll_face') {
          final result = await FaceEnrollmentSyncService.apply(
            serverUrl: settings.normalizedBaseUrl,
            actionId: actionId,
            payload: payload,
            counters: counters,
            fetchImage: (imageId) => _fetchStagedImage(settings, imageId),
          );
          if (result.failure != null) {
            if (!result.retryable) {
              actionFailures[actionId] = result.failure!;
              if (result.summary != null) {
                enrollmentResults[actionId] = result.summary!;
              }
            } else {
              deferred[actionId] = result.failure!;
            }
            failures.add(SyncActionFailure(
                actionId: actionId, message: result.failure!));
          } else {
            enrollmentResults[actionId] = result.summary!;
            appliedIds.add(actionId);
            if (result.replayed) skipped++;
          }
        } else if (kind == deletePhotoActionKind ||
            kind == replacePhotoActionKind ||
            kind == editRecordActionKind) {
          final result = switch (kind) {
            deletePhotoActionKind =>
              await ChekiEditSyncService.deletePhoto(payload),
            replacePhotoActionKind => await ChekiEditSyncService.replacePhoto(
                payload,
                counters: counters,
                fetchImage: (imageId) => _fetchStagedImage(settings, imageId),
              ),
            _ => await ChekiEditSyncService.editRecord(payload),
          };
          if (result.failure != null) {
            if (result.retryable) {
              deferred[actionId] = result.failure!;
            } else {
              actionFailures[actionId] = result.failure!;
            }
            failures.add(SyncActionFailure(
                actionId: actionId, message: result.failure!));
          } else {
            enrollmentResults[actionId] = result.summary!;
            appliedIds.add(actionId);
          }
        } else if (kind == chekiPhotoActionKind) {
          final result = await ChekiPhotoSyncService.apply(
            actionId: actionId,
            payload: payload,
            counters: counters,
            counter: _resolveCounter(counters, payload),
            unsettledActionIds: unsettled()..remove(actionId),
            fetchImage: (imageId) => _fetchStagedImage(settings, imageId),
          );
          if (result.failure != null) {
            if (result.retryable) {
              deferred[actionId] = result.failure!;
            } else {
              actionFailures[actionId] = result.failure!;
            }
            failures.add(SyncActionFailure(
                actionId: actionId, message: result.failure!));
          } else {
            enrollmentResults[actionId] = result.summary!;
            appliedIds.add(actionId);
          }
        } else if (kind == 'member_create') {
          final name = (payload['name'] ?? payload['member_name'] ?? '')
              .toString()
              .trim();
          if (name.isEmpty) {
            throw SyncException('建卡失败：缺少成员名');
          }
          final group = (payload['group_name'] ?? payload['group'] ?? '')
              .toString()
              .trim();
          final personId = _readNullableInt(payload['person_id']);
          final personName = (payload['person_name'] ?? '').toString().trim();
          // A retried action must not create a second card. 兼任 / 转团 are
          // different groups of the same person, so a matching person id alone
          // is not a duplicate when a new group was requested.
          final exists = counters.any((counter) {
            final groupMatches = group.isEmpty ||
                _normalizeMemberName(counter.groupName) ==
                    _normalizeMemberName(group);
            if (!groupMatches) return false;
            if (personId != null && counter.personId == personId) return true;
            return _normalizeMemberName(counter.name) ==
                _normalizeMemberName(name);
          });
          if (!exists) {
            final color = _validColor(payload['color']) ?? '#FFE135';
            final created = CounterModel(
              name: name,
              groupName: group,
              personId: personId,
              personName: personName.isEmpty ? name : personName,
              color: color,
            );
            final id = await DatabaseService.insertCounter(created);
            counters.add(created.copyWith(id: id));
          }
          appliedIds.add(actionId);
        } else if (kind == 'counter_delta') {
          var counter = _resolveCounter(counters, payload);
          if (counter == null && payload['allow_create'] == true) {
            final name = (payload['member_name'] ?? payload['name'] ?? '')
                .toString()
                .trim();
            final group = (payload['group_name'] ?? '').toString().trim();
            if (name.isEmpty) {
              throw SyncException('缺少成员名称，无法新建卡片');
            }
            final created = CounterModel(
              name: name,
              groupName: group,
              personId: _readNullableInt(payload['person_id']),
              personName: (payload['person_name'] ?? '').toString(),
              color: '#FFE135',
            );
            final id = await DatabaseService.insertCounter(created);
            counter = created.copyWith(id: id);
            counters.add(counter);
          }
          if (counter == null) {
            throw SyncException('本地找不到这位成员，请先在 App 里创建卡片');
          }
          final counts = payload['counts'];
          if (counts is! Map) {
            throw SyncException('操作缺少 counts');
          }
          final deltas = <CounterCountField, int>{};
          for (final field in CounterCountField.values) {
            final value = _readInt(
              counts[field.key] ??
                  counts[_snake(field.key)] ??
                  counts[field.key.replaceAll('Count', '')],
            );
            if (value > 0) {
              deltas[field] = value;
            }
          }
          if (deltas.isEmpty) {
            throw SyncException('操作没有有效的计数');
          }
          final occurredAt = _parseDate(
            (payload['occurred_at'] ?? '').toString(),
          );
          final pricing = pricingByGroup[counter.groupName.trim()] ??
              GroupPricingModel.unconfigured(counter.groupName.trim());
          final record = ActivityRecordModel.counterAdjustment(
            counter: counter,
            occurredAt: occurredAt,
            deltas: deltas,
            pricing: pricing,
            note: (payload['note'] ?? '').toString(),
            activityName: (payload['activity_name'] ?? '').toString(),
            venueName: (payload['venue_name'] ?? '').toString(),
            sessionLabel: (payload['session_label'] ?? '').toString(),
          ).copyWith(
            source: mcpSource,
            sourceRecordId: actionId,
          );
          await DatabaseService.insertActivityRecordWithCounterImpact(record);
          existingIds.add(actionId);
          appliedIds.add(actionId);
        } else if (kind == 'ticket') {
          final eventName =
              (payload['event_name'] ?? payload['subject_name'] ?? '')
                  .toString()
                  .trim();
          if (eventName.isEmpty) {
            throw SyncException('门票操作缺少活动名称');
          }
          final quantity = _readInt(payload['quantity'], fallback: 1);
          final unitPrice = _readDouble(payload['unit_price']);
          final ticketType = (payload['ticket_type'] ?? '').toString().trim();
          final isFree = payload['is_free'] == true;
          final record = ActivityRecordModel.ticket(
            eventName: eventName,
            occurredAt: _parseDate(
              (payload['occurred_at'] ?? '').toString(),
            ),
            quantity: max(1, quantity),
            unitPrice: isFree ? 0 : max(0, unitPrice),
            ticketType: ticketType,
            isFree: isFree,
            sessionLabel: (payload['session_label'] ?? '').toString(),
            venueName: (payload['venue_name'] ?? '').toString(),
            note: (payload['note'] ?? '').toString(),
          ).copyWith(
            source: mcpSource,
            sourceRecordId: actionId,
          );
          await DatabaseService.insertActivityRecord(record);
          await TicketPricingService.rememberRecord(record);
          existingIds.add(actionId);
          appliedIds.add(actionId);
        } else {
          throw SyncException('未知操作类型: $kind');
        }
      } catch (error) {
        final message = kind == 'enroll_face'
            ? '人脸登记未保存，请稍后重试'
            : kind == chekiPhotoActionKind
                ? '切奇照片未保存，下次同步重试：$error'
                : error is SyncException
                    ? error.message
                    : '$error';
        if (kind == 'member_create' && error is SyncException) {
          actionFailures[actionId] = message;
        } else {
          deferred[actionId] =
              message.length > 300 ? '${message.substring(0, 300)}…' : message;
        }
        failures.add(
          SyncActionFailure(actionId: actionId, message: message),
        );
      }
    }

    if (appliedIds.isNotEmpty ||
        actionFailures.isNotEmpty ||
        deferred.isNotEmpty) {
      try {
        await _request(
          settings,
          'POST',
          '/api/v1/actions/ack',
          body: {
            'ids': [...appliedIds, ...actionFailures.keys],
            if (actionFailures.isNotEmpty) 'failures': actionFailures,
            if (deferred.isNotEmpty) 'deferred': deferred,
            if (enrollmentResults.isNotEmpty) 'results': enrollmentResults,
          },
        );
      } catch (_) {
        // The next pull will see these ids again; the source_record_id
        // dedupe check above prevents double counting. Face enrollment has
        // a separate transactional receipt, including failures and summaries.
      }
    }
    return SyncApplyResult(
      applied: appliedIds.length,
      skipped: skipped,
      failures: failures,
    );
  }

  static Future<Map<String, dynamic>> buildSnapshot(
    SyncSettings settings,
  ) async {
    final counters = await DatabaseService.getCounters();
    final records = await DatabaseService.getActivityRecords();
    // Archived photos in 切册 order (per record), so an assistant can name
    // the one to delete or replace. sha1 is of the bytes as archived; for a
    // photo sent through MCP it is the sha1 of the image that was sent.
    final positions = <int, int>{};
    final photos = [
      for (final media in await DatabaseService.getActivityRecordMedia())
        {
          'media_id': media.id,
          'record_id': media.recordId,
          'position': positions.update(media.recordId, (n) => n + 1,
              ifAbsent: () => 1),
          'sha1': media.sourceHash,
          'media_type': media.mediaType.name,
          'created_at': media.createdAt.toIso8601String(),
          if (media.ownerPersonName.isNotEmpty)
            'owner_person_name': media.ownerPersonName,
        },
    ];
    final pricings = await DatabaseService.getGroupPricings();
    final merchStats = await MerchService.getStats();
    var appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.buildNumber.isEmpty
          ? info.version
          : '${info.version}+${info.buildNumber}';
    } catch (_) {
      appVersion = '';
    }

    final customByCounterId = <int, Map<String, int>>{};
    final customByPersonId = <int, Map<String, int>>{};
    final customByName = <String, Map<String, int>>{};
    for (final record in records) {
      final items = record.effectiveCustomChekiCounts;
      if (items.isEmpty) {
        continue;
      }
      final bucket = <String, int>{};
      for (final item in items) {
        final label = item.label.trim();
        if (label.isEmpty) continue;
        bucket[label] = (bucket[label] ?? 0) + item.count;
      }
      if (bucket.isEmpty) continue;
      final counterId = record.counterId;
      if (counterId != null) {
        final target = customByCounterId.putIfAbsent(counterId, () => {});
        bucket
            .forEach((key, value) => target[key] = (target[key] ?? 0) + value);
        continue;
      }
      final personId = record.personId;
      if (personId != null) {
        final target = customByPersonId.putIfAbsent(personId, () => {});
        bucket
            .forEach((key, value) => target[key] = (target[key] ?? 0) + value);
        continue;
      }
      final key =
          '${_normalize(record.groupName)}|${_normalize(record.subjectName)}';
      final target = customByName.putIfAbsent(key, () => {});
      bucket.forEach((key, value) => target[key] = (target[key] ?? 0) + value);
    }

    final counterMaps = <Map<String, dynamic>>[];
    final customTotalByCounterId = <int, int>{};
    for (final counter in counters) {
      final custom = <String, int>{};
      final byId = counter.id == null ? null : customByCounterId[counter.id];
      if (byId != null) {
        custom.addAll(byId);
      }
      if (counter.personId != null) {
        final byPerson = customByPersonId[counter.personId];
        if (byPerson != null) {
          byPerson.forEach((key, value) {
            custom[key] = (custom[key] ?? 0) + value;
          });
        }
      }
      final fallback =
          '${_normalize(counter.groupName)}|${_normalize(counter.name)}';
      final byName = customByName[fallback];
      if (byName != null) {
        byName.forEach((key, value) {
          custom[key] = (custom[key] ?? 0) + value;
        });
      }
      final customTotal =
          custom.values.fold<int>(0, (sum, value) => sum + value);
      if (counter.id != null) {
        customTotalByCounterId[counter.id!] = customTotal;
      }
      final total = counter.count + customTotal;
      counterMaps.add({
        ...counter.toMap(),
        'name_pinyin': counter.namePinyin,
        'custom_counts': custom,
        'total_count': total,
      });
    }

    final visibleCounters =
        counters.where((counter) => !counter.isHidden).toList(growable: false);
    final visibleIds =
        visibleCounters.map((counter) => counter.id).whereType<int>().toSet();
    var memberTotal = 0;
    final byType = <String, int>{
      'threeInchCount': 0,
      'fiveInchCount': 0,
      'unsignedThreeInchCount': 0,
      'unsignedFiveInchCount': 0,
      'groupCutCount': 0,
      'threeInchShukudaiCount': 0,
      'fiveInchShukudaiCount': 0,
    };
    final memberKeys = <String>{};
    for (final counter in visibleCounters) {
      final customTotal =
          counter.id == null ? 0 : (customTotalByCounterId[counter.id] ?? 0);
      memberTotal += counter.count + customTotal;
      byType['threeInchCount'] =
          (byType['threeInchCount'] ?? 0) + counter.aggregatedThreeInchCount;
      byType['fiveInchCount'] =
          (byType['fiveInchCount'] ?? 0) + counter.aggregatedFiveInchCount;
      byType['unsignedThreeInchCount'] =
          (byType['unsignedThreeInchCount'] ?? 0) +
              counter.unsignedThreeInchCount;
      byType['unsignedFiveInchCount'] = (byType['unsignedFiveInchCount'] ?? 0) +
          counter.unsignedFiveInchCount;
      byType['groupCutCount'] =
          (byType['groupCutCount'] ?? 0) + counter.groupCutCount;
      byType['threeInchShukudaiCount'] =
          (byType['threeInchShukudaiCount'] ?? 0) +
              counter.threeInchShukudaiCount;
      byType['fiveInchShukudaiCount'] = (byType['fiveInchShukudaiCount'] ?? 0) +
          counter.fiveInchShukudaiCount;
      memberKeys.add(_memberKey(counter));
    }

    var duplicateTotal = 0;
    final duplicateByField = <String, int>{};
    for (final record in records) {
      if (!record.isMulti) {
        continue;
      }
      // Legacy multi rows without a selected count field never contributed to
      // counter totals, so they must not reduce the snapshot total either.
      final field = record.multiCountField;
      if (field == null) {
        continue;
      }
      final matchedIds = <int>{};
      for (final participant in record.effectiveParticipants) {
        final counter = DatabaseService.resolveCounterForParticipant(
          counters,
          participant,
        );
        if (counter?.id != null && visibleIds.contains(counter!.id)) {
          matchedIds.add(counter.id!);
        }
      }
      if (matchedIds.length <= 1) {
        continue;
      }
      final duplicate = record.multiTotalCount * (matchedIds.length - 1);
      duplicateTotal += duplicate;
      final key = field.aggregatedBaseField.key;
      duplicateByField[key] = (duplicateByField[key] ?? 0) + duplicate;
      // Unsigned photos are also reported on their own key; de-duplicate
      // that bucket too so it matches the physical photo count.
      if (field.key != key) {
        duplicateByField[field.key] =
            (duplicateByField[field.key] ?? 0) + duplicate;
      }
    }

    final adjustedByType = <String, int>{
      for (final entry in byType.entries)
        entry.key: max(0, entry.value - (duplicateByField[entry.key] ?? 0)),
    };
    final ticketStats = TicketStats.fromRecords(records);
    final pricingByGroup = {
      for (final pricing in pricings) pricing.groupName.trim(): pricing,
    };
    var revenue = 0.0;
    for (final record in records) {
      if (record.shouldResolveWithCurrentPricing) {
        final pricing = pricingByGroup[record.groupName.trim()] ??
            GroupPricingModel.unconfigured(record.groupName.trim());
        revenue += record.totalAmountWithPricing(pricing);
      } else {
        revenue += record.totalAmount;
      }
    }

    final hiddenCounters =
        counters.where((counter) => counter.isHidden).toList(growable: false);
    return {
      'schema': 'ota-counter-snapshot',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'device_id': settings.deviceId,
      'app_version': appVersion,
      'counters': counterMaps,
      'records': records.map((record) => record.toMap()).toList(),
      'photos': photos,
      'pricings': pricings.map((pricing) => pricing.toMap()).toList(),
      // 周边 has its own ledger and is not part of the activity-record stream,
      // so the MCP snapshot gets a small summary object instead of fake
      // counter/ticket records. Extra JSON keys are ignored by older readers.
      'merch': {
        'purchase_count': merchStats.purchaseCount,
        'item_count': merchStats.itemCount,
        'amount': merchStats.amount,
        'by_kind': merchStats.amountByKind,
        'by_member': merchStats.amountByMember,
        'by_month': merchStats.amountByMonth,
      },
      'summary': {
        'total_count': max(0, memberTotal - duplicateTotal),
        'by_type': adjustedByType,
        'member_count': memberKeys.length,
        'hidden_member_count': hiddenCounters.length,
        'record_count': records.length,
        'revenue': revenue,
        'ticket_count': ticketStats.ticketCount,
        'ticket_amount': ticketStats.amount,
        'free_ticket_count': ticketStats.freeTicketCount,
        'paid_ticket_count': ticketStats.paidTicketCount,
        'ticket_types': ticketStats.countByType,
        'custom_total': counterMaps.fold<int>(
          0,
          (sum, map) =>
              sum +
              (map['custom_counts'] is Map
                  ? (map['custom_counts'] as Map).values.fold<int>(
                        0,
                        (inner, value) =>
                            inner + (value is num ? value.toInt() : 0),
                      )
                  : 0),
        ),
      },
    };
  }

  static String _memberKey(CounterModel counter) {
    if (counter.personId != null) {
      return 'person-id:${counter.personId}';
    }
    final personName = _normalize(counter.personName);
    if (personName.isNotEmpty) {
      return 'person-name:$personName';
    }
    return 'counter:${_normalize(counter.groupName)}|${_normalize(counter.name)}';
  }

  static String _normalizeMemberName(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s·•・_\-~/\\()\[\]{}（）【】「」『』]+'), '');

  static String? _validColor(Object? value) {
    final text = (value ?? '').toString().trim();
    if (RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(text)) return text.toUpperCase();
    return null;
  }

  static CounterModel? _resolveCounter(
    List<CounterModel> counters,
    Map<String, dynamic> payload,
  ) {
    final id = _readNullableInt(payload['counter_id']);
    final personId = _readNullableInt(payload['person_id']);
    final name = _normalize(
      (payload['member_name'] ?? payload['name'] ?? '').toString(),
    );
    final personName = _normalize((payload['person_name'] ?? '').toString());
    final group = _normalize((payload['group_name'] ?? '').toString());

    CounterModel? byId;
    if (id != null) {
      for (final counter in counters) {
        if (counter.id == id) {
          byId = counter;
          break;
        }
      }
    }
    // 兼任: a server action may carry the person's *primary* card id while
    // naming the other group. Group is the stronger routing signal, otherwise
    // Li-U-Li counts would land on the Meguri-Kaado card.
    if (byId != null &&
        (group.isEmpty || _normalize(byId.groupName) == group)) {
      return byId;
    }

    List<CounterModel> personCards = const [];
    if (personId != null) {
      personCards = counters
          .where((counter) => counter.personId == personId)
          .toList(growable: false);
    }
    if (personCards.isNotEmpty) {
      if (group.isNotEmpty) {
        for (final counter in personCards) {
          if (_normalize(counter.groupName) == group) return counter;
        }
        // The card may have moved groups; a single card is still unambiguous.
        if (personCards.length == 1) return personCards.single;
      } else {
        return personCards.first;
      }
    }

    if (name.isNotEmpty) {
      for (final counter in counters) {
        final counterName = _normalize(counter.name);
        final counterPerson = _normalize(counter.personName);
        final matchesName = counterName == name ||
            (personName.isNotEmpty && counterPerson == personName);
        if (!matchesName) continue;
        if (group.isEmpty || _normalize(counter.groupName) == group) {
          return counter;
        }
      }
    }

    // Only a group-less action may fall back to the carried id: it describes
    // the intended card directly.
    return group.isEmpty ? byId : null;
  }

  /// Downloads an image staged on the server (face enrollment or cheki
  /// photo). Missing/expired images throw [FaceEnrollmentImageNotFound].
  static Future<Uint8List> _fetchStagedImage(
    SyncSettings settings,
    String imageId,
  ) async {
    // One more try on a dropped connection or a timeout: a phone on a
    // mobile network loses one request now and then, and a photo action
    // with many images would otherwise wait for the next sync.
    try {
      return await _fetchStagedImageOnce(settings, imageId);
    } on FaceEnrollmentImageNotFound {
      rethrow;
    } on SyncException {
      rethrow;
    } catch (_) {
      await Future<void>.delayed(stagedImageRetryDelay);
      return _fetchStagedImageOnce(settings, imageId);
    }
  }

  @visibleForTesting
  static Duration stagedImageRetryDelay = const Duration(seconds: 1);

  static Future<Uint8List> _fetchStagedImageOnce(
    SyncSettings settings,
    String imageId,
  ) async {
    _requireConfigured(settings);
    final uri = Uri.parse('${settings.normalizedBaseUrl}/api/v1/face-images/'
        '${Uri.encodeComponent(imageId)}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 12));
      request.followRedirects = false;
      request.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${settings.token.trim()}');
      request.headers.set(capabilitiesHeader, capabilities);
      final response =
          await request.close().timeout(const Duration(seconds: 25));
      if (response.statusCode == HttpStatus.notFound ||
          response.statusCode == HttpStatus.gone) {
        throw const FaceEnrollmentImageNotFound();
      }
      if (response.statusCode >= 500) {
        // Retried once by [_fetchStagedImage].
        throw HttpException('照片下载失败 (HTTP ${response.statusCode})');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw SyncException('照片下载失败 (HTTP ${response.statusCode})');
      }
      final bytes = await response
          .fold<BytesBuilder>(
              BytesBuilder(), (buffer, chunk) => buffer..add(chunk))
          .timeout(const Duration(seconds: 25));
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  static Future<Map<String, dynamic>> _request(
    SyncSettings settings,
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    if (kIsWeb) {
      throw SyncException('Web 预览不支持本机同步，请在 App 中使用');
    }
    final base = settings.normalizedBaseUrl;
    if (base.isEmpty) {
      throw SyncException('请先填写同步服务地址');
    }
    final uri = Uri.tryParse('$base$path');
    if (uri == null) {
      throw SyncException('同步服务地址无效');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 12));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${settings.token.trim()}',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(capabilitiesHeader, capabilities);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response =
          await request.close().timeout(const Duration(seconds: 25));
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 25));
      Map<String, dynamic> decoded = const {};
      if (text.trim().isNotEmpty) {
        try {
          final value = jsonDecode(text);
          if (value is Map) {
            decoded = Map<String, dynamic>.from(value);
          }
        } catch (_) {
          throw SyncException('同步服务返回了无法解析的数据');
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message =
            (decoded['error'] ?? decoded['message'] ?? '').toString();
        throw SyncException(
          message.isEmpty ? '同步服务错误 (HTTP ${response.statusCode})' : message,
        );
      }
      return decoded;
    } on SocketException catch (error) {
      throw SyncException('连不上同步服务：${error.message}');
    } on TimeoutException {
      throw SyncException('同步服务响应超时');
    } finally {
      client.close(force: true);
    }
  }

  static void _requireConfigured(SyncSettings settings) {
    if (!settings.isConfigured) {
      throw SyncException('请先填写服务地址和 Token');
    }
  }

  static DateTime _parseDate(String raw) {
    final parsed = DateTime.tryParse(raw.trim());
    return parsed ?? DateTime.now();
  }

  static int _readInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static int? _readNullableInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double _readDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  static String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s·•・_\-~/\\\(\)\[\]\{\}]+'), '');
  }

  static String _snake(String camel) {
    return camel.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => '_${match.group(0)!.toLowerCase()}',
    );
  }

  static String _newDeviceId() {
    final random = Random.secure();
    final suffix = List<int>.generate(4, (_) => random.nextInt(256))
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'ota-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }
}
