enum ActivityRecordMediaType {
  scan,
  memory;

  String get dbValue => switch (this) {
        ActivityRecordMediaType.scan => 'scan',
        ActivityRecordMediaType.memory => 'memory',
      };

  String get label => switch (this) {
        ActivityRecordMediaType.scan => '切图',
        ActivityRecordMediaType.memory => '纪念照',
      };

  int get sortPriority => switch (this) {
        ActivityRecordMediaType.scan => 0,
        ActivityRecordMediaType.memory => 1,
      };

  static ActivityRecordMediaType fromDb(String value) {
    return switch (value) {
      'scan' => ActivityRecordMediaType.scan,
      _ => ActivityRecordMediaType.memory,
    };
  }
}

enum ActivityRecordMediaProcessingMode {
  none,
  nativeScanner,
  manualAssist,
  antiGlareBasic,
  antiGlareFusion;

  String get dbValue => switch (this) {
        ActivityRecordMediaProcessingMode.none => 'none',
        ActivityRecordMediaProcessingMode.nativeScanner => 'native_scanner',
        ActivityRecordMediaProcessingMode.manualAssist => 'manual_assist',
        ActivityRecordMediaProcessingMode.antiGlareBasic => 'anti_glare_basic',
        ActivityRecordMediaProcessingMode.antiGlareFusion =>
          'anti_glare_fusion',
      };

  String get label => switch (this) {
        ActivityRecordMediaProcessingMode.none => '原图',
        ActivityRecordMediaProcessingMode.nativeScanner => '原生扫描',
        ActivityRecordMediaProcessingMode.manualAssist => '手动框选',
        ActivityRecordMediaProcessingMode.antiGlareBasic => '简单防反光',
        ActivityRecordMediaProcessingMode.antiGlareFusion => '多张防反光',
      };

  bool get isProcessed => this != ActivityRecordMediaProcessingMode.none;

  static ActivityRecordMediaProcessingMode fromDb(String value) {
    return switch (value) {
      'native_scanner' => ActivityRecordMediaProcessingMode.nativeScanner,
      'manual_assist' => ActivityRecordMediaProcessingMode.manualAssist,
      'anti_glare_basic' => ActivityRecordMediaProcessingMode.antiGlareBasic,
      'anti_glare_fusion' => ActivityRecordMediaProcessingMode.antiGlareFusion,
      _ => ActivityRecordMediaProcessingMode.none,
    };
  }
}

class ActivityRecordMediaModel {
  final int? id;
  final int recordId;
  final String path;
  final DateTime createdAt;
  final ActivityRecordMediaType mediaType;
  final ActivityRecordMediaProcessingMode processingMode;
  final bool isReversed;
  final int? ownerPersonId;
  final String ownerPersonName;
  final String ownerGroupName;

  /// When the original photo was taken (camera shutter / EXIF
  /// DateTimeOriginal). Null when unknown or not recorded.
  final DateTime? capturedAt;

  /// sha1 of the original photo the crop came from; guards against importing
  /// the same original twice. Empty when not recorded.
  final String sourceHash;

  /// Crop corners in the (EXIF-upright) original, JSON of RecordScanQuad
  /// fields. Empty when not recorded.
  final String cropQuadJson;

  const ActivityRecordMediaModel({
    this.id,
    required this.recordId,
    required this.path,
    required this.createdAt,
    this.mediaType = ActivityRecordMediaType.memory,
    this.processingMode = ActivityRecordMediaProcessingMode.none,
    this.isReversed = false,
    this.ownerPersonId,
    this.ownerPersonName = '',
    this.ownerGroupName = '',
    this.capturedAt,
    this.sourceHash = '',
    this.cropQuadJson = '',
  });

  bool get isScan => mediaType == ActivityRecordMediaType.scan;

  bool get hasOwnerScope =>
      ownerPersonId != null ||
      ownerPersonName.trim().isNotEmpty ||
      ownerGroupName.trim().isNotEmpty;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'record_id': recordId,
      'path': path,
      'created_at': createdAt.toIso8601String(),
      'media_type': mediaType.dbValue,
      'processing_mode': processingMode.dbValue,
      'is_reversed': isReversed ? 1 : 0,
      'owner_person_id': ownerPersonId,
      'owner_person_name': ownerPersonName,
      'owner_group_name': ownerGroupName,
      'captured_at': capturedAt?.toIso8601String(),
      'source_hash': sourceHash,
      'crop_quad_json': cropQuadJson,
    };
  }

  factory ActivityRecordMediaModel.fromMap(Map<String, Object?> map) {
    return ActivityRecordMediaModel(
      id: (map['id'] as num?)?.toInt(),
      recordId: (map['record_id'] as num?)?.toInt() ?? 0,
      path: (map['path'] ?? '') as String,
      createdAt: DateTime.tryParse((map['created_at'] ?? '') as String) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      mediaType: ActivityRecordMediaType.fromDb(
        (map['media_type'] ?? 'memory') as String,
      ),
      processingMode: ActivityRecordMediaProcessingMode.fromDb(
        (map['processing_mode'] ?? 'none') as String,
      ),
      isReversed: ((map['is_reversed'] as num?)?.toInt() ?? 0) == 1,
      ownerPersonId: (map['owner_person_id'] as num?)?.toInt(),
      ownerPersonName: (map['owner_person_name'] ?? '') as String,
      ownerGroupName: (map['owner_group_name'] ?? '') as String,
      capturedAt: DateTime.tryParse(
        '${map['captured_at'] ?? map['capturedAt'] ?? ''}',
      ),
      sourceHash: '${map['source_hash'] ?? map['sourceHash'] ?? ''}',
      cropQuadJson: '${map['crop_quad_json'] ?? map['cropQuadJson'] ?? ''}',
    );
  }

  ActivityRecordMediaModel copyWith({
    int? id,
    int? recordId,
    String? path,
    DateTime? createdAt,
    ActivityRecordMediaType? mediaType,
    ActivityRecordMediaProcessingMode? processingMode,
    bool? isReversed,
    int? ownerPersonId,
    String? ownerPersonName,
    String? ownerGroupName,
    DateTime? capturedAt,
    String? sourceHash,
    String? cropQuadJson,
  }) {
    return ActivityRecordMediaModel(
      id: id ?? this.id,
      recordId: recordId ?? this.recordId,
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
      mediaType: mediaType ?? this.mediaType,
      processingMode: processingMode ?? this.processingMode,
      isReversed: isReversed ?? this.isReversed,
      ownerPersonId: ownerPersonId ?? this.ownerPersonId,
      ownerPersonName: ownerPersonName ?? this.ownerPersonName,
      ownerGroupName: ownerGroupName ?? this.ownerGroupName,
      capturedAt: capturedAt ?? this.capturedAt,
      sourceHash: sourceHash ?? this.sourceHash,
      cropQuadJson: cropQuadJson ?? this.cropQuadJson,
    );
  }
}

class ActivityRecordMediaOwnerScope {
  final int? personId;
  final String personName;
  final String groupName;

  const ActivityRecordMediaOwnerScope({
    this.personId,
    required this.personName,
    required this.groupName,
  });
}
