import 'dart:convert';
import 'dart:typed_data';

import '../../models/counter_model.dart';
import '../../models/face_sample_model.dart';
import '../database_service.dart';
import 'face_models.dart';
import 'face_recognition_rules.dart';
import 'face_sample_service.dart';

/// The server confirms that the uploaded image no longer exists.
class FaceEnrollmentImageNotFound implements Exception {
  const FaceEnrollmentImageNotFound();
}

class FaceEnrollmentResult {
  final Map<String, dynamic>? summary;
  final String? failure;
  final bool replayed;
  final bool retryable;

  const FaceEnrollmentResult(
      {this.summary,
      this.failure,
      this.replayed = false,
      this.retryable = false});
}

/// Applies only chat face-enrollment actions. Original images stay in memory;
/// durable receipts and samples commit atomically before the server is ACKed.
class FaceEnrollmentSyncService {
  static Future<FaceEnrollmentResult> apply({
    required String serverUrl,
    required String actionId,
    required Map<String, dynamic> payload,
    required List<CounterModel> counters,
    required Future<Uint8List> Function(String imageId) fetchImage,
  }) async {
    final db = await DatabaseService.database;
    final whereArgs = [serverUrl, actionId];
    const where = 'server_url = ? AND action_id = ?';
    FaceEnrollmentResult readReceipt(Map<String, Object?> row) =>
        FaceEnrollmentResult(
          summary: row['result_json'] == null
              ? null
              : Map<String, dynamic>.from(
                  jsonDecode(row['result_json'] as String) as Map),
          failure: row['failure'] as String?,
          replayed: true,
        );
    final previous = await db.query(
        DatabaseService.faceEnrollmentActionsTableName,
        where: where,
        whereArgs: whereArgs);
    if (previous.isNotEmpty) return readReceipt(previous.single);

    FaceSampleModel? sample;
    Map<String, dynamic>? summary;
    String? failure;
    List<FaceAnalysis>? analyzed;
    Uint8List? imageBytes;
    try {
      final member = _resolveMember(counters, payload);
      final imageId = payload['imageId'];
      if (imageId is! String || imageId.trim().isEmpty) {
        throw const FormatException('登记操作缺少有效的照片编号');
      }
      Uint8List bytes;
      try {
        bytes = await fetchImage(imageId);
      } on FaceEnrollmentImageNotFound {
        throw const FormatException('登记照片下载失败，请重新发送照片');
      } catch (_) {
        // No terminal receipt or ACK: the server must retain the original
        // image until a later sync can download and enroll it successfully.
        return const FaceEnrollmentResult(
          failure: '登记照片暂时无法下载，已保留待处理，下次同步将重试',
          retryable: true,
        );
      }
      imageBytes = bytes;
      List<FaceAnalysis> faces;
      try {
        faces = await FaceSampleService.analyzer(bytes);
      } on FormatException {
        throw const FormatException('无法解码照片，请换一张有效照片');
      } catch (_) {
        // Model session initialization resets itself on failure. Keep the
        // action/image pending so a later sync can initialize and try again.
        return const FaceEnrollmentResult(
          failure: '人脸识别暂时不可用，已保留待处理，请稍后同步重试',
          retryable: true,
        );
      }
      analyzed = faces;
      final selfSamples = [
        for (final s in await FaceSampleService.getSamples(isSelf: true))
          s.embedding,
      ];
      final memberSamples = [
        for (final s in await FaceSampleService.getMemberSamples(member))
          s.embedding,
      ];
      final selector = _faceSelector(payload);
      final leftOrder = FaceSampleService.faceOrderFromLeft(faces);
      final selected = FaceSampleService.selectEnrollmentFace(
        faces,
        face: selector,
        selfSamples: selfSamples,
        memberSamples: memberSamples,
      );
      if (selected == null) {
        final nonSelf = FaceSampleService.memberFaces(faces, selfSamples);
        if (faces.isEmpty) {
          throw const FormatException('照片中未检测到人脸，请换一张清晰照片');
        }
        if (selector.startsWith('left_')) {
          throw FormatException(
              '照片中只有 ${faces.length} 张脸，无法选择 $selector，请按 faces 的 index_from_left 重试');
        }
        if (nonSelf.isEmpty) {
          throw const FormatException('照片中未找到非「我」的人脸，请换一张成员照片');
        }
        throw const FormatException(
            '照片中有多张人脸，无法确定成员，请发送成员单人照、用 face: left_N 选择，或在 App 中手动登记');
      }
      if (isSelfFace(faces[selected].embedding, selfSamples)) {
        final selectedLabel = selector.startsWith('left_')
            ? '第 ${leftOrder.indexOf(selected) + 1} 张脸'
            : '选中的脸';
        throw FormatException('$selectedLabel被识别为「我」，请换一张成员照片或选择其他 left_N');
      }
      sample = FaceSampleService.sampleFromAnalysis(faces[selected],
          source: FaceSampleSource.manual, owner: member);
      summary = {
        'faces_found': faces.length,
        // One-based index from left, matching the faces feedback numbering.
        'used_face': leftOrder.indexOf(selected) + 1,
        'used_face_bounds': {
          'x': faces[selected].face.x,
          'y': faces[selected].face.y,
          'width': faces[selected].face.width,
          'height': faces[selected].face.height,
        },
        'counter_id': member.counterId,
        'person_id': member.personId,
      };
    } on FormatException catch (error) {
      failure = error.message;
    } catch (_) {
      failure = '人脸登记失败，请稍后重新发送照片';
    }

    if (failure != null) {
      summary = await _failureSummary(
        analyzed,
        imageBytes,
        personId: _readPersonId(payload),
      );
    }

    return db.transaction((txn) async {
      // Overlapping manual/automatic syncs can both have fetched the same image.
      final previous = await txn.query(
          DatabaseService.faceEnrollmentActionsTableName,
          where: where,
          whereArgs: whereArgs);
      if (previous.isNotEmpty) return readReceipt(previous.single);
      if (sample != null) {
        summary!['samples_kept'] =
            await FaceSampleService.addSamples([sample], transaction: txn);
      }
      await txn.insert(DatabaseService.faceEnrollmentActionsTableName, {
        'server_url': serverUrl,
        'action_id': actionId,
        'result_json': summary == null ? null : jsonEncode(summary),
        'failure': failure,
      });
      return FaceEnrollmentResult(summary: summary, failure: failure);
    });
  }

