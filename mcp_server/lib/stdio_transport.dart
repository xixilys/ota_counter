import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_protocol.dart';
import 'store.dart';

/// Newline-delimited JSON-RPC over stdio, the transport expected by most
/// desktop MCP clients (Claude Desktop, Grok, Hermes, etc.).
Future<int> runStdioMcp(SyncStore store) async {
  final protocol = McpProtocol(store);
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    Object? input;
    try {
      input = jsonDecode(trimmed);
    } catch (_) {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      }));
      await stdout.flush();
      continue;
    }
    final response = await protocol.handle(input);
    if (response != null) {
      stdout.writeln(jsonEncode(response));
      await stdout.flush();
    }
  }
  return 0;
}
