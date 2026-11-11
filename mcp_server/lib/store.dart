import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'face_images.dart';
import 'snapshot.dart' show normalizePart;

const String kSyncServerName = 'ota-counter-sync';
const String kSyncServerVersion = '1.0.0';
const String kStateSchema = 'ota_counter_sync_state';

/// App → server capability header for chat face enrollment. Clients that do
/// not advertise it never receive `enroll_face` actions, so v1.6.0 apps keep
/// tolerating the upgraded server without reporting an unknown action type.
const String kCapabilitiesHeader = 'x-ota-capabilities';
const String kFaceEnrollmentCapability = 'face-enroll-v1';
const String kFaceEnrollmentActionKind = 'enroll_face';

String nowIso() => DateTime.now().toIso8601String();

/// File-backed state for the OTA Counter sync bridge.
///
/// The bridge deliberately keeps a single JSON document: it is easy to back
/// up, inspect, and move between machines. All mutations go through a small
/// future-chain lock so HTTP requests cannot interleave writes.
class SyncStore {
  SyncStore(this.dataDir, {this.publicBaseUrl});

  final String? publicBaseUrl;
  late final FaceImages faceImages = FaceImages(dataDir);

  final String dataDir;
  Map<String, dynamic>? _state;
  Future<void> _tail = Future<void>.value();

  File get stateFile => File('$dataDir/state.json');
  File get backupFile => File('$dataDir/state.json.bak');

  Future<Map<String, dynamic>> status() {
    return _locked((state) async => _statusMap(state));
  }

  Future<Map<String, dynamic>> replaceSnapshot(
    Map<String, dynamic> snapshot, {
    String? clientId,
  }) {
    return _locked((state) async {
      final copy = _deepCopy(snapshot);
      copy['received_at'] = nowIso();
      final nextRev = _readInt(state['rev']) + 1;
      copy['server_rev'] = nextRev;
      state['snapshot'] = copy;
      state['rev'] = nextRev;
      state['updated_at'] = nowIso();
      if (clientId != null && clientId.trim().isNotEmpty) {
        final clients = _ensureMap(state, 'clients');
        clients[clientId.trim()] = {
          'last_seen_at': nowIso(),
          'last_rev': nextRev,
        };
      }
      await _save(state);
      return _statusMap(state);
    });
  }

  Future<Map<String, dynamic>> queueAction(Map<String, dynamic> action) {
    if (action['kind'] == 'enroll_face') {
      throw FaceImageException('脸照录入请使用 enroll_face 或上传链接工具');
    }
    return _locked((state) async {
      final actions = _ensureList(state, 'actions');
      final id = _readString(action['id']).trim();
      if (id.isNotEmpty) {
        for (final existing in actions) {
          if (existing is Map && _readString(existing['id']) == id) {
            return {
              'action': _deepCopy(existing),
              'duplicate': true,
              'rev': _readInt(state['rev']),
            };
          }
        }
      }
      final pendingCount = actions
          .whereType<Map>()
          .where((item) => _readString(item['status']) == 'pending')
          .length;
      if (pendingCount >= 500) {
        throw StateError(
            'pending action queue is full (500); sync the app first');
      }
      final stored = _deepCopy(action);
      stored['id'] = id.isEmpty ? _newActionId() : id;
      stored['status'] = 'pending';
      stored['created_at'] ??= nowIso();
      stored['created_by'] ??= 'mcp';
      actions.add(stored);
      final nextRev = _readInt(state['rev']) + 1;
      state['rev'] = nextRev;
      state['updated_at'] = nowIso();
      await _save(state);
      return {
        'action': _deepCopy(stored),
        'duplicate': false,
        'rev': nextRev,
      };
    });
  }

  Future<Map<String, dynamic>> createFaceUploadLink(Map<String, dynamic> target,
      {String? requestBaseUrl}) {
    final base = Uri.tryParse(publicBaseUrl ?? requestBaseUrl ?? '');
    if (base == null ||
        !{'http', 'https'}.contains(base.scheme) ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment) {
      throw FaceImageException(
          '无法推导公开地址，请配置 OTA_SYNC_PUBLIC_BASE_URL（含反向代理路径前缀）');
    }
    return _locked((current) async {
      final state = _deepCopy(current);
      final links = state['face_upload_links'] as Map? ?? <String, dynamic>{};
      state['face_upload_links'] = links;
      final now = DateTime.now();
      links.removeWhere((_, value) =>
          DateTime.parse(value['expires_at'] as String).isBefore(now));
      final secret = faceRandomId();
      final expires = now.add(const Duration(hours: 24)).toIso8601String();
      links[secret] = {
        'target': _deepCopy(target),
        'expires_at': expires,
        'used': 0
      };
      await _save(state);
      _state = state;
      return {
        'url':
            '${base.toString().replaceFirst(RegExp(r'/+$'), '')}/face-upload?token=$secret',
        'expires_at': expires,
        'max_images': 10,
        'member': target,
        'message': '打开链接选择最多 10 张照片；App 同步后处理，请用 list_face_enrollments 查看结果。',
      };
    });
  }

