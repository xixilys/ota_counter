import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

const String kSyncServerName = 'ota-counter-sync';
const String kSyncServerVersion = '1.0.0';
const String kStateSchema = 'ota_counter_sync_state';

String nowIso() => DateTime.now().toIso8601String();

/// File-backed state for the OTA Counter sync bridge.
///
/// The bridge deliberately keeps a single JSON document: it is easy to back
/// up, inspect, and move between machines. All mutations go through a small
/// future-chain lock so HTTP requests cannot interleave writes.
class SyncStore {
  SyncStore(this.dataDir);

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

  Future<Map<String, dynamic>> acknowledgeActions(
    Iterable<String> ids, {
    Map<String, String>? failures,
  }) {
    return _locked((state) async {
      final wanted =
          ids.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
      if (wanted.isEmpty) {
        return {'applied': 0, 'failed': 0, 'rev': _readInt(state['rev'])};
      }
      final actions = _ensureList(state, 'actions');
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
        action['status'] = 'applied';
        action['applied_at'] = at;
        applied += 1;
      }
      if (failures != null) {
        for (final entry in failures.entries) {
          final id = entry.key.trim();
          for (final action in actions) {
            if (action is Map && _readString(action['id']) == id) {
              action['status'] = 'failed';
              action['failure'] = entry.value;
              action['failed_at'] = at;
              failed += 1;
            }
          }
        }
      }
      _pruneActions(actions);
      final nextRev = applied + failed > 0
          ? _readInt(state['rev']) + 1
          : _readInt(state['rev']);
      state['rev'] = nextRev;
      state['updated_at'] = at;
      await _save(state);
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
      {String? status, int limit = 100}) {
    return _locked((state) async {
      final actions = _ensureList(state, 'actions');
      final result = <Map<String, dynamic>>[];
      for (final item in actions) {
        if (item is! Map) {
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
      if (action is Map && _readString(action['status']) != 'pending') {
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
