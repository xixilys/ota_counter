import 'dart:convert';

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
  McpProtocol(this.store);

  final SyncStore store;

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
                  'snapshot age and pending actions.',
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
      case 'add_ticket':
        return _addTicket(arguments);
      case 'list_pending_actions':
        return _listPendingActions(arguments);
      case 'get_sync_status':
        return _getSyncStatus();
      default:
        throw ToolException('Unknown tool: $name');
    }
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
    final member = _findMember(view, arguments);
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
    final requestedGroup = readString(arguments, ['group']).trim();
    if (requestedGroup.isNotEmpty &&
        !member.groups.any(
          (value) => normalizePart(value) == normalizePart(requestedGroup),
        )) {
      throw ToolException(
        'Group "$requestedGroup" is not one of this member\'s groups: '
        '${member.groups.join(', ')}',
      );
    }
    final primaryGroup =
        requestedGroup.isNotEmpty ? requestedGroup : member.primaryGroup;
    final payload = {
      'counter_id': member.primaryCounterId,
      'person_id': member.personId,
      'person_name': member.name,
      'member_name': member.name,
      'group_name': primaryGroup,
      'occurred_at': occurredAt.toIso8601String(),
      'counts': counts,
      'note': readString(arguments, ['note']),
      'activity_name': readString(arguments, ['activity_name', 'activityName']),
      'venue_name': readString(arguments, ['venue_name', 'venueName']),
      'session_label': readString(arguments, ['session_label', 'sessionLabel']),
      'allow_create': arguments['allow_create'] == true,
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
        'member_id': member.primaryCounterId,
        'name': member.name,
        'group': primaryGroup,
      },
      'counts': counts,
      'occurred_at': payload['occurred_at'],
      'pending_actions': _pendingCount(await store.status()),
      'message':
          'Queued. Open OTA Counter → MCP 同步 → 一键同步 to apply it locally.',
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
    Map<String, dynamic> arguments,
  ) {
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
      throw ToolException(
        'No member matched "$name${group.isEmpty ? '' : ' / $group'}". '
        'Call list_members to see available names.',
      );
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
      'ticket_type':
          readString(record, ['ticket_type', 'ticketType']).trim(),
      'is_free': record['ticket_is_free'] == null
          ? (readDouble(record, ['ticket_unit_price', 'ticketUnitPrice']) <= 0 &&
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

  static const List<Map<String, dynamic>> _toolDefinitions = [
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