  Future<Map<String, dynamic>> faceUploadLink(String secret) {
    return _locked((state) async => _deepCopy(_faceLink(state, secret)));
  }

  Map _faceLink(Map<String, dynamic> state, String secret) {
    final links = state['face_upload_links'];
    final link = links is Map ? links[secret] : null;
    if (link is! Map ||
        !DateTime.parse(link['expires_at'] as String).isAfter(DateTime.now())) {
      throw FaceImageException('上传链接无效或已过期，请重新生成', status: 401);
    }
    if (_readInt(link['used']) >= 10) {
      throw FaceImageException('此链接已上传 10 张图片，请重新生成', status: 409);
    }
    return link;
  }

  Future<Map<String, dynamic>> queueFaceEnrollment(
      Map<String, dynamic> target, String imageId, String source,
      {String? uploadSecret, String face = 'auto'}) {
    return _locked((current) async {
      final state = _deepCopy(current);
      final link = uploadSecret == null ? null : _faceLink(state, uploadSecret);
      final actions = _ensureList(state, 'actions');
      if (actions
              .whereType<Map>()
              .where((a) => a['status'] == 'pending')
              .length >=
          500) {
        throw FaceImageException('待处理队列已满，请先同步 App', status: 409);
      }
      final action = {
        'id': _newActionId(),
        'kind': 'enroll_face',
        'status': 'pending',
        'payload': {
          ...target,
          'imageId': imageId,
          'source': source,
          'face': face
        },
        'created_at': nowIso(),
        'created_by': 'mcp',
      };
      actions.add(action);
      if (link != null) link['used'] = _readInt(link['used']) + 1;
      state['rev'] = _readInt(state['rev']) + 1;
      state['updated_at'] = nowIso();
      await _save(state);
      _state = state;
      return {
        'action_id': action['id'],
        'status': 'pending',
        'kind': 'enroll_face',
        'message': '已排队，等待 App 同步后录入；尚未完成。'
      };
    });
  }

  Future<List<Map<String, dynamic>>> faceEnrollments(
      {String? status,
      Set<int>? counterIds,
      int? personId,
      String? group,
      int limit = 50}) {
    return _locked((state) async {
      final result = <Map<String, dynamic>>[];
      for (final action
          in _ensureList(state, 'actions').reversed.whereType<Map>()) {
        if (action['kind'] != 'enroll_face' ||
            (status != null && action['status'] != status)) {
          continue;
        }
        final payload =
            action['payload'] is Map ? action['payload'] as Map : const {};
        if (group != null &&
            !normalizePart(_readString(payload['group_name']))
                .contains(normalizePart(group))) {
          continue;
        }
        if (counterIds != null &&
            !counterIds.contains(payload['counter_id']) &&
            !(personId != null && payload['person_id'] == personId)) {
          continue;
        }
        result.add(_faceEnrollmentView(action));
        if (result.length >= limit) break;
      }
      return result;
    });
  }

