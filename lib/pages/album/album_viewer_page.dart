import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../../services/album_clarity_service.dart';
import 'album_format.dart';
import 'album_models.dart';
import 'album_widgets.dart';

/// Full-screen cheki viewer: pinch-to-zoom, horizontal swipe between the
/// photos of the current view, hero from the tapped print, and a small
/// paper-style info panel (member / date / 场次 / spec).
class AlbumViewerPage extends StatefulWidget {
  final List<AlbumPhoto> photos;
  final int initialIndex;

  const AlbumViewerPage({
    super.key,
    required this.photos,
    this.initialIndex = 0,
  });

  @override
  State<AlbumViewerPage> createState() => _AlbumViewerPageState();
}

class _AlbumViewerPageState extends State<AlbumViewerPage> {
  late final PageController _pageController;
  late int _index;
  bool _chromeVisible = true;
  final _clarityService = AlbumClarityService();
  bool _clarity = true;
  bool _preparing = false;
  bool _failed = false;
  bool _comparing = false;
  AlbumClarityImage? _prepared;
  final _photoSizes = <int, Size>{};
  final _cropZoom =
      <int, (PhotoViewController, PhotoViewScaleStateController)>{};
  final _sizeErrors = <int>{};
  final _sizeLoads = <int, (ImageStream, ImageStreamListener)>{};
  late final StreamSubscription<String> _rescans;
  Timer? _prepareTimer;
  int _generation = 0;

