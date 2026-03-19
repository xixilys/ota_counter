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

  const ActivityRecordMediaModel({
    this.id,
    required this.recordId,
    required this.path,
    required this.createdAt,
    this.mediaType = ActivityRecordMediaType.memory,
    this.processingMode = ActivityRecordMediaProcessingMode.none,
  });

  bool get isScan => mediaType == ActivityRecordMediaType.scan;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'record_id': recordId,
      'path': path,
      'created_at': createdAt.toIso8601String(),
      'media_type': mediaType.dbValue,
      'processing_mode': processingMode.dbValue,
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
    );
  }
}
