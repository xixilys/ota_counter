import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/face_sample_model.dart';
import 'face_sample_service.dart';

/// 导出结果：文件路径、导出的样本条数、因模型/空向量被跳过的条数。
class FaceSampleExportResult {
  const FaceSampleExportResult({
    required this.path,
    required this.count,
    required this.skipped,
  });

  final String path;
  final int count;
  final int skipped;
}

/// 把 on-device 的 128 维 embedding 导出成一个本地 JSON 文件。
///
/// 不含人脸照片，不上传服务器；只有用户主动点击时才生成。
/// 导出格式与 `face_engine` 的 SFace int8 模型对齐，供本地/服务端用同一套
/// 余弦相似度比对。
class FaceSampleExportService {
  FaceSampleExportService._();

  static const String fileName = 'face_samples_export.json';

  /// 组装导出内容（不落盘）。App 内同步服务和本地导出共用同一份结构。
  static Future<Map<String, Object?>> buildPayload() async {
    final samples = await FaceSampleService.getSamples();
    final rows = <Map<String, Object?>>[];
    for (final sample in samples) {
      final embedding = sample.embedding;
      if (embedding.isEmpty ||
          sample.modelId != FaceSampleModel.currentModelId) {
        continue;
      }
      rows.add({
        'member_id': sample.counterId ?? sample.personId,
        'counter_id': sample.counterId,
        'person_id': sample.personId,
        'name': sample.personName,
        'is_self': sample.isSelf,
        'model_id': sample.modelId,
        'quality': sample.quality,
        'source': sample.source.dbValue,
        'created_at': sample.createdAt.toIso8601String(),
        'embedding': [
          for (final value in embedding) double.parse(value.toStringAsFixed(6)),
        ],
      });
    }
    return {
      'model_id': FaceSampleModel.currentModelId,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'samples': rows,
    };
  }

  static Future<FaceSampleExportResult> exportToJson({
    Directory? directory,
  }) async {
    final allSamples = await FaceSampleService.getSamples();
    final payload = await buildPayload();
    final rows = (payload['samples'] as List).cast<Map<String, Object?>>();
    final skipped = allSamples.length - rows.length;

    final targetDirectory =
        directory ?? await getApplicationDocumentsDirectory();
    final file = File('${targetDirectory.path}/$fileName');
    await file.writeAsString(
      const JsonEncoder.withIndent(' ').convert(payload),
    );

    return FaceSampleExportResult(
      path: file.path,
      count: rows.length,
      skipped: skipped < 0 ? 0 : skipped,
    );
  }
}