  Future<Map<String, dynamic>> acknowledgeActions(
    Iterable<String> ids, {
    Map<String, String>? failures,
    Map<String, dynamic>? results,
  }) {
    return _locked((current) async {
      final state = _deepCopy(current);
      final wanted =
          ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
      if (wanted.isEmpty) {
        return {'applied': 0, 'failed': 0, 'rev': _readInt(state['rev'])};
      }
      final actions = _ensureList(state, 'actions');
      // Validate the new enrollment receipt contract before mutating any batch
      // item. Non-enrollment ACKs retain their existing behavior.
      for (final action in actions.whereType<Map>()) {
        final id = _readString(action['id']);
        if (action['kind'] != 'enroll_face' ||
            action['status'] != 'pending' ||
            !wanted.contains(id)) {
          continue;
        }
        final result = results?[id];
        final failure = failures?[id];
        if (failure != null) {
          if (failure.trim().isEmpty) {
            throw FaceImageException('脸照录入失败必须提供原因');
          }
          if (result != null) _validateFaceResult(result, failure: true);
          continue;
        }
        if (result != null) _validateFaceResult(result, failure: false);
        if (result is! Map ||
            result['faces_found'] is! int ||
            (result['faces_found'] as int) < 1 ||
            result['used_face'] is! int ||
            (result['used_face'] as int) < 1 ||
            (result['used_face'] as int) > (result['faces_found'] as int) ||
            result['samples_kept'] is! int ||
            (result['samples_kept'] as int) < 0) {
          throw FaceImageException(
              '成功脸照录入必须返回 results，包含 faces_found、used_face 和 samples_kept');
        }
        _validateFaceResult(result, failure: false);
      }
      final cleanupImages = <String>{};
      var applied = 0;
      var failed = 0;
      final at = nowIso();
      for (final action in actions) {
        if (action is! Map) {
          continue;
        }
        final id = _readString(action['id']);
        if (!wanted.contains(id)) {
          continue;
        }
        if (action['kind'] == 'enroll_face') {
          if (action['status'] != 'pending') {
            if (action['image_cleanup_pending'] == true) {
              cleanupImages
                  .add((action['payload'] as Map)['imageId'] as String);
            }
            continue;
          }
          action['image_cleanup_pending'] = true;
          cleanupImages.add((action['payload'] as Map)['imageId'] as String);
          final failure = failures?[id];
          action['status'] = failure == null ? 'applied' : 'failed';
          if (results?[id] != null) action['result'] = results![id];
          if (failure != null) {
            action['failure'] = failure;
            action['failed_at'] = at;
            failed++;
          } else {
            action['applied_at'] = at;
            applied++;
          }
          continue;
        }
        action['status'] = 'applied';
        action['applied_at'] = at;
        applied += 1;
      }
      if (failures != null) {
        for (final entry in failures.entries) {
          final id = entry.key.trim();
          for (final action in actions) {
            if (action is Map &&
                action['kind'] != 'enroll_face' &&
                _readString(action['id']) == id) {
              action['status'] = 'failed';
              action['failure'] = entry.value;
              action['failed_at'] = at;
              failed += 1;
            }
          }
        }
      }
      final nextRev = applied + failed > 0
          ? _readInt(state['rev']) + 1
          : _readInt(state['rev']);
      state['rev'] = nextRev;
      state['updated_at'] = at;
      if (cleanupImages.isEmpty) _pruneActions(actions);
      // Commit receipts before deleting their source images. Failed writes
      // leave both the in-memory pending state and image bytes retryable.
      await _save(state);
      _state = state;
      for (final imageId in cleanupImages) {
        await faceImages.delete(imageId);
      }
      for (final action in actions.whereType<Map>()) {
        if (action['kind'] == 'enroll_face' &&
            cleanupImages.contains((action['payload'] as Map)['imageId'])) {
          action.remove('image_cleanup_pending');
        }
      }
      // Pruning also protects failed cleanup from earlier ACK batches.
      final beforePrune = actions.length;
      _pruneActions(actions);
      if (cleanupImages.isNotEmpty || actions.length != beforePrune) {
        await _save(state);
      }
      return {
        'applied': applied,
        'failed': failed,
        'rev': nextRev,
      };
    });
  }

  Future<Map<String, dynamic>?> snapshot() {
    return _locked((state) async {
      final value = state['snapshot'];
      return value is Map ? _deepCopy(value) : null;
    });
  }

  Future<List<Map<String, dynamic>>> actions(
      {String? status, int limit = 100, Set<String>? excludeKinds}) {
    return _locked((state) async {
      final actions = _ensureList(state, 'actions');
      final result = <Map<String, dynamic>>[];
      for (final item in actions) {
        if (item is! Map) {
          continue;
        }
        if (excludeKinds != null &&
            excludeKinds.contains(_readString(item['kind']))) {
          continue;
        }
        if (status != null &&
            status.isNotEmpty &&
            _readString(item['status']) != status) {
          continue;
        }
        result.add(_deepCopy(item));
        if (result.length >= limit) {
          break;
        }
      }
      return result;
    });
  }

