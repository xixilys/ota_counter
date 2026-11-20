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
          'instructions': 'OTA Counter bridge. Read the latest app snapshot with '
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
      case 'attach_cheki_photos':
        return _attachChekiPhotos(arguments);
      case 'list_cheki_photos':
        final status = readString(arguments, ['status']);
        if (status.isNotEmpty &&
            !{'pending', 'applied', 'failed'}.contains(status)) {
          throw ToolException('status 只能是 pending、applied 或 failed');
        }
        final actions = await store.chekiPhotoActions(
          status: status.isEmpty ? null : status,
          limit: readInt(arguments, ['limit'], 50).clamp(1, 100),
        );
        return {'count': actions.length, 'attachments': actions};
      case 'list_record_photos':
        return _listRecordPhotos(arguments);
      case 'delete_cheki_photo':
        return _deleteChekiPhoto(arguments);
      case 'replace_cheki_photo':
        return _replaceChekiPhoto(arguments);
      case 'edit_record':
        return _editRecord(arguments);
      case 'list_cheki_edits':
        final status = readString(arguments, ['status']);
        if (status.isNotEmpty &&
            !{'pending', 'applied', 'failed'}.contains(status)) {
          throw ToolException('status 只能是 pending、applied 或 failed');
        }
        final edits = await store.chekiEditActions(
          status: status.isEmpty ? null : status,
          recordId: arguments['record_id'] == null
              ? null
              : _requireId(arguments['record_id'], 'record_id'),
          mediaId: arguments['media_id'] == null
              ? null
              : _requireId(arguments['media_id'], 'media_id'),
          limit: readInt(arguments, ['limit'], 50).clamp(1, 100),
        );
        return {'count': edits.length, 'edits': edits};
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

  /// Image arguments of `attach_cheki_photos` / `record_cheki`: an `images`
  /// array (objects with image_base64 / image_url, or bare strings) plus an
  /// optional single top-level image_base64 / image_url.
  List<({String? url, List<int>? bytes, String? mime, String source})>
      _chekiImageArguments(Map<String, dynamic> arguments,
          {required bool required}) {
    final items = <Map<String, dynamic>>[];
    final list = arguments['images'];
    if (list != null) {
      if (list is! List) {
        throw ToolException('images 必须是数组，每项是 {image_base64} 或 {image_url}');
      }
      for (final item in list) {
        if (item is String) {
          final text = item.trim();
          items.add(RegExp(r'^https?://', caseSensitive: false).hasMatch(text)
              ? {'image_url': text}
              : {'image_base64': text});
        } else if (item is Map) {
          items.add({
            if ((item['image_url'] ?? item['url']) != null)
              'image_url': item['image_url'] ?? item['url'],
            if ((item['image_base64'] ?? item['base64']) != null)
              'image_base64': item['image_base64'] ?? item['base64'],
          });
        } else {
          throw ToolException('images 的每一项必须是对象或字符串');
        }
      }
    }
    if (arguments['image_base64'] != null || arguments['image_url'] != null) {
      items.add({
        if (arguments['image_url'] != null) 'image_url': arguments['image_url'],
        if (arguments['image_base64'] != null)
          'image_base64': arguments['image_base64'],
      });
    }
    if (items.isEmpty) {
      if (!required) return const [];
      throw ToolException('请至少提供一张照片：images 数组，或 image_base64 / image_url');
    }
    if (items.length > kMaxChekiPhotosPerAction) {
      throw ToolException('一次最多 $kMaxChekiPhotosPerAction 张照片，请分批提交');
    }
    final parsed =
        <({String? url, List<int>? bytes, String? mime, String source})>[];
    for (var i = 0; i < items.length; i++) {
      try {
        parsed.add(_faceImageArgument(items[i]));
      } on ToolException catch (error) {
        throw ToolException('第 ${i + 1} 张照片：${error.message}');
      }
    }
    return parsed;
  }

  /// Stages every image; on any failure the already staged ones are removed.
  Future<List<Map<String, dynamic>>> _stageChekiImages(
      List<({String? url, List<int>? bytes, String? mime, String source})>
          images) async {
    final staged = <Map<String, dynamic>>[];
    try {
      for (var i = 0; i < images.length; i++) {
        final image = images[i];
        final String id;
        try {
          id = image.url != null
              ? await store.faceImages.fetch(image.url!)
              : await store.faceImages.saveBytes(image.bytes!, image.mime!);
        } on FaceImageException catch (error) {
          throw ToolException('第 ${i + 1} 张照片：${error.message}');
        }
        staged.add({
          'imageId': id,
          'source': image.source,
          'mime': await store.faceImages.mime(id),
        });
      }
      return staged;
    } catch (_) {
      await _deleteStaged(staged);
      rethrow;
    }
  }

  Future<void> _deleteStaged(List<Map<String, dynamic>> staged) async {
    for (final image in staged) {
      await store.faceImages.delete(image['imageId'] as String);
    }
  }

  Future<Map<String, dynamic>> _attachChekiPhotos(
    Map<String, dynamic> arguments,
  ) async {
    final images = _chekiImageArguments(arguments, required: true);
    final rawRecordId = arguments['record_id'];
    int? recordId;
    if (rawRecordId != null) {
      recordId = _parseMemberId(rawRecordId);
      if (recordId == null) {
        throw ToolException('record_id 必须是正整数，请用 list_records 核对');
      }
    }
    final recordActionId = readString(arguments, ['record_action_id']).trim();
    final rawName = readString(arguments, ['name', 'member']).trim();
    final hasMember = arguments['member_id'] != null || rawName.isNotEmpty;
    if (!hasMember && recordId == null && recordActionId.isEmpty) {
      throw ToolException(
          '请提供 member_id（优先）或 name（重名时加 group）；也可以直接给 record_id');
    }
    final rawOccurredAt = readString(arguments, ['occurred_at', 'occurredAt']);
    if (rawOccurredAt.trim().isEmpty &&
        recordId == null &&
        recordActionId.isEmpty) {
      throw ToolException('请提供 occurred_at（拍切日期 YYYY-MM-DD），或用 record_id 指定流水');
    }
    final occurredAt =
        rawOccurredAt.trim().isEmpty ? null : _parseOccurredAt(rawOccurredAt);

    var target = <String, dynamic>{};
    if (hasMember) {
      try {
        target = await _faceTarget({
          ...arguments,
          if (arguments['member'] == null && rawName.isNotEmpty)
            'member': rawName,
        });
      } on ToolException {
        // A card that a queued record_cheki(allow_create) is about to create
        // is not in the snapshot yet; the linked action identifies it.
        if (recordActionId.isEmpty) rethrow;
        target = {
          'member_name': rawName,
          'group_name': readString(arguments, ['group']).trim(),
        };
      }
    }
    if (recordId != null) {
      final snapshot = await store.snapshot();
      if (snapshot != null) {
        final record = SnapshotView(snapshot)
            .records
            .where((item) => readInt(item, ['id']) == recordId)
            .firstOrNull;
        if (record == null) {
          throw ToolException(
              'record_id $recordId 不在最新快照里，请先在 App 同步，或用 list_records 核对');
        }
        if (recordType(record) == 'ticket') {
          throw ToolException('record_id $recordId 是门票流水，切奇照片只能挂到切奇流水');
        }
      }
    }

    final staged = await _stageChekiImages(images);
    final payload = <String, dynamic>{
      ...target,
      'occurred_at': occurredAt?.toIso8601String() ?? '',
      'activity_name':
          readString(arguments, ['activity_name', 'activityName']).trim(),
      if (recordId != null) 'record_id': recordId,
      if (recordActionId.isNotEmpty) 'record_action_id': recordActionId,
      'note': readString(arguments, ['note']).trim(),
      'images': staged,
    };
    final Map<String, dynamic> queued;
    try {
      queued = await store.queueChekiPhotos(payload);
    } on FaceImageException catch (error) {
      await _deleteStaged(staged);
      throw ToolException(error.message);
    } catch (_) {
      await _deleteStaged(staged);
      rethrow;
    }
    return {
      ...queued,
      'image_count': staged.length,
      'member': target,
      if (recordId != null) 'record_id': recordId,
      'occurred_at': payload['occurred_at'],
      'message': '已排队 ${staged.length} 张照片，手机打开 OTA Counter 同步后才会挂到切册；'
          '尚未完成。之后用 list_cheki_photos 查看结果。',
    };
  }

  int _requireId(Object? value, String name) {
    final id = _parseMemberId(value);
    if (id == null) throw ToolException('$name 必须是正整数');
    return id;
  }

  /// The snapshot's 切册 photo list (App 1.7.13+).
  List<Map<dynamic, dynamic>> _snapshotPhotos(SnapshotView view) {
    final photos = view.raw['photos'];
    if (photos is! List) {
      throw ToolException(
          '快照里没有照片清单：请把手机上的 OTA Counter 升级到 1.7.13 或以上，并同步一次');
    }
    return photos.whereType<Map>().toList();
  }

  Map<String, dynamic> _photoTarget(SnapshotView view, int mediaId) {
    final photo = _snapshotPhotos(view)
        .where((p) => readInt(p, ['media_id']) == mediaId)
        .firstOrNull;
    if (photo == null) {
      throw ToolException(
          '照片 #$mediaId 不在最新快照里（可能已删除，或 App 还没同步），请用 list_record_photos 核对');
    }
    final recordId = readInt(photo, ['record_id']);
    final record =
        view.records.where((r) => readInt(r, ['id']) == recordId).firstOrNull;
    return {
      'media_id': mediaId,
      'record_id': recordId,
      'position': readInt(photo, ['position']),
      'sha1': readString(photo, ['sha1']),
      if (record != null) 'record': _recordBrief(record),
    };
  }

  Map<String, dynamic> _recordBrief(Map<dynamic, dynamic> record) => {
        'id': readInt(record, ['id'], -1),
        'type': recordType(record),
        'date': recordDate(record),
        'subject': recordDisplayName(record),
        'group': readString(record, ['group_name', 'groupName']),
        'activity_name': readString(record, ['activity_name', 'activityName']),
      };

  Future<Map<String, dynamic>> _listRecordPhotos(
      Map<String, dynamic> arguments) async {
    final view = await _requireSnapshot();
    final photos = _snapshotPhotos(view);
    final limit = readInt(arguments, ['limit'], 50).clamp(1, 200);
    final Map<int, Map<dynamic, dynamic>> records;
    if (arguments['record_id'] != null) {
      final recordId = _requireId(arguments['record_id'], 'record_id');
      final record = view.records
          .where((r) => readInt(r, ['id']) == recordId)
          .firstOrNull;
      if (record == null) {
        throw ToolException('record_id $recordId 不在最新快照里，请用 list_records 核对');
      }
      records = {recordId: record};
    } else {
      final member = readString(arguments, ['member']).trim();
      final from = readString(arguments, ['from']).trim();
      final to = readString(arguments, ['to']).trim();
      if (member.isEmpty && from.isEmpty && to.isEmpty) {
        throw ToolException('请给 record_id，或 member / from / to 之一来缩小范围');
      }
      records = {
        for (final r in view.searchRecords(
            from: from, to: to, member: member, limit: 100000))
          readInt(r, ['id']): r,
      };
    }
    final pending = {
      for (final edit in await store.chekiEditActions(status: 'pending'))
        if (edit['media_id'] != null) edit['media_id']: edit['id'],
    };
    final matched = [
      for (final photo in photos)
        if (records.containsKey(readInt(photo, ['record_id']))) photo,
    ];
    return {
      'count': matched.length,
      'returned': matched.length < limit ? matched.length : limit,
      'photos': [
        for (final photo in matched.take(limit))
          {
            'media_id': readInt(photo, ['media_id']),
            'record_id': readInt(photo, ['record_id']),
            'position': readInt(photo, ['position']),
            'sha1': readString(photo, ['sha1']),
            'media_type': readString(photo, ['media_type']),
            'created_at': readString(photo, ['created_at']),
            if (readString(photo, ['owner_person_name']).isNotEmpty)
              'owner_person_name': readString(photo, ['owner_person_name']),
            'record':
                _recordBrief(records[readInt(photo, ['record_id'])]!),
            if (pending[readInt(photo, ['media_id'])] != null)
              'pending_action_id': pending[readInt(photo, ['media_id'])],
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _queueEdit(
      String kind, Map<String, dynamic> payload) async {
    try {
      return await store.queueChekiEdit(kind, payload);
    } on FaceImageException catch (error) {
      throw ToolException(error.message);
    }
  }

  void _checkSha1(Map<String, dynamic> arguments, Map<String, dynamic> target) {
    final given = readString(arguments, ['sha1']).trim().toLowerCase();
    if (given.isNotEmpty && given != target['sha1']) {
      throw ToolException(
          '照片 #${target['media_id']} 的 sha1 是 ${target['sha1']}，和给的 $given 不一致；'
          '请用 list_record_photos 重新核对是哪一张');
    }
  }

  Future<Map<String, dynamic>> _deleteChekiPhoto(
      Map<String, dynamic> arguments) async {
    final mediaId = _requireId(arguments['media_id'], 'media_id');
    final target = _photoTarget(await _requireSnapshot(), mediaId);
    _checkSha1(arguments, target);
    final queued = await _queueEdit(kDeletePhotoActionKind, {
      'media_id': mediaId,
      'record_id': target['record_id'],
      'sha1': target['sha1'],
    });
    return {
      ...queued,
      'photo': target,
      'message': '已排队删除照片 #$mediaId（流水 #${target['record_id']} 第 '
          '${target['position']} 张），手机打开 OTA Counter 同步后才会删；尚未完成。'
          '结果用 list_cheki_edits 查。',
    };
  }

  Future<Map<String, dynamic>> _replaceChekiPhoto(
      Map<String, dynamic> arguments) async {
    final mediaId = _requireId(arguments['media_id'], 'media_id');
    final images = _chekiImageArguments(arguments, required: true);
    if (images.length != 1) {
      throw ToolException('替换一次只能给一张新照片');
    }
    final target = _photoTarget(await _requireSnapshot(), mediaId);
    _checkSha1(arguments, target);
    final staged = await _stageChekiImages(images);
    final Map<String, dynamic> queued;
    try {
      queued = await _queueEdit(kReplacePhotoActionKind, {
        'media_id': mediaId,
        'record_id': target['record_id'],
        'sha1': target['sha1'],
        'images': staged,
      });
    } catch (_) {
      await _deleteStaged(staged);
      rethrow;
    }
    return {
      ...queued,
      'photo': target,
      'message': '已排队把照片 #$mediaId 换成新图（位置和所属流水不变），'
          '手机打开 OTA Counter 同步后才会换；尚未完成。结果用 list_cheki_edits 查。',
    };
  }

  /// Tool argument → ledger field `edit_record` may change.
  static const Map<String, String> _editCountFields = {
    'three_inch': 'three_inch_count',
    'five_inch': 'five_inch_count',
    'unsigned_three_inch': 'unsigned_three_inch_count',
    'unsigned_five_inch': 'unsigned_five_inch_count',
    'group_cut': 'group_cut_count',
    'three_inch_shukudai': 'three_inch_shukudai_count',
    'five_inch_shukudai': 'five_inch_shukudai_count',
  };
  static const List<String> _editTextFields = [
    'note',
    'activity_name',
    'venue_name',
    'session_label',
  ];

  Future<Map<String, dynamic>> _editRecord(
      Map<String, dynamic> arguments) async {
    final recordId = _requireId(arguments['record_id'], 'record_id');
    final view = await _requireSnapshot();
    final record =
        view.records.where((r) => readInt(r, ['id']) == recordId).firstOrNull;
    if (record == null) {
      throw ToolException(
          'record_id $recordId 不在最新快照里（可能已删除，或 App 还没同步），请用 list_records 核对');
    }
    final requested = <String, Object>{};
    for (final entry in _editCountFields.entries) {
      final value = arguments[entry.key] ?? arguments[entry.value];
      if (value == null) continue;
      final number = value is num
          ? value
          : (value is String ? num.tryParse(value.trim()) : null);
      if (number == null || number != number.roundToDouble() || number < 0) {
        throw ToolException('${entry.key} 必须是不小于 0 的整数');
      }
      if (number > 999) throw ToolException('${entry.key} 不能超过 999');
      requested[entry.value] = number.toInt();
    }
    for (final field in _editTextFields) {
      final value = arguments[field];
      if (value == null) continue;
      if (value is! String) throw ToolException('$field 必须是字符串');
      if (value.length > 500) throw ToolException('$field 太长（最多 500 字）');
      requested[field] = value.trim();
    }
    if (requested.isEmpty) {
      throw ToolException('没有要改的内容：给出要改的张数（three_inch 等）或 note / '
          'activity_name / venue_name / session_label');
    }
    final type = recordType(record);
    if (type != 'counter' &&
        requested.keys.any(_editCountFields.containsValue)) {
      throw ToolException('流水 #$recordId 是${type == 'ticket' ? '门票' : '多人切'}，'
          '只能改单人切奇流水的张数；备注和活动信息可以改');
    }
    Object current(String field) => _editCountFields.containsValue(field)
        ? readInt(record, [field])
        : readString(record, [field]);
    final before = {for (final key in requested.keys) key: current(key)};
    final changes = {
      for (final entry in requested.entries)
        if (entry.value != before[entry.key]) entry.key: entry.value,
    };
    if (changes.isEmpty) {
      return {
        'status': 'unchanged',
        'record': _recordJson(record),
        'before': before,
        'message': '流水 #$recordId 已经是这些值，没有排队。',
      };
    }
    final expected = {for (final key in changes.keys) key: before[key]};
    final queued = await _queueEdit(kEditRecordActionKind, {
      'record_id': recordId,
      'changes': changes,
      'expected': expected,
    });
    return {
      ...queued,
      'record': _recordJson(record),
      'before': expected,
      'after': changes,
      'message': '已排队修改流水 #$recordId（${recordDisplayName(record)}，'
          '${recordDate(record)}），手机打开 OTA Counter 同步后才会改；尚未完成。'
          'before 是快照里的旧值，请核对；若手机上已被改过，App 不会覆盖并回报原因。'
          '结果用 list_cheki_edits 查。',
    };
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
    final images = _chekiImageArguments(arguments, required: false);

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
    if (images.isNotEmpty) {
      final staged = await _stageChekiImages(images);
      final Map<String, dynamic> queued;
      try {
        queued = await store.queueChekiPhotos({
          'counter_id': counterId,
          'person_id': personId,
          'person_name': personName,
          'member_name': memberName,
          'group_name': primaryGroup,
          'occurred_at': payload['occurred_at'],
          'activity_name': payload['activity_name'],
          'note': '',
          'images': staged,
        }, counterDelta: {
          'kind': 'counter_delta',
          'payload': payload,
          'created_by': 'mcp',
        });
      } catch (_) {
        await _deleteStaged(staged);
        rethrow;
      }
      return {
        'action_id': queued['record_action_id'],
        'status': 'pending',
        'kind': 'counter_delta',
        'photo_action_id': queued['action_id'],
        'image_count': staged.length,
        'member': {
          'member_id': counterId,
          'name': memberName,
          'group': primaryGroup,
        },
        'counts': counts,
        'occurred_at': payload['occurred_at'],
        'pending_actions': _pendingCount(await store.status()),
        'message': '已排队计数和 ${staged.length} 张照片，手机打开 OTA Counter 同步后生效；'
            '照片挂到这次生成的流水上，用 list_cheki_photos 查看结果。',
      };
    }
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

  static const Map<String, dynamic> _chekiImageProperties = {
    'images': {
      'type': 'array',
      'maxItems': 20,
      'description': '照片数组（最多 20 张）。每项是 {"image_base64": "..."}（JPEG/PNG，可带 '
          'data:image/...;base64, 前缀，≤8 MB 编码）或 {"image_url": "https://..."}（≤15 MB）',
      'items': {
        'type': 'object',
        'properties': {
          'image_base64': {'type': 'string'},
          'image_url': {'type': 'string'},
        },
        'additionalProperties': false,
      },
    },
    'image_base64': {
      'type': 'string',
      'description': '只有一张照片时可直接用：JPEG/PNG 的 base64',
    },
    'image_url': {
      'type': 'string',
      'description': '只有一张照片时可直接用：公开 HTTP(S) 图片地址',
    },
  };

  static const List<Map<String, dynamic>> _toolDefinitions = [
    {
      'name': 'attach_cheki_photos',
      'description': '把拍立得照片（扫描或切好的卡图）挂到 App 的切奇流水上，进「切册」显示；不改计数。'
          '先用 list_members 核对 member_id，再给 occurred_at（拍切日期）。'
          '挂到哪条流水：record_id（list_records 里的流水编号）> record_action_id（record_cheki 返回的 action_id）'
          '> 该成员当天的流水（有 activity_name 时优先同名活动）> 同成员同日还在排队的 record_cheki。'
          '要同时加计数，直接在 record_cheki 里带 images。App 入库时自动拉正、校正透视和减反光。'
          'App 同步后才会生效，只能回复「已排队」；结果用 list_cheki_photos 查。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'member_id': {
            'type': ['integer', 'string'],
            'description': '成员编号（list_members 的 member_id），优先使用',
          },
          'name': {'type': 'string', 'description': '成员名；重名时同时提供 group'},
          'group': {'type': 'string', 'description': '团名'},
          'occurred_at': {
            'type': 'string',
            'description': '拍切日期 YYYY-MM-DD（或 ISO 时间）；给了 record_id 时可省略',
          },
          'activity_name': {
            'type': 'string',
            'description': '活动名；当天有多条流水时用来挑同名活动那条',
          },
          'record_id': {
            'type': ['integer', 'string'],
            'description': '要挂的流水编号（list_records 返回的 id）',
          },
          'record_action_id': {
            'type': 'string',
            'description': '挂到某个已排队 record_cheki 生成的流水（填它返回的 action_id）',
          },
          'note': {'type': 'string'},
          ..._chekiImageProperties,
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_cheki_photos',
      'description': '查询切奇照片挂图的状态和 App 回执：pending 等待同步；applied 已入切册'
          '（attached_record_id、photos_saved、duplicates、media_ids 新照片编号；'
          'face_samples_added 是从照片里学到的该成员人脸样本数，排除主人后不是恰好一张脸的照片不学）；'
          'failed 带中文原因（failure）。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'status': {
            'type': 'string',
            'enum': ['pending', 'applied', 'failed'],
          },
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_record_photos',
      'description': '列出切册里已挂的照片，供删图、换图前确认是哪一张。'
          '每张有 media_id（照片编号）、record_id（所属流水）、position（在该流水里第几张，从 1 起）、'
          'sha1（照片字节的 SHA-1；通过 MCP 发的照片就是当时所发图片的 SHA-1）、created_at 和所属流水摘要。'
          '按 record_id，或 member / from / to 缩小范围。数据来自 App 最近一次同步的快照。'
          'attach_cheki_photos 成功后，list_cheki_photos 的 media_ids 也给出新照片的编号。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'record_id': {
            'type': ['integer', 'string'],
            'description': '流水编号（list_records 的 id）',
          },
          'member': {'type': 'string', 'description': '成员名、团名或活动名（模糊匹配）'},
          'from': {'type': 'string', 'description': '起始日期 YYYY-MM-DD'},
          'to': {'type': 'string', 'description': '截止日期 YYYY-MM-DD'},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
        },
        'additionalProperties': false,
      },
    },
    {
      'name': 'delete_cheki_photo',
      'description': '从切册里删除一张照片（不改计数）。先用 list_record_photos 确认 media_id；'
          '可带 sha1 防止删错。手机上该照片若已被换过，App 不删并回报原因。'
          'App 同步后才会生效，只能回复「已排队」；结果用 list_cheki_edits 查。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'media_id': {
            'type': ['integer', 'string'],
            'description': '照片编号（list_record_photos 的 media_id）',
          },
          'sha1': {'type': 'string', 'description': '可选：期望的照片 SHA-1，不一致就不排队'},
        },
        'required': ['media_id'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'replace_cheki_photo',
      'description': '把切册里的一张照片换成新图，原位替换：所属流水和在切册里的顺序不变。'
          '旧照片从这张图学到的人脸样本会一并撤掉，再从新图重新学。'
          '新图用 image_base64 或 image_url（也可 images 数组里只放一张）。'
          'App 同步后才会生效，只能回复「已排队」；结果用 list_cheki_edits 查。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'media_id': {
            'type': ['integer', 'string'],
            'description': '要被替换的照片编号（list_record_photos 的 media_id）',
          },
          'sha1': {'type': 'string', 'description': '可选：旧照片期望的 SHA-1，不一致就不排队'},
          ..._chekiImageProperties,
        },
        'required': ['media_id'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'edit_record',
      'description': '修改一条流水：张数、备注、活动信息。只传要改的字段；张数是改后的新值（不是增量）。'
          '张数只能改单人切奇流水（门票、多人切只能改备注和活动信息）；改张数会同步调整成员的累计数。'
          '返回 before（快照里的旧值）和 after，请核对。手机上这些字段若已被改过，App 不覆盖并回报原因。'
          'App 同步后才会生效，只能回复「已排队」；结果用 list_cheki_edits 查。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'record_id': {
            'type': ['integer', 'string'],
            'description': '流水编号（list_records 的 id）',
          },
          'three_inch': {'type': 'integer', 'minimum': 0, 'description': '三寸（签名）'},
          'five_inch': {'type': 'integer', 'minimum': 0, 'description': '五寸（签名）'},
          'unsigned_three_inch': {'type': 'integer', 'minimum': 0, 'description': '三寸未签'},
          'unsigned_five_inch': {'type': 'integer', 'minimum': 0, 'description': '五寸未签'},
          'group_cut': {'type': 'integer', 'minimum': 0, 'description': '团切'},
          'three_inch_shukudai': {'type': 'integer', 'minimum': 0, 'description': '三寸宿题'},
          'five_inch_shukudai': {'type': 'integer', 'minimum': 0, 'description': '五寸宿题'},
          'note': {'type': 'string', 'description': '备注（整段替换；空字符串清空）'},
          'activity_name': {'type': 'string', 'description': '活动名'},
          'venue_name': {'type': 'string', 'description': '场地'},
          'session_label': {'type': 'string', 'description': '场次'},
        },
        'required': ['record_id'],
        'additionalProperties': false,
      },
    },
    {
      'name': 'list_cheki_edits',
      'description': '查询删图、换图、改流水的状态和 App 回执：pending 等待同步（attempts / last_error 是重试情况）；'
          'applied 已完成（result 里有 before / after 或 deleted / replaced）；failed 带中文原因（failure）。',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'status': {
            'type': 'string',
            'enum': ['pending', 'applied', 'failed'],
          },
          'record_id': {'type': ['integer', 'string']},
          'media_id': {'type': ['integer', 'string']},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
        },
        'additionalProperties': false,
      },
    },
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
              'additive and never negative. Optional images (images / '
              'image_base64 / image_url) are attached to the record this '
              'change creates and shown in 切册; check them with '
              'list_cheki_photos.',
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
          ..._chekiImageProperties,
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
