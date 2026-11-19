import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum AlbumCameraAccessStatus { full, limited, denied }

/// Only for cross-photo recovery. Ordinary album imports and previews do not
/// need to check or request this permission.
class AlbumCameraAccess {
  static const _channel = MethodChannel('ota_counter/album_camera_sources');
  static const accessRequiredCode = 'camera_access_required';

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Recheck Android's current access without showing any permission dialog.
  static Future<AlbumCameraAccessStatus> check() => _read('accessStatus');

  /// Only call from an explicit user action.
  static Future<AlbumCameraAccessStatus> request() => _read('requestAccess');

  static Future<AlbumCameraAccessStatus> _read(String method) async {
    if (!isSupported) return AlbumCameraAccessStatus.denied;
    return switch (await _channel.invokeMethod<String>(method)) {
      'full' => AlbumCameraAccessStatus.full,
      'limited' => AlbumCameraAccessStatus.limited,
      _ => AlbumCameraAccessStatus.denied,
    };
  }
}
