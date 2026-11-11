// ignore_for_file: avoid_relative_lib_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/http_transport.dart';
import '../lib/stdio_transport.dart';
import '../lib/store.dart';

Future<void> main(List<String> args) async {
  late final _Options options;
  try {
    options = _Options.parse(args);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_helpText);
    exitCode = 2;
    return;
  }
  if (options.showHelp || options.command == 'help') {
    stdout.writeln(_helpText);
    return;
  }
  if (options.showVersion) {
    stdout.writeln('$kSyncServerName $kSyncServerVersion');
    return;
  }

  final store =
      SyncStore(options.dataDir, publicBaseUrl: options.publicBaseUrl);
  final token = await SyncConfig.loadOrCreateToken(options.dataDir);
  final explicitToken = options.token?.trim() ?? '';
  final effectiveToken = explicitToken.isEmpty ? token : explicitToken;
  if (explicitToken.isNotEmpty) {
    await SyncConfig.writeToken(options.dataDir, effectiveToken);
  }

  switch (options.command) {
    case 'token':
      stdout.writeln(effectiveToken);
      return;
    case 'status':
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(await store.status()),
      );
      return;
    case 'import':
      final path = options.importPath;
      if (path == null || path.trim().isEmpty) {
        stderr.writeln('import needs a JSON file path');
        exitCode = 2;
        return;
      }
      final file = File(path);
      if (!await file.exists()) {
        stderr.writeln('File not found: $path');
        exitCode = 2;
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      final snapshot = decoded is Map && decoded['snapshot'] is Map
          ? Map<String, dynamic>.from(decoded['snapshot'] as Map)
          : decoded is Map
              ? Map<String, dynamic>.from(decoded)
              : null;
      if (snapshot == null) {
        stderr.writeln('Expected a snapshot JSON object');
        exitCode = 2;
        return;
      }
      final status = await store.replaceSnapshot(
        snapshot,
        clientId: 'cli-import',
      );
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'ok': true,
          'rev': status['rev'],
          'snapshot': status['snapshot'],
        }),
      );
      return;
    case 'mcp':
      exitCode = await runStdioMcp(store);
      return;
    case 'serve':
      await _serve(store, effectiveToken, options);
      return;
    default:
      stderr.writeln('Unknown command: ${options.command}');
      stderr.writeln(_helpText);
      exitCode = 2;
  }
}

Future<void> _serve(
  SyncStore store,
  String token,
  _Options options,
) async {
  final server = SyncHttpServer(
    store: store,
    token: token,
    host: options.host,
    port: options.port,
  );
  try {
    await server.start();
  } catch (error) {
    stderr
        .writeln('Failed to listen on ${options.host}:${options.port}: $error');
    exitCode = 1;
    return;
  }

  final port = server.actualPort;
  final base = 'http://${options.host}:$port';
  stdout.writeln('OTA Counter Sync $kSyncServerVersion');
  stdout.writeln('Data dir : ${options.dataDir}');
  stdout.writeln('REST     : $base/api/v1/status');
  stdout.writeln('MCP HTTP : $base/mcp');
  stdout.writeln('MCP SSE  : $base/sse');
  stdout.writeln('');
  stdout.writeln('App sync URL: ${_appUrl(options.host, port)}');
  if (options.host == '127.0.0.1' || options.host == 'localhost') {
    stdout.writeln(
      'Tip: bind with --host 0.0.0.0 to reach this server from a phone on LAN.',
    );
  } else {
    final lan = await _lanAddresses(port);
    if (lan.isNotEmpty) {
      stdout.writeln('LAN URLs:');
      for (final address in lan) {
        stdout.writeln('  $address');
      }
    }
  }
  stdout.writeln('');
  stdout.writeln('MCP stdio config:');
  stdout.writeln(jsonEncode({
    'mcpServers': {
      'ota-counter': {
        'command': 'dart',
        'args': [
          '${Directory.current.path}/mcp_server/bin/ota_sync_server.dart',
          'mcp',
          '--data-dir',
          options.dataDir,
        ],
      },
    },
  }));
  stdout.writeln('');
  stdout.writeln('Press Ctrl+C to stop.');

  final stop = Completer<void>();
  ProcessSignal.sigint.watch().listen((_) async {
    if (!stop.isCompleted) stop.complete();
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    if (!stop.isCompleted) stop.complete();
  });
  await stop.future;
  await server.close();
}

