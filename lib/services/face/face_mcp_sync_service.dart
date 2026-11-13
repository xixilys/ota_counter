import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/activity_record_media_model.dart';
import '../database_service.dart';
import '../settings_service.dart';
import 'face_sample_export_service.dart';

/// Result of one sync to the local face MCP.
class FaceMcpSyncResult {
  const FaceMcpSyncResult({
    required this.ok,
    this.sent = 0,
    this.failed = 0,
    this.members,
    this.error,
  });

  final bool ok;
  final int sent;
  final int failed;
  final int? members;
  final String? error;

  String get summary {
    if (!ok) return '同步失败：${error ?? '未知原因'}';
    if (sent == 0) return '没有可同步的内容';
    return members == null ? '已同步 $sent 条' : '已同步 $sent 条 / $members 位成员';
  }
}

/// Talks to the Mac-side face MCP (`~/.ota-counter/face_mcp_server.py`).
///
/// Samples are 128-d SFace vectors only (no photos); photos are uploaded as
/// base64 and stored by the MCP for Hermes to classify.  Both calls are
/// explicit user actions; nothing is sent while the page loads unless the
/// user taps the buttons.
class FaceMcpSyncService {
  FaceMcpSyncService._();

  static const Duration _connectTimeout = Duration(seconds: 6);
  static const Duration _sampleTimeout = Duration(seconds: 30);
  static const Duration _photoTimeout = Duration(seconds: 60);

  static Future<({String url, String token})> _settings() async => (
        url: await SettingsService.getFaceMcpUrl(),
        token: await SettingsService.getFaceMcpToken(),
      );

  static Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> arguments, {
    required Duration timeout,
  }) async {
    final settings = await _settings();
    final uri = Uri.tryParse(settings.url.trim());
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('本机人脸库地址不正确');
    }
    if (settings.token.isEmpty) {
      throw const FormatException('还没有配置本机人脸库 token');
    }

    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': method, 'arguments': arguments},
    });
    final bytes = utf8.encode(body);
    final client = HttpClient()..connectionTimeout = _connectTimeout;
    try {
      final request = await client.postUrl(uri).timeout(_connectTimeout);
      // The MCP reads Content-Length; without it Dart sends a chunked body,
      // which used to arrive as an empty request and look like a bad method.
      request.contentLength = bytes.length;
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Authorization', 'Bearer ${settings.token}');
      request.add(bytes);
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('本机人脸库返回 HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      final error = decoded['error'];
      if (error is Map) {
        throw StateError('本机人脸库错误：${error['message'] ?? error}');
      }
      final content =
          ((decoded['result'] as Map?)?['content'] as List?)?.firstOrNull;
      final inner = content is Map ? content['text'] : null;
      if (inner is! String) {
        throw const FormatException('本机人脸库返回格式不正确');
      }
      final payload = jsonDecode(inner);
      if (payload is! Map<String, Object?>) {
        throw const FormatException('本机人脸库返回格式不正确');
      }
      if (payload['ok'] == false) {
        throw StateError('${payload['error'] ?? '本机人脸库拒绝了请求'}');
      }
      return payload;
    } finally {
      client.close(force: true);
    }
  }

  /// Push the on-device 128-d samples to the MCP.
  static Future<FaceMcpSyncResult> syncSamples() async {
    try {
      final payload = await FaceSampleExportService.buildPayload();
      final sent = (payload['samples'] as List).length;
      if (sent == 0) {
        return const FaceMcpSyncResult(ok: true, sent: 0);
      }
      final result = await _call(
        'import_face_samples',
        {'payload': payload},
        timeout: _sampleTimeout,
      );
      return FaceMcpSyncResult(
        ok: true,
        sent: sent,
        members: (result['members'] as num?)?.toInt(),
      );
    } catch (error) {
      return FaceMcpSyncResult(ok: false, error: '$error');
    }
  }

  /// Upload the app's cut polaroids (scan media) to the MCP album.
  ///
  /// The MCP needs local Mac paths for paths, so each photo travels as base64
  /// in its own request; [onProgress] reports completed/total photos.
  static Future<FaceMcpSyncResult> syncPhotos({
    void Function(int done, int total)? onProgress,
  }) async {
    final media = await DatabaseService.getActivityRecordMedia();
    final photos = media.where((item) => item.isScan).toList(growable: false);
    final total = photos.length;
    if (total == 0) {
      return const FaceMcpSyncResult(ok: true, sent: 0);
    }
    try {
      // Fail fast on a wrong URL/token instead of retrying every photo.
      await _call('face_sample_stats', const {}, timeout: _sampleTimeout);
    } catch (error) {
      return FaceMcpSyncResult(ok: false, error: '$error');
    }
    var sent = 0;
    var failed = 0;
    for (var i = 0; i < photos.length; i++) {
      final item = photos[i];
      onProgress?.call(i, total);
      try {
        final file = File(item.path);
        if (!await file.exists()) {
          failed += 1;
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > 15 * 1024 * 1024) {
          failed += 1;
          continue;
        }
        final result = await _call(
          'add_photos',
          {
            'photos': [
              {
                'name': _photoName(item),
                'image_base64': base64Encode(bytes),
              },
            ],
          },
          timeout: _photoTimeout,
        );
        if (result['ok'] == true && (result['count'] as num? ?? 0) > 0) {
          sent += 1;
        } else {
          failed += 1;
        }
      } catch (_) {
        failed += 1;
      }
    }
    onProgress?.call(total, total);
    return FaceMcpSyncResult(
      ok: failed == 0 || sent > 0,
      sent: sent,
      failed: failed,
      error: sent == 0 ? '一张照片都没有同步成功' : null,
    );
  }

  static String _photoName(ActivityRecordMediaModel item) {
    final base = item.path.split(Platform.pathSeparator).last;
    final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
    return 'cheki_${item.id ?? 'x'}_$stem.jpg';
  }
}
