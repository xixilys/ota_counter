import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_metadata.dart';

class AppUpdateInfo {
  final String versionName;
  final int versionCode;
  final String versionLabel;
  final String title;
  final List<String> notes;
  final String primaryUrl;
  final String downloadPageUrl;
  final String backupUrl;
  final bool force;

  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.versionLabel,
    required this.title,
    required this.notes,
    required this.primaryUrl,
    required this.downloadPageUrl,
    required this.backupUrl,
    required this.force,
  });

  bool get hasBackupUrl => backupUrl.trim().isNotEmpty;

  String get preferredOpenUrl {
    final pageUrl = downloadPageUrl.trim();
    if (pageUrl.isNotEmpty) {
      return pageUrl;
    }
    return primaryUrl;
  }

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final versionName = '${json['versionName'] ?? ''}'.trim();
    final versionCode = (json['versionCode'] as num?)?.toInt() ??
        int.tryParse('${json['versionCode'] ?? ''}') ??
        0;
    final versionLabel = '${json['versionLabel'] ?? ''}'.trim();
    final title = '${json['title'] ?? ''}'.trim();
    final notes = (json['notes'] as List<dynamic>? ?? const <dynamic>[])
        .map((item) => '$item'.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);

    return AppUpdateInfo(
      versionName: versionName,
      versionCode: versionCode,
      versionLabel: versionLabel.isEmpty && versionName.isNotEmpty
          ? 'v$versionName'
          : versionLabel,
      title: title.isEmpty && versionName.isNotEmpty
          ? 'OTA Counter v$versionName'
          : title,
      notes: notes,
      primaryUrl: '${json['primaryUrl'] ?? ''}'.trim(),
      downloadPageUrl: '${json['downloadPageUrl'] ?? ''}'.trim(),
      backupUrl: '${json['backupUrl'] ?? ''}'.trim(),
      force: json['force'] == true,
    );
  }
}

class UpdateService {
  static Future<AppUpdateInfo?> fetchLatestRelease({
    String manifestUrl = kUpdateManifestUrl,
  }) async {
    final uri = Uri.tryParse(manifestUrl);
    if (uri == null) {
      throw const FormatException('更新地址无效');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response =
          await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('更新清单请求失败: ${response.statusCode}', uri: uri);
      }

      final body = await utf8.decodeStream(response);
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('更新清单格式不正确');
      }

      final info = AppUpdateInfo.fromJson(decoded);
      if (info.versionCode <= 0 || info.preferredOpenUrl.trim().isEmpty) {
        throw const FormatException('更新清单缺少必要字段');
      }
      return info;
    } finally {
      client.close(force: true);
    }
  }
}
