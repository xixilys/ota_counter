import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/album_camera_access.dart';

/// Place this only where cross-photo recovery has work to do.
class AlbumCameraAccessBanner extends StatefulWidget {
  const AlbumCameraAccessBanner({super.key, required this.onGranted});

  /// Runs once per transition to full access after a request or settings change.
  final VoidCallback onGranted;

  @override
  State<AlbumCameraAccessBanner> createState() =>
      _AlbumCameraAccessBannerState();
}

class _AlbumCameraAccessBannerState extends State<AlbumCameraAccessBanner> {
  AppLifecycleListener? _lifecycle;
  AlbumCameraAccessStatus? _status;
  bool _requesting = false;
  bool _showSettings = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!AlbumCameraAccess.isSupported) return;
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_requesting) return;
    final AlbumCameraAccessStatus status;
    try {
      status = await AlbumCameraAccess.check();
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    if (!mounted || _requesting) return;
    final granted = _status != null &&
        _status != AlbumCameraAccessStatus.full &&
        status == AlbumCameraAccessStatus.full;
    setState(() => _status = status);
    if (granted) widget.onGranted();
  }

  Future<void> _request() async {
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      final status = await AlbumCameraAccess.request();
      if (!mounted) return;
      setState(() {
        _status = status;
        _showSettings = status != AlbumCameraAccessStatus.full;
      });
    } on PlatformException {
      if (mounted) setState(() => _error = '暂时无法申请照片权限，请重试。');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
    if (mounted && _status == AlbumCameraAccessStatus.full) widget.onGranted();
  }

  Future<void> _openSettings() async {
    try {
      if (await openAppSettings()) return;
    } on PlatformException {
      // Keep the banner so the user can try again.
    }
    if (mounted) setState(() => _error = '无法打开设置，请在系统中打开应用权限。');
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (!AlbumCameraAccess.isSupported ||
        status == null ||
        status == AlbumCameraAccessStatus.full) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final message = status == AlbumCameraAccessStatus.limited
        ? '目前只能读取选中的照片。允许读取全部照片后，切册才能从相机原拍自动补全切图。'
        : '允许读取全部照片后，切册才能从相机原拍自动补全切图。';
    return Material(
      color: colors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('从相机原拍补全切图', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(message, style: theme.textTheme.bodyMedium),
            if (_error case final error?)
              Text(error, style: TextStyle(color: colors.error)),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: _requesting
                    ? null
                    : _showSettings
                        ? _openSettings
                        : _request,
                child: Text(_showSettings ? '去系统设置' : '授权读取照片'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