  Future<T> _locked<T>(
    Future<T> Function(Map<String, dynamic> state) action,
  ) async {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    try {
      await previous;
      final state = await _ensureLoaded();
      return await action(state);
    } finally {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  Future<Map<String, dynamic>> _ensureLoaded() async {
    final cached = _state;
    if (cached != null) {
      return cached;
    }
    await Directory(dataDir).create(recursive: true);
    final file = stateFile;
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final state = Map<String, dynamic>.from(decoded);
          _normalizeState(state);
          _state = state;
          return state;
        }
      } catch (_) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        await file.copy('$dataDir/state.corrupt.$stamp.json');
      }
    }
    final state = _emptyState();
    _state = state;
    await _save(state);
    return state;
  }

  Future<void> _save(Map<String, dynamic> state) async {
    await Directory(dataDir).create(recursive: true);
    final text = const JsonEncoder.withIndent('  ').convert(state);
    final tmp = File('$dataDir/state.json.tmp');
    await tmp.writeAsString(text, flush: true);
    final file = stateFile;
    if (await file.exists()) {
      try {
        await file.copy(backupFile.path);
      } catch (_) {
        // A missing backup is not fatal.
      }
    }
    try {
      await tmp.rename(file.path);
    } catch (_) {
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    }
  }

  Map<String, dynamic> _statusMap(Map<String, dynamic> state) {
    final snapshot = state['snapshot'];
    final snapshotMap = snapshot is Map ? snapshot : null;
    final actions = _ensureList(state, 'actions');
    var pending = 0;
    var applied = 0;
    var failed = 0;
    for (final action in actions) {
      if (action is! Map) {
        continue;
      }
      switch (_readString(action['status'])) {
        case 'pending':
          pending += 1;
        case 'applied':
          applied += 1;
        case 'failed':
          failed += 1;
      }
    }
    final summary = snapshotMap?['summary'];
    return {
      'ok': true,
      'name': kSyncServerName,
      'version': kSyncServerVersion,
      'time': nowIso(),
      'rev': _readInt(state['rev']),
      'updated_at': _readString(state['updated_at']),
      'snapshot': snapshotMap == null
          ? null
          : {
              'received_at': _readString(snapshotMap['received_at']),
              'exported_at': _readString(snapshotMap['exported_at']),
              'app_version': _readString(snapshotMap['app_version']),
              'device_id': _readString(snapshotMap['device_id']),
              'members': _readCounterList(snapshotMap).length,
              'records': _readRecordList(snapshotMap).length,
              'summary': summary is Map ? _deepCopy(summary) : null,
            },
      'actions': {
        'pending': pending,
        'applied': applied,
        'failed': failed,
      },
    };
  }

  Map<String, dynamic> _emptyState() {
    final at = nowIso();
    return {
      'schema': kStateSchema,
      'version': 1,
      'rev': 0,
      'created_at': at,
      'updated_at': at,
      'snapshot': null,
      'actions': <dynamic>[],
      'clients': <String, dynamic>{},
    };
  }

  void _normalizeState(Map<String, dynamic> state) {
    state['schema'] ??= kStateSchema;
    state['version'] ??= 1;
    state['rev'] ??= 0;
    state['created_at'] ??= nowIso();
    state['updated_at'] ??= nowIso();
    state['actions'] ??= <dynamic>[];
    state['clients'] ??= <String, dynamic>{};
  }

  void _pruneActions(List<dynamic> actions) {
    const maxApplied = 500;
    final appliedIndexes = <int>[];
    for (var i = 0; i < actions.length; i++) {
      final action = actions[i];
      if (action is Map &&
          _readString(action['status']) != 'pending' &&
          action['image_cleanup_pending'] != true) {
        appliedIndexes.add(i);
      }
    }
    final removeCount = appliedIndexes.length - maxApplied;
    if (removeCount <= 0) {
      return;
    }
    final toRemove = appliedIndexes.take(removeCount).toSet();
    for (var i = actions.length - 1; i >= 0; i--) {
      if (toRemove.contains(i)) {
        actions.removeAt(i);
      }
    }
  }

  String _newActionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    final suffix = base64UrlEncode(bytes).replaceAll('=', '');
    return 'act_${DateTime.now().millisecondsSinceEpoch}_$suffix';
  }
}

class SyncConfig {
  static Future<String> loadOrCreateToken(String dataDir) async {
    await Directory(dataDir).create(recursive: true);
    final file = File('$dataDir/token');
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) {
        return existing;
      }
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    await file.writeAsString('$token\n', flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {
        // Best effort only.
      }
    }
    return token;
  }

  static Future<void> writeToken(String dataDir, String token) async {
    await Directory(dataDir).create(recursive: true);
    await File('$dataDir/token').writeAsString('$token\n', flush: true);
  }

  static bool constantTimeEquals(String a, String b) {
    final left = a.codeUnits;
    final right = b.codeUnits;
    var diff = left.length ^ right.length;
    final length = min(left.length, right.length);
    for (var i = 0; i < length; i++) {
      diff |= left[i] ^ right[i];
    }
    return diff == 0;
  }
}

