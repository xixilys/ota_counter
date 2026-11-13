import 'dart:convert';

import 'face_images.dart';
import 'member_catalog.dart';
import 'snapshot.dart';
import 'store.dart';

const String kProtocolVersion = '2025-06-18';

class ToolException implements Exception {
  ToolException(this.message, {this.code = -32000});
  final String message;
  final int code;
  @override
  String toString() => message;
}

class McpMethodException extends ToolException {
  McpMethodException(super.message) : super(code: -32601);
}

/// Transport-independent MCP JSON-RPC handler.
///
/// [handle] accepts a decoded request object (or a JSON-RPC batch) and returns
/// the decoded response object. Notifications return `null`.
class McpProtocol {
  McpProtocol(
    this.store, {
    this.requestBaseUrl,
    this.catalog = MemberCatalog.empty,
  });

  final String? requestBaseUrl;

  final SyncStore store;

  final MemberCatalog catalog;

  Future<Object?> handle(Object? payload) async {
    if (payload is List) {
      final responses = <Object>[];
      for (final item in payload) {
        final response = await _handleOne(item);
        if (response != null) {
          responses.add(response);
        }
      }
      return responses.isEmpty ? null : responses;
    }
    return _handleOne(payload);
  }

  Future<Map<String, dynamic>?> _handleOne(Object? payload) async {
    if (payload is! Map) {
      return _error(null, -32600, 'Invalid Request');
    }
    final request = Map<String, dynamic>.from(payload);
    final id = request['id'];
    final method = request['method'];
    if (method is! String) {
      return _error(id, -32600, 'Invalid Request');
    }
    final isNotification = !request.containsKey('id') || id == null;
    final params = request['params'] is Map
        ? Map<String, dynamic>.from(request['params'] as Map)
        : <String, dynamic>{};

    try {
      final result = await _dispatch(method, params);
      if (isNotification) {
        return null;
      }
      return {
        'jsonrpc': '2.0',
        'id': id,
        'result': result,
      };
    } on ToolException catch (error) {
      if (isNotification) return null;
      return _error(id, error.code, error.message);
    } catch (error) {
      if (isNotification) return null;
      return _error(id, -32603, 'Internal error: $error');
    }
  }