  static String _faceSelector(Map<String, dynamic> payload) {
    final raw = payload['face'];
    if (raw == null || (raw is String && raw.trim().isEmpty)) return 'auto';
    if (raw is! String) {
      throw const FormatException('人脸选择参数无效，请使用 auto、largest 或 left_N');
    }
    final value = raw.trim().toLowerCase();
    if (value == 'auto' || value == 'largest') return value;
    final match = RegExp(r'^left_(\d+)$').firstMatch(value);
    final index = match == null ? null : int.tryParse(match.group(1)!);
    if (index != null && index >= 1 && index <= 50) {
      return 'left_$index';
    }
    throw const FormatException('人脸选择参数无效，请使用 auto、largest 或 left_N');
  }

  static int? _readPersonId(Map<String, dynamic> payload) {
    final value = payload['person_id'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }

  static Future<Map<String, dynamic>> _failureSummary(
    List<FaceAnalysis>? faces,
    Uint8List? bytes, {
    int? personId,
  }) async {
    final list = faces ?? const <FaceAnalysis>[];
    List<Map<String, dynamic>> feedback = const [];
    if (list.isNotEmpty) {
      var width = 0;
      var height = 0;
      if (bytes != null) {
        try {
          final size = await FaceSampleService.imageSize(bytes);
          width = size.width;
          height = size.height;
        } catch (_) {
          // Fall back to the detected extents below.
        }
      }
      if (width <= 0 || height <= 0) {
        for (final face in list) {
          final right = face.face.x + face.face.width;
          final bottom = face.face.y + face.face.height;
          if (right > width) width = right.ceil();
          if (bottom > height) height = bottom.ceil();
        }
      }
      final order = FaceSampleService.faceOrderFromLeft(list);
      feedback = [
        for (var i = 0; i < order.length; i++)
          {
            'index_from_left': i + 1,
            'box': _normalizedBox(list[order[i]].face, width, height),
          }
      ];
    }
    return {
      'faces_found': list.length,
      'used_face': null,
      'samples_kept': 0,
      'faces': feedback,
      if (personId != null) 'person_id': personId,
    };
  }

  static Map<String, double> _normalizedBox(
      FaceDetection face, int width, int height) {
    double clamp(double value) =>
        value.isNaN ? 0 : value.clamp(0.0, 1.0).toDouble();
    if (width <= 0 || height <= 0) {
      return {'x': 0, 'y': 0, 'width': 0, 'height': 0};
    }
    return {
      'x': clamp(face.x / width),
      'y': clamp(face.y / height),
      'width': clamp(face.width / width),
      'height': clamp(face.height / height),
    };
  }

  static FaceMember _resolveMember(
      List<CounterModel> counters, Map<String, dynamic> payload) {
    int? id(String key) {
      final value = payload[key];
      if (value == null) return null;
      final parsed = value is int ? value : int.tryParse('$value');
      if (parsed == null || parsed <= 0) {
        throw const FormatException('登记操作的成员编号无效');
      }
      return parsed;
    }

    String text(String key) {
      final value = payload[key];
      if (value == null) return '';
      if (value is! String) throw const FormatException('登记操作的成员信息无效');
      return value.trim();
    }

    final counterId = id('counter_id');
    final personId = id('person_id');
    final name = text('member_name');
    final personName = text('person_name');
    final group = text('group_name');
    final matches = counters.where((c) {
      if (counterId != null) return c.id == counterId;
      if (personId != null) return c.personId == personId;
      return (name.isNotEmpty && c.name.trim() == name ||
              personName.isNotEmpty && c.personName.trim() == personName) &&
          (group.isEmpty || c.groupName.trim() == group);
    }).toList();
    if (matches.isEmpty) {
      throw const FormatException('本地找不到这位成员，请先在 App 里创建卡片');
    }
    if (personId != null && matches.any((c) => c.personId != personId)) {
      throw const FormatException('成员编号与真人身份不一致，请重新选择成员');
    }
    // Aliases of one explicit person share face samples; names alone must be unique.
    if (matches.length > 1 && personId == null) {
      throw const FormatException('有多位同名成员，请指定成员编号或团体');
    }
    return FaceSampleService.memberFromCounter(matches.first);
  }
}