Map<String, dynamic> _faceEnrollmentView(Map<dynamic, dynamic> action) {
  final payload = action['payload'] is Map
      ? Map<String, dynamic>.from(action['payload'] as Map)
      : <String, dynamic>{};
  final result = action['result'] is Map
      ? Map<String, dynamic>.from(action['result'] as Map)
      : null;
  final id = _readString(action['id']);
  return {
    'id': id,
    'enrollment_id': id,
    'kind': 'enroll_face',
    'status': _readString(action['status']),
    'created_at': _readString(action['created_at']),
    'applied_at': action['applied_at'],
    'failed_at': action['failed_at'],
    'source': payload['source'],
    'face': payload['face'] ?? 'auto',
    'member_id': payload['counter_id'],
    'person_id': payload['person_id'],
    'member_name': payload['member_name'],
    'person_name': payload['person_name'],
    'group_name': payload['group_name'],
    'faces_found': result?['faces_found'],
    'used_face': result?['used_face'],
    'samples_kept': result?['samples_kept'],
    'faces': result?['faces'] ?? const <dynamic>[],
    'failure': action['failure'],
    'image_cleanup_pending': action['image_cleanup_pending'] == true,
    'result': result,
    'payload': payload,
  };
}

void _validateFaceResult(Object? value, {required bool failure}) {
  if (value is! Map) {
    throw FaceImageException('脸照结果必须是 JSON 对象');
  }
  final facesFound = value['faces_found'];
  if (facesFound is! int || facesFound < 0) {
    throw FaceImageException('脸照结果的 faces_found 必须是非负整数');
  }
  if (!failure && facesFound < 1) {
    throw FaceImageException('成功脸照的 faces_found 必须大于 0');
  }
  final usedFace = value['used_face'];
  if (usedFace != null) {
    if (usedFace is! int || usedFace < 1 || usedFace > facesFound) {
      throw FaceImageException('脸照结果的 used_face 必须是 1 到 faces_found 的整数');
    }
  } else if (!failure) {
    throw FaceImageException('成功脸照必须提供 used_face');
  }
  final samplesKept = value['samples_kept'];
  if (samplesKept is! int || samplesKept < 0) {
    throw FaceImageException('脸照结果的 samples_kept 必须是非负整数');
  }
  final faces = value['faces'];
  if (faces == null) {
    if (failure) {
      throw FaceImageException('失败脸照必须提供 faces 列表');
    }
    return;
  }
  if (faces is! List) {
    throw FaceImageException('脸照结果的 faces 必须是列表');
  }
  for (final item in faces) {
    if (item is! Map || item['index_from_left'] is! int) {
      throw FaceImageException('faces 项必须包含整数 index_from_left');
    }
    final index = item['index_from_left'] as int;
    if (index < 1) {
      throw FaceImageException('faces 的 index_from_left 从 1 开始');
    }
    final box = item['box'];
    if (box is! Map) {
      throw FaceImageException('faces 项必须包含归一化 box');
    }
    for (final key in ['x', 'y', 'width', 'height']) {
      final coordinate = box[key];
      if (coordinate is! num || coordinate < 0 || coordinate > 1) {
        throw FaceImageException('faces 的 box.$key 必须在 0 到 1 之间');
      }
    }
  }
}

Map<String, dynamic> _deepCopy(Map<dynamic, dynamic> value) {
  return Map<String, dynamic>.from(
    jsonDecode(jsonEncode(value)) as Map,
  );
}

List<dynamic> _ensureList(Map<String, dynamic> state, String key) {
  final value = state[key];
  if (value is List) {
    return value;
  }
  final list = <dynamic>[];
  state[key] = list;
  return list;
}

Map<String, dynamic> _ensureMap(Map<String, dynamic> state, String key) {
  final value = state[key];
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  final map = <String, dynamic>{};
  state[key] = map;
  return map;
}

int _readInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _readString(Object? value) => value is String ? value : '';

List<dynamic> _readCounterList(Map<dynamic, dynamic> snapshot) {
  final value = snapshot['counters'] ?? snapshot['members'];
  return value is List ? value : const [];
}

List<dynamic> _readRecordList(Map<dynamic, dynamic> snapshot) {
  final value = snapshot['records'] ?? snapshot['activity_records'];
  return value is List ? value : const [];
}