  Future<Object?> _dispatch(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'initialize':
        return {
          'protocolVersion': params['protocolVersion'] is String &&
                  (params['protocolVersion'] as String).isNotEmpty
              ? params['protocolVersion']
              : kProtocolVersion,
          'capabilities': {
            'tools': {'listChanged': false},
            'resources': {'subscribe': false, 'listChanged': false},
            'prompts': {'listChanged': false},
          },
          'serverInfo': {
            'name': kSyncServerName,
            'version': kSyncServerVersion,
          },
          'instructions':
              'OTA Counter bridge. Read the latest app snapshot with '
                  'get_overview/list_members/list_records. Use record_cheki or '
                  'add_ticket to queue changes; they are applied by the OTA '
                  'Counter app on its next pull. Check get_sync_status for '
                  'snapshot age and pending actions. 用户发照片并说「这是X」时：先用 '
                  'list_members/get_member 核对 member_id（重名时补充 group），再调用 '
                  'enroll_face；有图片字节就用 image_base64，只有公开 HTTP(S) 图片 URL 才用 '
                  'image_url。只能回复「已排队，手机打开同步后生效」，不要说已录入。之后用 '
                  'list_face_enrollments 查询 App 回执，诚实报告 faces_found、used_face 和 '
                  'samples_kept（每人最多保留 30 个样本，samples_kept 可能为 0）。失败时按中文原因'
                  '和 faces 里的 index_from_left 让用户用 face: left_N 重试。没有图片字节时用 '
                  'create_face_upload_link 给用户手机上传链接。没有卡片的新人先用 search_member 查名册/别名，'
                  '再 create_member 或 record_cheki(allow_create=true)。不要索取或显示同步 token。',
        };
      case 'ping':
        return <String, dynamic>{};
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return null;
      case 'logging/setLevel':
        return <String, dynamic>{};
      case 'roots/list':
        return {'roots': <dynamic>[]};
      case 'tools/list':
        return {'tools': _toolDefinitions};
      case 'tools/call':
        return _callTool(params);
      case 'resources/list':
        return {'resources': _resources};
      case 'resources/read':
        return _readResource(params);
      case 'prompts/list':
        return {'prompts': _prompts};
      case 'prompts/get':
        return _getPrompt(params);
      default:
        throw McpMethodException('Method not found: $method');
    }
  }

  Future<Map<String, dynamic>> _callTool(Map<String, dynamic> params) async {
    final name = params['name'] is String ? params['name'] as String : '';
    final arguments = params['arguments'] is Map
        ? Map<String, dynamic>.from(params['arguments'] as Map)
        : <String, dynamic>{};
    if (name.isEmpty) {
      return _toolError('Missing tool name');
    }
    try {
      final value = await _runTool(name, arguments);
      return _toolResult(value);
    } catch (error) {
      return _toolError(error.toString());
    }
  }

  Future<Object?> _runTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    switch (name) {
      case 'get_overview':
        return _getOverview();
      case 'list_members':
        return _listMembers(arguments);
      case 'get_member':
        return _getMember(arguments);
      case 'list_records':
        return _listRecords(arguments);
      case 'list_groups':
        return _listGroups();
      case 'record_cheki':
        return _recordCheki(arguments);
      case 'create_member':
        return _createMember(arguments);
      case 'search_member':
        return _searchMember(arguments);
      case 'add_ticket':
        return _addTicket(arguments);
      case 'list_pending_actions':
        return _listPendingActions(arguments);
      case 'get_sync_status':
        return _getSyncStatus();
      case 'create_face_upload_link':
        return store.createFaceUploadLink(await _faceTarget(arguments),
            requestBaseUrl: requestBaseUrl);
      case 'enroll_face':
        final target = await _faceTarget(arguments);
        final face = _faceSelector(arguments);
        final image = _faceImageArgument(arguments);
        final imageId = image.url != null
            ? await store.faceImages.fetch(image.url!)
            : await store.faceImages.saveBytes(image.bytes!, image.mime!);
        try {
          final queued = await store
              .queueFaceEnrollment(target, imageId, image.source, face: face);
          return {
            ...queued,
            'enrollment_id': queued['action_id'],
            'face': face,
            'message': '已排队，手机打开 OTA Counter 同步后才会处理；尚未录入。',
          };
        } catch (_) {
          await store.faceImages.delete(imageId);
          rethrow;
        }
      case 'list_face_enrollments':
        final status = readString(arguments, ['status']);
        if (status.isNotEmpty &&
            !{'pending', 'applied', 'failed'}.contains(status)) {
          throw ToolException('status 只能是 pending、applied 或 failed');
        }
        final hasIdentity = arguments['member_id'] != null ||
            readString(arguments, ['member']).trim().isNotEmpty;
        final member = hasIdentity ? await _faceMember(arguments) : null;
        final actions = await store.faceEnrollments(
          status: status.isEmpty ? null : status,
          group: readString(arguments, ['group']).trim().isEmpty
              ? null
              : readString(arguments, ['group']).trim(),
          counterIds: member?.counterIds.toSet(),
          personId: member?.personId,
          limit: readInt(arguments, ['limit'], 50).clamp(1, 100),
        );
        return {'count': actions.length, 'enrollments': actions};
      default:
        throw ToolException('Unknown tool: $name');
    }
  }

  Future<MemberAggregate> _faceMember(Map<String, dynamic> arguments) async {
    final rawId = arguments['member_id'];
    if (rawId != null && _parseMemberId(rawId) == null) {
      throw ToolException('member_id 无效，请用 list_members 核对');
    }
    if (rawId == null &&
        (arguments['member'] is! String ||
            (arguments['member'] as String).trim().isEmpty)) {
      throw ToolException('请提供 member_id（优先）或 member（成员名）；重名时同时提供 group（团名）');
    }
    if (arguments['group'] != null && arguments['group'] is! String) {
      throw ToolException('group 必须是字符串');
    }
    return _findMember(await _requireSnapshot(), arguments,
        requireUnique: true);
  }

  int? _parseMemberId(Object? value) {
    if (value is num) {
      final id = value.toInt();
      return id > 0 ? id : null;
    }
    if (value is String) {
      final id = int.tryParse(value.trim());
      return id != null && id > 0 ? id : null;
    }
    return null;
  }

  Future<Map<String, dynamic>> _faceTarget(
      Map<String, dynamic> arguments) async {
    final member = await _faceMember(arguments);
    final rawId = _parseMemberId(arguments['member_id']);
    final group = readString(arguments, ['group']).trim();
    Map<dynamic, dynamic>? counter;
    if (rawId != null) {
      for (final item in member.counters) {
        if (readInt(item, ['id']) == rawId) {
          counter = item;
          break;
        }
      }
      if (counter == null) {
        throw ToolException(
            'member_id $rawId 与成员 ${member.name} 不一致，请用 list_members 核对');
      }
      if (group.isNotEmpty &&
          !normalizePart(counterGroup(counter))
              .contains(normalizePart(group))) {
        throw ToolException(
            'member_id $rawId 属于 ${counterGroup(counter)}，与 group「$group」不一致');
      }
    } else {
      final groups = member.groups
          .where((g) => normalizePart(g).contains(normalizePart(group)))
          .toList();
      if (group.isNotEmpty && groups.length != 1) {
        throw ToolException('团名不明确，请提供完整 group：${member.groups.join('、')}');
      }
      counter = group.isEmpty
          ? member.counters.firstWhere(
              (c) => readInt(c, ['id']) == member.primaryCounterId,
              orElse: () => member.counters.first)
          : member.counters
              .firstWhere((c) => counterGroup(c).trim() == groups.single);
    }
    final id = readInt(counter, ['id']);
    if (id <= 0) throw ToolException('成员编号无效，请先重新同步 App 快照');
    final personName = counterPersonName(counter).trim();
    return {
      'counter_id': id,
      'person_id': member.personId,
      'person_name': personName.isEmpty ? member.name : personName,
      'member_name': counterName(counter),
      'group_name': counterGroup(counter),
    };
  }

  String _faceSelector(Map<String, dynamic> arguments) {
    final raw = arguments['face'];
    if (raw == null || (raw is String && raw.trim().isEmpty)) return 'auto';
    if (raw is! String) {
      throw ToolException('face 必须是字符串：auto、largest 或 left_N');
    }
    final value = raw.trim().toLowerCase();
    if (value == 'auto' || value == 'largest') return value;
    final match = RegExp(r'^left_(\d+)$').firstMatch(value);
    final index = match == null ? null : int.tryParse(match.group(1)!);
    if (index != null && index >= 1 && index <= 50) return 'left_$index';
    throw ToolException('face 只能是 auto、largest 或 left_N（N 从 1 开始，按人脸框中心从左到右）');
  }

  ({String? url, List<int>? bytes, String? mime, String source})
      _faceImageArgument(Map<String, dynamic> arguments) {
    final urlValue = arguments['image_url'];
    final base64Value = arguments['image_base64'];
    if (urlValue == null && base64Value == null) {
      throw ToolException('请提供 image_url 或 image_base64（二者只能有一个）');
    }
    if (urlValue != null && base64Value != null) {
      throw ToolException('image_url 与 image_base64 只能提供一个');
    }
    if (urlValue != null) {
      if (urlValue is! String || urlValue.trim().isEmpty) {
        throw ToolException('image_url 必须是非空 HTTP(S) 图片地址');
      }
      return (url: urlValue.trim(), bytes: null, mime: null, source: 'url');
    }
    if (base64Value is! String || base64Value.trim().isEmpty) {
      throw ToolException('image_base64 必须是非空 JPEG 或 PNG 的 base64 字符串');
    }
    var text = base64Value.trim();
    String? declaredMime;
    final prefix =
        RegExp(r'^data:image/(jpeg|jpg|png);base64,', caseSensitive: false)
            .firstMatch(text);
    if (text.toLowerCase().startsWith('data:')) {
      if (prefix == null) {
        throw ToolException('只接受 data:image/jpeg 或 data:image/png 前缀');
      }
      declaredMime =
          prefix.group(1)!.toLowerCase() == 'png' ? 'image/png' : 'image/jpeg';
      text = text.substring(prefix.end);
    }
    if (text.length > maxFaceBase64EncodedBytes) {
      throw ToolException('image_base64 编码后不能超过 8 MB');
    }
    List<int> bytes;
    try {
      bytes = base64Decode(text.replaceAll(RegExp(r'[\s]'), ''));
    } on FormatException {
      throw ToolException('image_base64 不是有效的 base64 数据');
    }
    String mime;
    if (isJpegBytes(bytes)) {
      mime = 'image/jpeg';
    } else if (isPngBytes(bytes)) {
      mime = 'image/png';
    } else {
      throw ToolException('仅支持 JPEG 或 PNG 图片，请换一张照片');
    }
    if (declaredMime != null && declaredMime != mime) {
      throw ToolException('data: 前缀声明为 $declaredMime，但图片内容不是该格式');
    }
    return (url: null, bytes: bytes, mime: mime, source: 'base64');
  }

  Future<SnapshotView> _requireSnapshot() async {
    final snapshot = await store.snapshot();
    if (snapshot == null) {
      throw ToolException(
        'No snapshot has been uploaded yet. Open OTA Counter → menu → '
        'MCP 同步 and tap 一键同步 (or upload a snapshot with POST /api/v1/snapshot).',
      );
    }
    return SnapshotView(snapshot);
  }

  Future<Map<String, dynamic>> _getOverview() async {
    final view = await _requireSnapshot();
    final status = await store.status();
    final result = view.overview(
      pendingActions: _pendingCount(status),
    );
    return {
      ...result,
      'server_rev': status['rev'],
      'snapshot_age_seconds': _snapshotAgeSeconds(view.raw),
      'stale': _snapshotAgeSeconds(view.raw) > 15 * 60,
    };
  }

  Future<Map<String, dynamic>> _listMembers(
    Map<String, dynamic> arguments,
  ) async {
    final view = await _requireSnapshot();
    final query = normalizePart(readString(arguments, ['query']));
    final includeHidden = arguments['include_hidden'] == true;
    final limit = readInt(arguments, ['limit'], 50).clamp(1, 100);
    final offset = readInt(arguments, ['offset'], 0).clamp(0, 10000);
    final all = view.members(includeHidden: includeHidden);
    final filtered = query.isEmpty
        ? all
        : all.where((member) {
            final haystack = normalizePart([
              member.name,
              member.groupLabel,
              ...member.groups,
            ].join(' '));
            return haystack.contains(query);
          }).toList(growable: false);
    final total = view.totalCount;
    final page = filtered.skip(offset).take(limit).toList(growable: false);
    return {
      'total': filtered.length,
      'offset': offset,
      'limit': limit,
      'members': [
        for (final member in page) member.toJson(total: total),
      ],
    };
  }

  Future<Map<String, dynamic>> _getMember(
    Map<String, dynamic> arguments,
  ) async {
    final view = await _requireSnapshot();
    final member = _findMember(view, arguments);
    final total = view.totalCount;
    final recent = view.searchRecords(member: member.name, limit: 10);
    return {
      ...member.toJson(total: total),
      'recent_records': [
        for (final record in recent) _recordJson(record),
      ],
      'counters': member.counters.map((counter) {
        return {
          'counter_id': readInt(counter, ['id']),
          'name': counterName(counter),
          'group': counterGroup(counter),
          'total_count': counterTotal(counter),
          'counts': counterCounts(counter),
        };
      }).toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> _listRecords(
    Map<String, dynamic> arguments,
  ) async {
    final view = await _requireSnapshot();
    final records = view.searchRecords(
      from: readString(arguments, ['from']),
      to: readString(arguments, ['to']),
      member: readString(arguments, ['member']),
      type: readString(arguments, ['type']),
      limit: readInt(arguments, ['limit'], 30),
      offset: readInt(arguments, ['offset'], 0),
    );
    return {
      'records': [
        for (final record in records) _recordJson(record),
      ],
      'count': records.length,
    };
  }

  Future<Map<String, dynamic>> _listGroups() async {
    final view = await _requireSnapshot();
    return {
      'groups': view.groups(),
      'count': view.groups().length,
    };
  }

  Future<Map<String, dynamic>> _recordCheki(
    Map<String, dynamic> arguments,
  ) async {
    final view = await _requireSnapshot();
    final allowCreate = arguments['allow_create'] == true;
    MemberAggregate? member;
    try {
      member = _findMember(view, arguments);
    } on ToolException {
      if (!allowCreate) rethrow;
    }
    final counts = <String, int>{};
    for (final entry in countKeyAliases.entries) {
      final value = arguments[entry.key] ??
          arguments[_camel(entry.key)] ??
          arguments[entry.value];
      if (value is num && value.toInt() > 0) {
        counts[entry.value] = value.toInt().clamp(1, 999);
      }
    }
    if (counts.isEmpty) {
      throw ToolException(
        'No count supplied. Pass at least one of three_inch, five_inch, '
        'unsigned_three_inch, unsigned_five_inch, group_cut, '
        'three_inch_shukudai, five_inch_shukudai.',
      );
    }
    final occurredAt = _parseOccurredAt(
      readString(arguments, ['occurred_at', 'occurredAt']),
    );

    int? personId;
    String personName;
    String primaryGroup;
    int? counterId;
    String memberName;
    final found = member;
    if (found == null) {
      // allow_create with a name that is not on any card yet.
      final name = readString(arguments, ['name', 'member']).trim();
      if (name.isEmpty) {
        throw ToolException(
          'allow_create=true 时需要 name：请提供要新建卡片的成员名',
        );
      }
      personId = _optionalPersonId(arguments['person_id']);
      personName = readString(arguments, ['person_name', 'personName']).trim();
      primaryGroup = readString(arguments, ['group_name', 'group']).trim();
      counterId = null;
      memberName = name;
      if (personName.isEmpty) personName = name;
    } else {
      final requestedGroup =
          readString(arguments, ['group', 'group_name']).trim();
      if (requestedGroup.isNotEmpty &&
          !found.groups.any(
            (value) => normalizePart(value) == normalizePart(requestedGroup),
          )) {
        throw ToolException(
          'Group "$requestedGroup" is not one of this member\'s groups: '
          '${found.groups.join(', ')}',
        );
      }
      primaryGroup =
          requestedGroup.isNotEmpty ? requestedGroup : found.primaryGroup;
      counterId = found.primaryCounterId;
      personId = found.personId;
      personName = found.name;
      memberName = found.name;
    }

    final payload = {
      'counter_id': counterId,
      'person_id': personId,
      'person_name': personName,
      'member_name': memberName,
      'group_name': primaryGroup,
      'occurred_at': occurredAt.toIso8601String(),
      'counts': counts,
      'note': readString(arguments, ['note']),
      'activity_name': readString(arguments, ['activity_name', 'activityName']),
      'venue_name': readString(arguments, ['venue_name', 'venueName']),
      'session_label': readString(arguments, ['session_label', 'sessionLabel']),
      'allow_create': allowCreate,
    };
    final queued = await store.queueAction({
      'kind': 'counter_delta',
      'payload': payload,
      'created_by': 'mcp',
    });
    final action = queued['action'] as Map;
    return {
      'action_id': action['id'],
      'status': action['status'],
      'kind': 'counter_delta',
      'member': {
        'member_id': counterId,
        'name': memberName,
        'group': primaryGroup,
      },
      'counts': counts,
      'occurred_at': payload['occurred_at'],
      'pending_actions': _pendingCount(await store.status()),
      'message':
          'Queued. Open OTA Counter → MCP 同步 → 一键同步 to apply it locally.',
    };
  }

  int? _optionalPersonId(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final id = value.toInt();
      return id > 0 ? id : null;
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      final id = int.tryParse(trimmed);
      if (id == null || id <= 0) {
        throw ToolException('person_id 必须是正整数');
      }
      return id;
    }
    throw ToolException('person_id 必须是正整数');
  }

  Future<Map<String, dynamic>> _createMember(
    Map<String, dynamic> arguments,
  ) async {
    final name = readString(arguments, ['name']).trim();
    if (name.isEmpty) {
      throw ToolException('name 不能为空：请提供要建卡的成员名');
    }
    if (name.length > 40) {
      throw ToolException('name 太长（最多 40 字）');
    }
    final group = readString(arguments, ['group', 'group_name']).trim();
    final personName =
        readString(arguments, ['person_name', 'personName']).trim();
    final personId = _optionalPersonId(arguments['person_id']);
    final color = readString(arguments, ['color']).trim();
    if (color.isNotEmpty && !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
      throw ToolException('color 需要 #RRGGBB 格式，例如 #FF5C8A');
    }

    final view = await _requireSnapshot();
    final normalized = MemberCatalog.normalizeName(name);
    for (final member in view.members(includeHidden: true)) {
      final names = <String>[
        member.name,
        for (final counter in member.counters) counterName(counter),
        for (final counter in member.counters) counterPersonName(counter),
      ].where((value) => value.trim().isNotEmpty);
      final sameName = names.any(
        (value) => MemberCatalog.normalizeName(value) == normalized,
      );
      final samePerson = personId != null && member.personId == personId;
      if (!sameName && !samePerson) continue;
      throw ToolException(
        '重名：已有成员卡「${member.name}」'
        '（${member.groupLabel.isEmpty ? '无团名' : member.groupLabel}，'
        'member_id ${member.primaryCounterId ?? '?'}），不需要 create_member；'
        '要计数请直接用 record_cheki。',
      );
    }

    final payload = <String, dynamic>{
      'name': name,
      'group_name': group,
      'person_id': personId,
      'person_name': personName.isEmpty ? name : personName,
      'color': color,
    };
    final queued = await store.queueAction({
      'kind': 'member_create',
      'payload': payload,
      'created_by': 'mcp',
    });
    final action = queued['action'] as Map;
    return {
      'ok': true,
      'action_id': action['id'],
      'status': action['status'],
      'kind': 'member_create',
      'member': {
        'name': name,
        'group': group,
        'person_id': personId,
        'person_name': payload['person_name'],
        'color': color,
      },
      'pending_actions': _pendingCount(await store.status()),
      'message': '已排队建卡，手机打开 OTA Counter 同步后才会出现这张卡。',
    };
  }

  Future<Map<String, dynamic>> _searchMember(
    Map<String, dynamic> arguments,
  ) async {
    final query = readString(arguments, ['query', 'q', 'name']).trim();
    if (query.isEmpty) {
      throw ToolException('query 不能为空：请给一个名字或别名');
    }
    final limit = readInt(arguments, ['limit'], 10).clamp(1, 50);
    final snapshot = await store.snapshot();
    final view = snapshot == null ? null : SnapshotView(snapshot);
    final appMembers =
        view?.members(includeHidden: true) ?? const <MemberAggregate>[];

    final candidates = <String, Map<String, dynamic>>{};
    void addCandidate(String key, Map<String, dynamic> value) {
      final existing = candidates[key];
      if (existing == null) {
        candidates[key] = value;
        return;
      }
      if ((value['score'] as int) > (existing['score'] as int)) {
        // Keep the card-backed row when one exists.
        candidates[key] = {
          ...value,
          if ((existing['has_card'] as bool) && !(value['has_card'] as bool))
            'has_card': true,
          if (existing['member_id'] != null && value['member_id'] == null)
            'member_id': existing['member_id'],
        };
      }
    }

    for (final member in appMembers) {
      final names = <String>[
        member.name,
        for (final counter in member.counters) counterName(counter),
        for (final counter in member.counters) counterPersonName(counter),
      ].where((value) => value.trim().isNotEmpty).toList();
      var bestScore = 0;
      var bestName = member.name;
      for (final value in names) {
        final match = MemberCatalog.bestMatch(query, value);
        if (match.score > bestScore) {
          bestScore = match.score;
          bestName = value;
        }
      }
      if (bestScore <= 0) continue;
      addCandidate(
        MemberCatalog.normalizeName(member.name),
        {
          'member_id': member.primaryCounterId,
          'person_id': member.personId,
          'name': member.name,
          'group': member.primaryGroup.isEmpty
              ? member.groupLabel
              : member.primaryGroup,
          'groups': member.groups,
          'has_card': true,
          'source': 'app',
          'status': '',
          'match': bestName,
          'score': bestScore,
        },
      );
    }

    for (final result in catalog.search(query, limit: limit)) {
      final member = result.member;
      final key = MemberCatalog.normalizeName(member.name);
      final existing = candidates[key];
      if (existing != null) {
        existing['has_card'] = true;
        if (existing['score'] < result.score) {
          existing['score'] = result.score;
        }
        continue;
      }
      addCandidate(key, {
        'member_id': null,
        'person_id': null,
        'name': member.name,
        'group': member.group,
        'groups': [member.group],
        'has_card': false,
        'source': 'roster',
        'status': member.status,
        'match': member.name,
        'score': result.score,
      });
    }

    final sorted = candidates.values.toList()
      ..sort((a, b) {
        final score = (b['score'] as int).compareTo(a['score'] as int);
        if (score != 0) return score;
        final card = (b['has_card'] as bool ? 1 : 0)
            .compareTo(a['has_card'] as bool ? 1 : 0);
        if (card != 0) return card;
        return (a['name'] as String).compareTo(b['name'] as String);
      });
    final page = sorted.take(limit).toList(growable: false);
    return {
      'query': query,
      'count': page.length,
      'total_matches': sorted.length,
      'roster_size': catalog.roster.length,
      'candidates': page,
      if (page.isEmpty) 'message': '没有找到匹配的成员或别名',
    };
  }

  Future<Map<String, dynamic>> _addTicket(
    Map<String, dynamic> arguments,
  ) async {
    final eventName = readString(arguments, ['event_name', 'eventName']).trim();
    if (eventName.isEmpty) {
      throw ToolException('event_name is required');
    }
    final quantity = readInt(arguments, ['quantity'], 1).clamp(1, 50);
    final isFree = arguments['is_free'] == true;
    final ticketType =
        readString(arguments, ['ticket_type', 'ticketType']).trim();
    final unitPrice = isFree
        ? 0.0
        : readDouble(arguments, ['unit_price', 'unitPrice']).clamp(0, 100000);
    final occurredAt = _parseOccurredAt(
      readString(arguments, ['occurred_at', 'occurredAt']),
    );
    final queued = await store.queueAction({
      'kind': 'ticket',
      'payload': {
        'event_name': eventName,
        'occurred_at': occurredAt.toIso8601String(),
        'quantity': quantity,
        'unit_price': unitPrice,
        'ticket_type': ticketType,
        'is_free': isFree,
        'session_label':
            readString(arguments, ['session_label', 'sessionLabel']),
        'venue_name': readString(arguments, ['venue_name', 'venueName']),
        'note': readString(arguments, ['note']),
      },
      'created_by': 'mcp',
    });
    final action = queued['action'] as Map;
    return {
      'action_id': action['id'],
      'status': action['status'],
      'kind': 'ticket',
      'event_name': eventName,
      'quantity': quantity,
      'unit_price': unitPrice,
      'ticket_type': ticketType,
      'is_free': isFree,
      'occurred_at': occurredAt.toIso8601String(),
      'pending_actions': _pendingCount(await store.status()),
    };
  }

  Future<Map<String, dynamic>> _listPendingActions(
    Map<String, dynamic> arguments,
  ) async {
    final limit = readInt(arguments, ['limit'], 50).clamp(1, 100);
    final actions = await store.actions(status: 'pending', limit: limit);
    return {
      'count': actions.length,
      'actions': actions,
    };
  }

  Future<Map<String, dynamic>> _getSyncStatus() async {
    final status = await store.status();
    final snapshot = await store.snapshot();
    return {
      ...status,
      'snapshot_age_seconds':
          snapshot == null ? null : _snapshotAgeSeconds(snapshot),
      'configured': snapshot != null,
    };
  }

  Future<Map<String, dynamic>> _readResource(
    Map<String, dynamic> params,
  ) async {
    final uri = readString(params, ['uri']);
    Object? data;
    if (uri == 'ota://sync-status') {
      data = await _getSyncStatus();
    } else if (uri == 'ota://overview') {
      data = await _getOverview();
    } else if (uri == 'ota://members') {
      final view = await _requireSnapshot();
      final total = view.totalCount;
      data = {
        'members': [
          for (final member in view.members(includeHidden: false))
            member.toJson(total: total),
        ],
      };
    } else if (uri == 'ota://recent-records') {
      final view = await _requireSnapshot();
      data = {
        'records': [
          for (final record in view.searchRecords(limit: 20))
            _recordJson(record),
        ],
      };
    } else if (uri == 'ota://snapshot') {
      data = await store.snapshot();
    } else {
      throw ToolException('Unsupported resource: $uri');
    }
    return {
      'contents': [
        {
          'uri': uri,
          'mimeType': 'application/json',
          'text': const JsonEncoder.withIndent('  ').convert(data),
        },
      ],
    };
  }

  Future<Map<String, dynamic>> _getPrompt(
    Map<String, dynamic> params,
  ) async {
    final name = readString(params, ['name']);
    final arguments = params['arguments'] is Map
        ? Map<String, dynamic>.from(params['arguments'] as Map)
        : <String, dynamic>{};
    if (name == 'enroll-member-face') {
      return {
        'description': '从聊天中录入成员脸照',
        'messages': [
          {
            'role': 'user',
            'content': {
              'type': 'text',
              'text': '请帮我录入成员脸照。先用 list_members/get_member 核对成员，'
                  '优先用 member_id；重名时询问并补充 member 与 group，不能擅自选择。'
                  '用户发来照片时用 enroll_face，聊天机器人有图片字节就传 image_base64，'
                  '有公开 HTTP(S) 图片地址才传 image_url；没有图片字节才用 '
                  'create_face_upload_link 给用户手机上传链接（最多 10 张，24 小时）。'
                  '不要索取或显示同步 token。回复只能是「已排队，手机打开同步后生效」，'
                  '之后用 list_face_enrollments 查询，报告 faces_found、used_face、'
                  'samples_kept（每人最多保留 30 个样本，0 表示新样本未保留）或中文失败原因。'
                  '失败时按 faces 的 index_from_left 让用户用 face: left_N 重试。'
                  '多人照片先按可信相似度选择；否则只有最大脸面积至少为次大脸的 1.5 倍才选择，'
                  '无法判断或零张脸应报告失败。'
            },
          }
        ],
      };
    }
    if (name != 'daily-summary' && name != 'monthly-report') {
      throw ToolException('Unknown prompt: $name');
    }
    final view = await _requireSnapshot();
    final overview = view.overview();
    final members = view.members(includeHidden: false).take(20);
    final date = readString(arguments, ['date']);
    final base = DateTime.tryParse(date) ?? DateTime.now();
    final from = name == 'daily-summary'
        ? formatDate(base)
        : formatDate(DateTime(base.year, base.month, 1));
    final to = name == 'daily-summary'
        ? from
        : formatDate(DateTime(base.year, base.month + 1, 0));
    final records = view.searchRecords(
      from: from,
      to: to,
      limit: 50,
    );
    final payload = {
      'period': from,
      'overview': overview,
      'members': [for (final m in members) m.toJson(total: view.totalCount)],
      'records': [for (final r in records) _recordJson(r)],
    };
    return {
      'description': name == 'daily-summary'
          ? 'Summarise one day of OTA Counter activity.'
          : 'Summarise the current month of OTA Counter activity.',
      'messages': [
        {
          'role': 'user',
          'content': {
            'type': 'text',
            'text': 'You are the OTA Counter assistant. Use this data to '
                'write a concise ${name == 'daily-summary' ? 'daily' : 'monthly'} '
                'summary in Chinese. Mention totals, standout members, and '
                'spend. Do not invent numbers.\n\n'
                '${const JsonEncoder.withIndent('  ').convert(payload)}',
          },
        },
      ],
    };
  }

  MemberAggregate _findMember(
    SnapshotView view,
    Map<String, dynamic> arguments, {
    bool requireUnique = false,
  }) {
    final members = view.members(includeHidden: true);
    final rawId = arguments['member_id'] ?? arguments['counter_id'];
    int? id;
    if (rawId is num) id = rawId.toInt();
    if (rawId is String) id = int.tryParse(rawId);
    if (id != null) {
      for (final member in members) {
        if (member.primaryCounterId == id || member.counterIds.contains(id)) {
          return member;
        }
      }
    }
    if (requireUnique && rawId != null) {
      throw ToolException('成员 ID 无效，请用 list_members 核对');
    }
    final name = normalizePart(readString(arguments, ['name', 'member']));
    final group = normalizePart(readString(arguments, ['group']));
    if (name.isEmpty) {
      throw ToolException(
        'Member not identified. Pass member_id (see list_members) or name.',
      );
    }
    final candidates = members.where((member) {
      final nameMatch = normalizePart(member.name).contains(name) ||
          member.counters.any(
            (counter) => normalizePart(counterName(counter)).contains(name),
          );
      if (!nameMatch) return false;
      if (group.isEmpty) return true;
      return member.groups.any(
        (value) => normalizePart(value).contains(group),
      );
    }).toList(growable: false);
    if (candidates.isEmpty) {
      final suggestions = members
          .take(10)
          .map((m) =>
              '${m.name}（${m.groupLabel.isEmpty ? '无团名' : m.groupLabel}，member_id ${m.primaryCounterId ?? '?'}）')
          .join('；');
      throw ToolException(
        '没有找到成员「$name${group.isEmpty ? '' : ' / $group'}」。'
        '可用成员：${suggestions.isEmpty ? '无' : suggestions}。请用 list_members 核对。',
      );
    }
    if (requireUnique && candidates.length > 1) {
      final labels = candidates
          .take(10)
          .map((m) =>
              '${m.name} / ${m.groupLabel.isEmpty ? '无团名' : m.groupLabel}（member_id ${m.primaryCounterId ?? '?'}）')
          .join('；');
      throw ToolException('匹配到多位成员，请补充 member 与 group 或改用 member_id：$labels');
    }
    candidates.sort((a, b) => b.total.compareTo(a.total));
    return candidates.first;
  }

  Map<String, dynamic> _recordJson(Map<dynamic, dynamic> record) {
    final type = recordType(record);
    final counts = <String, int>{
      'three_inch': readInt(record, ['three_inch_count', 'threeInchCount']),
      'five_inch': readInt(record, ['five_inch_count', 'fiveInchCount']),
      'unsigned_three_inch': readInt(
        record,
        ['unsigned_three_inch_count', 'unsignedThreeInchCount'],
      ),
      'unsigned_five_inch': readInt(
        record,
        ['unsigned_five_inch_count', 'unsignedFiveInchCount'],
      ),
      'group_cut': readInt(record, ['group_cut_count', 'groupCutCount']),
      'three_inch_shukudai': readInt(
        record,
        ['three_inch_shukudai_count', 'threeInchShukudaiCount'],
      ),
      'five_inch_shukudai': readInt(
        record,
        ['five_inch_shukudai_count', 'fiveInchShukudaiCount'],
      ),
    };
    final multiQuantity = readInt(record, [
      'multi_cut_quantity',
      'multiCutQuantity',
      'double_cut_quantity',
    ]);
    final ticketQuantity =
        readInt(record, ['ticket_quantity', 'ticketQuantity']);
    return {
      'id': readInt(record, ['id'], -1),
      'type': type,
      'date': recordDate(record),
      'occurred_at': readString(record, ['occurred_at', 'occurredAt']),
      'subject': recordDisplayName(record),
      'group': readString(record, ['group_name', 'groupName']),
      'person_name': readString(record, ['person_name', 'personName']),
      'activity_name': readString(record, ['activity_name', 'activityName']),
      'venue_name': readString(record, ['venue_name', 'venueName']),
      'session_label': readString(record, ['session_label', 'sessionLabel']),
      'note': readString(record, ['note']),
      'counts': counts,
      'multi_quantity': multiQuantity,
      'ticket_quantity': ticketQuantity,
      'ticket_type': readString(record, ['ticket_type', 'ticketType']).trim(),
      'is_free': record['ticket_is_free'] == null
          ? (readDouble(record, ['ticket_unit_price', 'ticketUnitPrice']) <=
                  0 &&
              readDouble(record, ['total_amount', 'totalAmount']) <= 0)
          : readBool(record, ['ticket_is_free']),
      'total_amount': readDouble(record, ['total_amount', 'totalAmount']),
    };
  }

  Map<String, dynamic> _toolResult(Object? value) {
    final structured = value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{'data': value};
    return {
      'content': [
        {
          'type': 'text',
          'text': const JsonEncoder.withIndent('  ').convert(value),
        },
      ],
      'structuredContent': structured,
      'isError': false,
    };
  }

  Map<String, dynamic> _toolError(String message) {
    return {
      'content': [
        {'type': 'text', 'text': message},
      ],
      'isError': true,
    };
  }

  Map<String, dynamic> _error(Object? id, int code, String message) {
    return {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    };
  }

  int _pendingCount(Map<String, dynamic> status) {
    final actions = status['actions'];
    return actions is Map ? readInt(actions, ['pending']) : 0;
  }

  int _snapshotAgeSeconds(Map<String, dynamic> snapshot) {
    final raw = readString(snapshot, ['received_at', 'exported_at']);
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return 0;
    final age = DateTime.now().difference(parsed).inSeconds;
    return age < 0 ? 0 : age;
  }

  DateTime _parseOccurredAt(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return DateTime.now();
    }
    final parsed = DateTime.tryParse(trimmed);
    if (parsed == null) {
      throw ToolException(
        'occurred_at must be YYYY-MM-DD or an ISO-8601 date-time.',
      );
    }
    return parsed;
  }

  String _camel(String snake) {
    final parts = snake.split('_');
    if (parts.length == 1) return snake;
    return parts.first +
        parts.skip(1).map((part) {
          if (part.isEmpty) return '';
          return part[0].toUpperCase() + part.substring(1);
        }).join();
  }

  static const _faceMemberProperties = <String, dynamic>{
    'member_id': {
      'type': ['integer', 'string'],
      'description': 'Preferred; id from list_members/get_member'
    },
    'member': {'type': 'string', 'description': '成员名；没有 member_id 时使用'},
    'group': {'type': 'string', 'description': '团名；同名成员必须提供'},
  };

  static const _faceArgumentProperties = <String, dynamic>{
    'member_id': {
      'type': ['integer', 'string'],
      'description': '首选；list_members/get_member 返回的 member_id'
    },
    'member': {'type': 'string', 'description': '成员名；没有 member_id 时使用'},
    'group': {'type': 'string', 'description': '团名；同名成员必须提供'},
    'image_url': {
      'type': 'string',
      'description': '公开 HTTP(S) 图片地址，≤15 MB，20 秒超时'
    },
    'image_base64': {
      'type': 'string',
      'description': 'JPEG/PNG 的 base64；可带 data:image/...;base64, 前缀，≤8 MB 编码'
    },
    'face': {
      'type': 'string',
      'description': 'auto（默认）、largest，或 left_N（按人脸框中心从左到右第 N 张）'
    },
  };

  static const List<Map<String, dynamic>> _toolDefinitions = [
    {
      'name': 'create_face_upload_link',
      'description':
          '为指定成员生成 24 小时有效的手机上传链接（最多 10 张），供没有图片字节的聊天客户端使用。优先用 member_id；重名补 member 与 group。App 同步后才处理。',
      'inputSchema': {
        'type': 'object',
        'properties': _faceMemberProperties,
        'additionalProperties': false
      },
    },
    {
      'name': 'enroll_face',
      'description': '用户发照片说「这是X」时调用：先 list_members 核对 member_id，再提交图片排队录入。'
          'image_url 与 image_base64 只能提供一个；image_base64 适合聊天机器人直接传字节。'
          'App 同步后才会处理，只能回复「已排队，手机打开同步后生效」。'
          '之后用 list_face_enrollments 报告实际结果；每人最多保留 30 个样本。',
      'inputSchema': {
        'type': 'object',
        'properties': _faceArgumentProperties,
        'additionalProperties': false
      },
    },
    {
      'name': 'list_face_enrollments',
      'description': '查询脸照录入状态及 App 回执：pending 等待同步、applied 成功、failed 及中文原因。'
          '每条包含 faces_found、used_face、samples_kept；失败还带 faces（index_from_left 与归一化 box），'
          '可让用户用 face: left_N 重试。samples_kept 是实际保留数，可能为 0，不能说已新增。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'member_id': {
            'type': ['integer', 'string']
          },
          'member': {'type': 'string'},
          'group': {'type': 'string'},
          'status': {
            'type': 'string',
            'enum': ['pending', 'applied', 'failed']
          },
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        },
        'additionalProperties': false
      },
    },
    {
      'name': 'get_overview',
      'description':
          'Get the latest OTA Counter totals, member count, record count, '
              'revenue and pending action count.',
      'inputSchema': {
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_members',
      'description':
          'List members (app home cards, merged across group affiliations) '
              'with totals and per-type counts.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Name or group filter'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
          'offset': {'type': 'integer', 'minimum': 0},
          'include_hidden': {'type': 'boolean'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_member',
      'description':
          'Get one member by member_id (preferred) or by name/group, with '
              'recent records and per-affiliation counters.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'member_id': {
            'type': ['integer', 'string']
          },
          'name': {'type': 'string'},
          'group': {'type': 'string'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_records',
      'description':
          'List activity records filtered by date range, member and type.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'from': {'type': 'string', 'description': 'YYYY-MM-DD inclusive'},
          'to': {'type': 'string', 'description': 'YYYY-MM-DD inclusive'},
          'member': {'type': 'string'},
          'type': {
            'type': 'string',
            'enum': ['counter', 'multi', 'ticket', 'all'],
          },
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
          'offset': {'type': 'integer', 'minimum': 0},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_groups',
      'description': 'List groups known from group pricing or member cards.',
      'inputSchema': {
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
    },
    {
      'name': 'record_cheki',
      'description':
          'Queue a cheki count change for a member. The app applies it on the '
              'next pull, so totals change after the app syncs. Counts are '
              'additive and never negative.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'member_id': {
            'type': ['integer', 'string']
          },
          'name': {'type': 'string'},
          'group': {'type': 'string'},
          'group_name': {'type': 'string'},
          'person_name': {'type': 'string'},
          'person_id': {
            'type': ['integer', 'string']
          },
          'three_inch': {'type': 'integer', 'minimum': 0, 'maximum': 999},
          'five_inch': {'type': 'integer', 'minimum': 0, 'maximum': 999},
          'unsigned_three_inch': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 999,
          },
          'unsigned_five_inch': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 999,
          },
          'group_cut': {'type': 'integer', 'minimum': 0, 'maximum': 999},
          'three_inch_shukudai': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 999,
          },
          'five_inch_shukudai': {
            'type': 'integer',
            'minimum': 0,
            'maximum': 999,
          },
          'occurred_at': {'type': 'string'},
          'note': {'type': 'string'},
          'activity_name': {'type': 'string'},
          'venue_name': {'type': 'string'},
          'session_label': {'type': 'string'},
          'allow_create': {'type': 'boolean'},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'create_member',
      'description': '给还没有卡片的成员建卡。服务端只排队 member_create，App 下一次同步时插入卡片；'
          '重名、缺 name 或 color 格式不对会直接返回中文失败原因。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': '成员名，必填'},
          'group': {'type': 'string', 'description': '团名，可空'},
          'person_id': {
            'type': ['integer', 'string'],
            'description': '同一真人的 person id，可空'
          },
          'person_name': {'type': 'string', 'description': '主档名，可空；默认用 name'},
          'color': {'type': 'string', 'description': '#RRGGBB，可空'},
        },
        'required': ['name'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'search_member',
      'description': '在 App 成员卡和仓库偶像名册（china_idols_seed.json）里模糊查名字/别名，'
          '返回 member_id、name、group、是否已有卡片。适合「Yuina→優晴Yu1na」「猪猪包→皮皮猪」这类查询。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '名字、别名或片段'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 50},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'add_ticket',
      'description': 'Queue a ticket purchase record for the app to apply.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'event_name': {'type': 'string'},
          'quantity': {'type': 'integer', 'minimum': 1, 'maximum': 50},
          'unit_price': {'type': 'number', 'minimum': 0},
          'ticket_type': {
            'type': 'string',
            'description': 'Ticket tier, e.g. 预售票 / 现场票 / 学生票',
          },
          'is_free': {
            'type': 'boolean',
            'description': 'Free event/ticket; unit_price becomes 0',
          },
          'occurred_at': {'type': 'string'},
          'session_label': {'type': 'string'},
          'venue_name': {'type': 'string'},
          'note': {'type': 'string'},
        },
        'required': ['event_name'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_pending_actions',
      'description': 'List queued changes that the app has not applied yet.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'get_sync_status',
      'description':
          'Get snapshot freshness, revision and pending action counts.',
      'inputSchema': {
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
    },
  ];

  static const List<Map<String, dynamic>> _resources = [
    {
      'uri': 'ota://overview',
      'name': 'OTA Counter overview',
      'mimeType': 'application/json',
      'description':
          'Latest counts, member count, revenue and pending actions.',
    },
    {
      'uri': 'ota://members',
      'name': 'OTA Counter members',
      'mimeType': 'application/json',
      'description': 'All visible members with per-type counts.',
    },
    {
      'uri': 'ota://recent-records',
      'name': 'OTA Counter recent records',
      'mimeType': 'application/json',
      'description': 'The 20 most recent activity records.',
    },
    {
      'uri': 'ota://sync-status',
      'name': 'OTA Counter sync status',
      'mimeType': 'application/json',
      'description': 'Snapshot age, revision and pending action counts.',
    },
  ];

  static const List<Map<String, dynamic>> _prompts = [
    {
      'name': 'enroll-member-face',
      'description': '从聊天图片或手机上传链接为成员录入脸照，并查询 App 实际处理结果。'
    },
    {
      'name': 'daily-summary',
      'description': 'Summarise one day of OTA Counter activity.',
      'arguments': [
        {
          'name': 'date',
          'description': 'YYYY-MM-DD; defaults to today',
          'required': false,
        },
      ],
    },
    {
      'name': 'monthly-report',
      'description': 'Summarise the current month of OTA Counter activity.',
      'arguments': [
        {
          'name': 'date',
          'description': 'Any date in the target month',
          'required': false,
        },
      ],
    },
  ];
}
