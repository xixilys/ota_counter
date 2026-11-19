import 'package:flutter_test/flutter_test.dart';
import 'package:ota_counter/models/activity_record_media_model.dart';
import 'package:ota_counter/services/album_camera_recovery.dart';

void main() {
  test(
      'a hand-framed scan is queued by its camera day, but a memory photo and an already checked import are not',
      () {
    final day = DateTime(2026, 11, 12);
    final manual = ActivityRecordMediaModel(
        recordId: 1,
        path: 'old.jpg',
        createdAt: day,
        capturedAt: DateTime(2026, 11, 13, 1),
        mediaType: ActivityRecordMediaType.scan,
        processingMode: ActivityRecordMediaProcessingMode.manualAssist);
    expect(AlbumCameraRecovery.recoveryDay(manual, DateTime(2026, 10, 3)), day);
    expect(
        AlbumCameraRecovery.recoveryDay(
            manual.copyWith(mediaType: ActivityRecordMediaType.memory), day),
        isNull);
    expect(
        AlbumCameraRecovery.recoveryDay(
            manual.copyWith(cropQuadJson: '{"_checked_card_id":"verified"}'),
            day),
        isNull);
  });
}