  AlbumPhoto get _photo => widget.photos[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.photos.length - 1);
    _pageController = PageController(initialPage: _index);
    _rescans = AlbumPhotoFiles.rescanned.listen((path) {
      if (mounted && _clarity && _photo.path == path) _prepareCurrent();
    });
    _prepareCurrent();
  }

  @override
  void dispose() {
    _rescans.cancel();
    _prepareTimer?.cancel();
    _clarityService.dispose();
    for (final (stream, listener) in _sizeLoads.values) {
      stream.removeListener(listener);
    }
    for (final (zoom, scale) in _cropZoom.values) {
      zoom.dispose();
      scale.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  void _resetCropZoom(int index) {
    final controls = _cropZoom[index];
    if (controls == null) return;
    controls.$1.reset();
    // Reset writes through PhotoView's listener with the old bounds first.
    // Keep the next layout in the initial scale state for the new geometry.
    controls.$2.setInvisibly(PhotoViewScaleState.initial);
  }

  void _prepareCurrent({bool afterSwipe = false, bool fromOriginal = false}) {
    _prepareTimer?.cancel();
    _clarityService.cancelPending();
    final generation = ++_generation;
    final photo = _photo;
    setState(() {
      _prepared = null;
      _preparing = _clarity;
      _failed = false;
      _comparing = fromOriginal;
    });
    if (!_clarity) return;
    _prepareTimer =
        Timer(Duration(milliseconds: afterSwipe ? 150 : 0), () async {
      try {
        final provider = await _clarityService.prepare(photo.path,
            rectifyCut: photo.canAutoRectify, isScan: photo.isScan);
        if (!mounted || generation != _generation || provider == null) return;
        // Decode/upload before switching providers. Never flash the old
        // crooked frame while its optimized rendition is loading.
        Object? error;
        await precacheImage(provider, context, onError: (e, _) => error = e);
        if (!mounted || generation != _generation) return;
        if (error != null) throw error!;
        if (provider.rectified) _resetCropZoom(_index);
        setState(() {
          _prepared = provider;
          _preparing = false;
        });
      } catch (_) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _preparing = false;
          _failed = true;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这张照片暂时无法增强，已显示原色；下一张继续清晰')));
      }
    });
  }

  void _toggleClarity() {
    if (_prepared?.rectified == true) _resetCropZoom(_index);
    _clarity = !_clarity;
    _prepareCurrent(fromOriginal: _clarity);
  }

  // Read dimensions from the same FileImage stream used to show the original.
  // Both modes keep this logical canvas: a 2560px preview must not change zoom,
  // pan or PhotoView's in-flight rebound animation on a 4000px original.
  void _resolvePhotoSize(int index) {
    if (_photoSizes.containsKey(index) ||
        _sizeErrors.contains(index) ||
        _sizeLoads.containsKey(index)) {
      return;
    }
    final stream = FileImage(File(widget.photos[index].path))
        .resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    void finished({bool hasFrame = false}) {
      void detach() {
        stream.removeListener(listener);
        _sizeLoads.remove(index);
      }

      if (!hasFrame) detach();
      // A cached stream can notify synchronously from the gallery builder.
      scheduleMicrotask(() {
        if (!mounted) return;
        setState(() {});
        // Keep oversized originals live until Image attaches in this frame;
        // they may be too large for Flutter's persistent image cache.
        if (hasFrame) {
          WidgetsBinding.instance.addPostFrameCallback((_) => detach());
        }
      });
    }

    listener = ImageStreamListener((info, _) {
      _photoSizes[index] =
          Size(info.image.width.toDouble(), info.image.height.toDouble());
      info.dispose();
      finished(hasFrame: true);
    }, onError: (Object _, StackTrace? __) {
      _sizeErrors.add(index);
      finished();
    });
    _sizeLoads[index] = (stream, listener);
    stream.addListener(listener);
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final rectified = _prepared?.rectified == true;
    Widget chrome(Widget child) => AnimatedOpacity(
          opacity: _chromeVisible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          child: IgnorePointer(ignoring: !_chromeVisible, child: child),
        );
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomMultiChildLayout(
        delegate: _ViewerLayout(avoidOverlay: _chromeVisible),
        children: [
          LayoutId(
            id: _ViewerPart.photo,
            child: PhotoViewGallery.builder(
              pageController: _pageController,
              itemCount: widget.photos.length,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              scrollPhysics: const BouncingScrollPhysics(),
              onPageChanged: (index) {
                if (rectified) _resetCropZoom(_index);
                setState(() => _index = index);
                _prepareCurrent(afterSwipe: true);
              },
              loadingBuilder: (context, progress) => const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              ),
              builder: (context, index) {
                final pagePhoto = widget.photos[index];
                // Off-screen pages must not reveal unprocessed originals
                // during swipes in default mode.
                final showOriginal = !_clarity ||
                    (index == _index &&
                        (_failed || (_comparing && _preparing)));
                final prepared = index == _index &&
                        _clarity &&
                        _prepared?.sourcePath == pagePhoto.path
                    ? _prepared
                    : null;
                if (showOriginal || (prepared != null && !prepared.rectified)) {
                  _resolvePhotoSize(index);
                }
                final originalSize = showOriginal || prepared != null
                    ? _photoSizes[index]
                    : null;
                // Keep the exact original zoom canvas for clarity-only changes.
                // A real perspective crop has a different aspect ratio.
                final size = prepared != null && prepared.rectified
                    ? Size(
                        prepared.width.toDouble(), prepared.height.toDouble())
                    : originalSize;
                final ImageProvider provider =
                    prepared ?? FileImage(File(pagePhoto.path));
                final zoom = pagePhoto.isScan || pagePhoto.canAutoRectify
                    ? _cropZoom.putIfAbsent(
                        index,
                        () => (
                          PhotoViewController(),
                          PhotoViewScaleStateController()
                        ),
                      )
                    : null;
                return PhotoViewGalleryPageOptions.customChild(
                  childSize: size,
                  controller: zoom?.$1,
                  scaleStateController: zoom?.$2,
                  disableGestures: size == null,
                  child: _sizeErrors.contains(index)
                      ? const _MissingPhoto()
                      : size == null
                          ? const Center(
                              child: CircularProgressIndicator(
                                  color: Colors.white70, strokeWidth: 2))
                          : Image(
                              key: ValueKey(pagePhoto.path),
                              image: provider,
                              width: size.width,
                              height: size.height,
                              fit: BoxFit.contain,
                              gaplessPlayback: false,
                              filterQuality: FilterQuality.medium,
                              semanticLabel:
                                  '${pagePhoto.memberCaption}，${albumDayTitle(pagePhoto.activityDay)}',
                              errorBuilder: (_, __, ___) =>
                                  const _MissingPhoto(),
                            ),
                  heroAttributes:
                      PhotoViewHeroAttributes(tag: pagePhoto.heroTag),
                  minScale: PhotoViewComputedScale.contained,
                  initialScale: PhotoViewComputedScale.contained,
                  maxScale: PhotoViewComputedScale.covered * 2.4,
                  // CustomChild is transformed as a fixed logical canvas; the
                  // Image above performs the actual texture filtering.
                  filterQuality: FilterQuality.none,
                  onTapUp: (context, details, value) => _toggleChrome(),
                );
              },
            ),
          ),
          LayoutId(
            id: _ViewerPart.header,
            child: chrome(_ViewerControls(
              index: _index,
              count: widget.photos.length,
              onClose: () => Navigator.of(context).maybePop(),
              clarity: _clarity,
              preparing: _preparing,
              failed: _failed,
              onToggleClarity: _toggleClarity,
            )),
          ),
          LayoutId(
            id: _ViewerPart.details,
            child: chrome(_ViewerDetails(photo: photo, rectified: rectified)),
          ),
        ],
      ),
    );
  }
}