String _appUrl(String host, int port) {
  if (host == '0.0.0.0' || host == '::') {
    return 'http://<this-machine-lan-ip>:$port';
  }
  if (host == '::1') {
    return 'http://127.0.0.1:$port';
  }
  return 'http://$host:$port';
}

Future<List<String>> _lanAddresses(int port) async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final result = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        result.add('http://${address.address}:$port');
      }
    }
    return result;
  } catch (_) {
    return const [];
  }
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

class _Options {
  _Options({
    required this.command,
    required this.dataDir,
    required this.host,
    required this.port,
    this.token,
    this.publicBaseUrl,
    this.importPath,
    this.showHelp = false,
    this.showVersion = false,
  });

  final String command;
  final String dataDir;
  final String host;
  final int port;
  final String? token;
  final String? publicBaseUrl;
  final String? importPath;
  final bool showHelp;
  final bool showVersion;

  static _Options parse(List<String> args) {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.current.path;
    var command = 'serve';
    var dataDir =
        Platform.environment['OTA_SYNC_DATA_DIR'] ?? '$home/.ota_counter_sync';
    var host = _nonEmpty(Platform.environment['OTA_SYNC_HOST']) ?? '127.0.0.1';
    var port =
        int.tryParse(Platform.environment['OTA_SYNC_PORT'] ?? '') ?? 8787;
    var publicBaseUrl =
        _nonEmpty(Platform.environment['OTA_SYNC_PUBLIC_BASE_URL']);
    var token = _nonEmpty(Platform.environment['OTA_SYNC_TOKEN']);
    var help = false;
    var version = false;
    var importPath = _nonEmpty(Platform.environment['OTA_SYNC_IMPORT']);
    var sawCommand = false;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String nextValue(String option) {
        if (i + 1 >= args.length) {
          throw FormatException('$option needs a value');
        }
        i += 1;
        return args[i];
      }

      if (arg == '--help' || arg == '-h') {
        help = true;
      } else if (arg == '--version' || arg == '-v') {
        version = true;
      } else if (arg == '--data-dir') {
        dataDir = nextValue(arg);
      } else if (arg.startsWith('--data-dir=')) {
        dataDir = arg.substring('--data-dir='.length);
      } else if (arg == '--host') {
        host = nextValue(arg);
      } else if (arg.startsWith('--host=')) {
        host = arg.substring('--host='.length);
      } else if (arg == '--port') {
        port = int.parse(nextValue(arg));
      } else if (arg.startsWith('--port=')) {
        port = int.parse(arg.substring('--port='.length));
      } else if (arg == '--public-base-url') {
        publicBaseUrl = nextValue(arg);
      } else if (arg.startsWith('--public-base-url=')) {
        publicBaseUrl = arg.substring('--public-base-url='.length);
      } else if (arg == '--token') {
        token = nextValue(arg);
      } else if (arg.startsWith('--token=')) {
        token = arg.substring('--token='.length);
      } else if (arg.startsWith('-')) {
        throw FormatException('Unknown option: $arg');
      } else if (!sawCommand) {
        command = arg;
        sawCommand = true;
      } else if (command == 'import' && importPath == null) {
        importPath = arg;
      } else {
        throw FormatException('Unexpected argument: $arg');
      }
    }

    return _Options(
      command: command,
      dataDir: dataDir,
      host: host,
      port: port,
      token: token,
      publicBaseUrl: publicBaseUrl,
      importPath: importPath,
      showHelp: help,
      showVersion: version,
    );
  }
}

const String _helpText = '''
OTA Counter Sync $kSyncServerVersion

Usage:
  dart run mcp_server/bin/ota_sync_server.dart [command] [options]

Commands:
  serve                 Run the HTTP bridge (default)
  mcp                   Run the stdio MCP server
  status                Print snapshot / action status as JSON
  token                 Print the bearer token (creates one if needed)
  import <file.json>    Import an app snapshot JSON file
  help                  Show this help

Options:
  --data-dir <path>     Default: ~/.ota_counter_sync
  --host <host>         Default: 127.0.0.1 (use 0.0.0.0 for LAN)
  --port <port>         Default: 8787
  --token <token>       Override and persist the bearer token
  --public-base-url <url>  Public origin + proxy prefix (or OTA_SYNC_PUBLIC_BASE_URL); no auto-detection
  --help, --version

Examples:
  dart run mcp_server/bin/ota_sync_server.dart serve --host 0.0.0.0
  dart run mcp_server/bin/ota_sync_server.dart mcp
  dart run mcp_server/bin/ota_sync_server.dart token
''';
