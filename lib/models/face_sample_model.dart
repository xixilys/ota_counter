import 'dart:convert';
import 'dart:typed_data';

/// Where a face sample came from.
enum FaceSampleSource {
  /// "我" enrolled in 人脸识别 settings.
  self,

  /// 「从已归档照片学习」: the only non-self face on an archived photo whose
  /// owner is known.
  bootstrap,

  /// A face the user confirmed (or left as auto) when saving a batch.
  confirmed,

  /// A face explicitly selected in a member's 「登记人脸」 page.
  manual;

  String get dbValue => name;

  static FaceSampleSource fromDb(Object? value) {
    return switch ('${value ?? ''}') {
      'self' => FaceSampleSource.self,
      'bootstrap' => FaceSampleSource.bootstrap,
      'manual' => FaceSampleSource.manual,
      _ => FaceSampleSource.confirmed,
    };
  }
}

/// One stored face embedding (table `face_samples`). Private, on-device
/// only: never exported in backups.
class FaceSampleModel {
  final int? id;
  final int? personId;
  final String personName;
  final int? counterId;
  final bool isSelf;
  final int? mediaId;

  /// Face box in the analysed image ({x, y, width, height, score}).
  final String faceBoxJson;

  /// L2-normalised embedding (SFace: 128 floats).
  final Float32List embedding;
  final String modelId;

  /// Detector score of the face, 0–1.
  final double quality;
  final FaceSampleSource source;
  final DateTime createdAt;

  /// Identifies the recogniser that produced [embedding]. Samples from a
  /// different model are not comparable and are ignored.
  static const String currentModelId = 'sface_2021dec_int8';

  const FaceSampleModel({
    this.id,
    this.personId,
    this.personName = '',
    this.counterId,
    this.isSelf = false,
    this.mediaId,
    this.faceBoxJson = '{}',
    required this.embedding,
    this.modelId = currentModelId,
    this.quality = 0,
    required this.source,
    required this.createdAt,
  });

  static Uint8List encodeEmbedding(List<double> values) {
    final floats =
        values is Float32List ? values : Float32List.fromList(values);
    return Uint8List.fromList(
      floats.buffer.asUint8List(floats.offsetInBytes, floats.lengthInBytes),
    );
  }

  static Float32List decodeEmbedding(Object? blob) {
    if (blob is! Uint8List || blob.lengthInBytes % 4 != 0) {
      return Float32List(0);
    }
    // Copy: the blob may not be 4-byte aligned.
    final copy = Uint8List.fromList(blob);
    return copy.buffer.asFloat32List();
  }

  static String encodeFaceBox({
    required double x,
    required double y,
    required double width,
    required double height,
    double score = 0,
  }) =>
      jsonEncode({
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'score': score,
      });

  Map<String, Object?> toMap() => {
        'id': id,
        'person_id': personId,
        'person_name': personName,
        'counter_id': counterId,
        'is_self': isSelf ? 1 : 0,
        'media_id': mediaId,
        'face_box_json': faceBoxJson,
        'embedding': encodeEmbedding(embedding),
        'model_id': modelId,
        'quality': quality,
        'source': source.dbValue,
        'created_at': createdAt.toIso8601String(),
      };

  factory FaceSampleModel.fromMap(Map<String, Object?> map) {
    int? readInt(String a, String b) => ((map[a] ?? map[b]) as num?)?.toInt();
    return FaceSampleModel(
      id: readInt('id', 'id'),
      personId: readInt('person_id', 'personId'),
      personName: '${map['person_name'] ?? map['personName'] ?? ''}',
      counterId: readInt('counter_id', 'counterId'),
      isSelf: (readInt('is_self', 'isSelf') ?? 0) != 0,
      mediaId: readInt('media_id', 'mediaId'),
      faceBoxJson: '${map['face_box_json'] ?? map['faceBoxJson'] ?? '{}'}',
      embedding: decodeEmbedding(map['embedding']),
      modelId: '${map['model_id'] ?? map['modelId'] ?? currentModelId}',
      quality: ((map['quality'] as num?) ?? 0).toDouble(),
      source: FaceSampleSource.fromDb(map['source']),
      createdAt:
          DateTime.tryParse('${map['created_at'] ?? map['createdAt'] ?? ''}') ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