enum _ViewerPart { photo, header, details }

/// Measure the actual overlay (including wrapping and system insets). Leave
/// the entire fitted photo visible between the controls and the caption.
class _ViewerLayout extends MultiChildLayoutDelegate {
  final bool avoidOverlay;
  _ViewerLayout({required this.avoidOverlay});

  @override
  void performLayout(Size size) {
    final edge = BoxConstraints.tightFor(width: size.width);
    final header = layoutChild(_ViewerPart.header, edge).height;
    final details = layoutChild(_ViewerPart.details, edge).height;
    final available = size.height - header - details;
    final reserve = avoidOverlay && available > 0;
    layoutChild(
        _ViewerPart.photo,
        BoxConstraints.tightFor(
            width: size.width, height: reserve ? available : size.height));
    positionChild(_ViewerPart.photo, Offset(0, reserve ? header : 0));
    positionChild(_ViewerPart.header, Offset.zero);
    positionChild(_ViewerPart.details, Offset(0, size.height - details));
  }

  @override
  bool shouldRelayout(_ViewerLayout oldDelegate) =>
      oldDelegate.avoidOverlay != avoidOverlay;
}

class _ViewerControls extends StatelessWidget {
  final int index;
  final int count;
  final VoidCallback onClose;
  final bool clarity, preparing, failed;
  final VoidCallback onToggleClarity;

  const _ViewerControls({
    required this.index,
    required this.count,
    required this.onClose,
    required this.clarity,
    required this.preparing,
    required this.failed,
    required this.onToggleClarity,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 12, 24),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            _RoundIconButton(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              onPressed: onClose,
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: onToggleClarity,
              style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor:
                      clarity ? const Color(0xFF55436F) : Colors.white12),
              icon: Icon(clarity ? Icons.auto_fix_high : Icons.image_outlined,
                  size: 18),
              label: Text(failed
                  ? '原色 · 未增强'
                  : clarity
                      ? (preparing ? '清晰处理中' : '清晰')
                      : '原色'),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${index + 1} / $count',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewerDetails extends StatelessWidget {
  final AlbumPhoto photo;
  final bool rectified;
  const _ViewerDetails({required this.photo, required this.rectified});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent =
        albumAccent(photo.primaryMember?.colorHex ?? '', Brightness.dark);
    final memberNames = photo.members.isEmpty
        ? '未归属'
        : photo.members.map((member) => member.displayName).join(' / ');
    final sessionLine = photo.sessionTitle;
    final placeLine = photo.sessionSubtitle;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black, Colors.black54, Colors.transparent],
          stops: [0, 0.72, 1],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 36, 16, 8),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    memberNames,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${albumDayTitle(photo.activityDay)} · '
                  '${photo.dateFromPhoto ? '拍摄日' : '流水日'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              sessionLine,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (placeLine.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                placeLine,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                  fontSize: 11.5,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (photo.specLabel.isNotEmpty)
                  _InfoChip(
                    icon: Icons.photo_size_select_actual_outlined,
                    label: photo.specLabel,
                  ),
                _InfoChip(
                  icon: photo.isScan
                      ? Icons.document_scanner_outlined
                      : Icons.photo_library_outlined,
                  label: rectified
                      ? '${photo.mediaLabel} · 已校正'
                      : photo.processingLabel.trim().isEmpty
                          ? photo.mediaLabel
                          : '${photo.mediaLabel} · ${photo.processingLabel}',
                ),
                if (photo.isGroup)
                  _InfoChip(
                    icon: Icons.groups_2_outlined,
                    label: '同框 ${photo.members.length} 人',
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '双指缩放 · 左右滑动切换',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white38,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white70),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.14),
        foregroundColor: Colors.white,
        minimumSize: const Size(42, 42),
        padding: EdgeInsets.zero,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon, size: 21),
    );
  }
}

class _MissingPhoto extends StatelessWidget {
  const _MissingPhoto();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        width: 220,
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 24),
        decoration: BoxDecoration(
          color: const Color(0xFF221E25),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 34,
            ),
            const SizedBox(height: 10),
            Text(
              '照片文件找不到了',
              style: theme.textTheme.titleSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '文件可能被清理或从备份恢复时缺失。记录仍在，可以重新存一张。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white54,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
