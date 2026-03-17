import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/counter_model.dart';

enum ImportPayloadKind {
  legacyCounters,
  otaBundle,
}

class ImportPayload {
  final ImportPayloadKind kind;
  final String fileName;
  final String rawJson;
  final List<CounterModel> counters;

  const ImportPayload({
    required this.kind,
    required this.fileName,
    required this.rawJson,
    this.counters = const [],
  });

  bool get isLegacyCounters => kind == ImportPayloadKind.legacyCounters;
  bool get isOtaBundle => kind == ImportPayloadKind.otaBundle;
}

class ExportImportService {
  static Future<void> exportData(List<CounterModel> counters) async {
    final data = counters.map((counter) => counter.toMap()).toList();
    final jsonStr = jsonEncode(data);

    final tempDir = await getTemporaryDirectory();
    final fileName = 'counters_${DateTime.now().millisecondsSinceEpoch}.txt';
    final tempFile = File('${tempDir.path}/$fileName');
    await tempFile.writeAsString(jsonStr);

    await Share.shareXFiles(
      [XFile(tempFile.path)],
      subject: '计数器数据导出',
    );

    await tempFile.delete();
  }

  static Future<ImportPayload?> pickImportPayload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'json'],
      dialogTitle: '选择要导入的文件',
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      return null;
    }

    final file = result.files.first;
    final path = file.path;
    final rawJson = file.bytes != null
        ? utf8.decode(file.bytes!, allowMalformed: true)
        : path != null
            ? await File(path).readAsString()
            : '';

    return _parseImportPayload(
      fileName: file.name,
      rawJson: rawJson,
    );
  }

  static ImportPayload _parseImportPayload({
    required String fileName,
    required String rawJson,
  }) {
    final sanitized = rawJson.replaceFirst('\ufeff', '').trim();
    if (sanitized.isEmpty) {
      throw const FormatException('导入文件为空');
    }

    final decoded = jsonDecode(sanitized);
    final counters = _tryParseLegacyCounters(decoded);
    if (counters != null) {
      return ImportPayload(
        kind: ImportPayloadKind.legacyCounters,
        fileName: fileName,
        rawJson: sanitized,
        counters: counters,
      );
    }

    if (_looksLikeOtaBundle(decoded) || _looksLikeOtaRecordList(decoded)) {
      return ImportPayload(
        kind: ImportPayloadKind.otaBundle,
        fileName: fileName,
        rawJson: sanitized,
      );
    }

    throw const FormatException('文件格式错误：当前仅支持旧版计数器备份或 OTA 历史导出文件');
  }

  static List<CounterModel>? _tryParseLegacyCounters(Object? decoded) {
    if (decoded is! List) {
      return null;
    }
    if (decoded.isEmpty) {
      return <CounterModel>[];
    }

    final counters = <CounterModel>[];
    for (final item in decoded) {
      if (item is! Map) {
        return null;
      }

      final mapped = item.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (_looksLikeOtaRecordMap(mapped)) {
        return null;
      }

      final counter = CounterModel.fromMap(mapped);
      if (counter.name.trim().isEmpty) {
        return null;
      }
      counters.add(counter);
    }
    return counters;
  }

  static bool _looksLikeOtaBundle(Object? decoded) {
    if (decoded is! Map) {
      return false;
    }

    return decoded.containsKey('records') ||
        decoded.containsKey('groups') ||
        decoded.containsKey('idols');
  }

  static bool _looksLikeOtaRecordList(Object? decoded) {
    if (decoded is! List || decoded.isEmpty) {
      return false;
    }

    return decoded.whereType<Map>().any((item) => _looksLikeOtaRecordMap(item));
  }

  static bool _looksLikeOtaRecordMap(Map<dynamic, dynamic> map) {
    final keys = map.keys.map((key) => key.toString()).toSet();
    return keys.contains('cutType') ||
        keys.contains('qty') ||
        keys.contains('ts') ||
        keys.contains('idol') ||
        keys.contains('finalAmount');
  }
}
