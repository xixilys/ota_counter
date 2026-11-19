import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../theme/app_theme.dart';
import '../../models/album_preferences.dart';
import '../../services/album_clarity_service.dart';
import 'album_format.dart';
import 'album_models.dart';

// ---------------------------------------------------------------------------
// Colour helpers

Color albumRawAccent(String hex, Brightness brightness) {
  final normalized = hex.trim().toUpperCase();
  if (normalized.startsWith('#') && normalized.length == 7) {
    try {
      return Color(int.parse('FF${normalized.substring(1)}', radix: 16));
    } catch (_) {
      // fall through to the default
    }
  }
  return AppTheme.sakura;
}

/// Member colour used for text printed on a cheki frame (captions, the date
/// line, the small accent line). The frame is cream in both themes now, so the
/// accent is darkened until it reaches WCAG AA against it, in dark mode too.
Color albumAccent(String hex, Brightness brightness, {Color? paper}) {
  final raw = albumRawAccent(hex, brightness);
  var color = AppTheme.readableAccent(raw, brightness);
  final background = paper ?? AppTheme.polaroid(brightness);
  for (var i = 0; i < 32 && albumContrastRatio(color, background) < 4.5; i++) {
    final hsl = HSLColor.fromColor(color);
    color =
        hsl.withLightness((hsl.lightness - 0.025).clamp(0.0, 1.0)).toColor();
  }
  return color;
}

/// Member colour used on a page/card surface (chips, count lines, section
/// titles). In dark mode [AppTheme.readableAccent] lightens it, which is what
/// keeps it readable on a dark surface; the cream-print darkening above is not
/// appropriate here.
Color albumSurfaceAccent(String hex, Brightness brightness) {
  var color =
      AppTheme.readableAccent(albumRawAccent(hex, brightness), brightness);
  final background = brightness == Brightness.dark
      ? const Color(0xFF1A1722)
      : const Color(0xFFFFFFFF);
  final step = brightness == Brightness.dark ? 0.02 : -0.02;
  for (var i = 0; i < 32 && albumContrastRatio(color, background) < 4.5; i++) {
    final hsl = HSLColor.fromColor(color);
    color = hsl.withLightness((hsl.lightness + step).clamp(0.0, 1.0)).toColor();
  }
  return color;
}

/// WCAG 2.1 relative-luminance contrast ratio (1..21).
double albumContrastRatio(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

/// Ink printed on a cream cheki frame. Theme `onSurfaceVariant` is light in
/// dark mode, which would disappear on the cream print, so this stays a
/// readable warm grey in both themes.
Color albumPrintInk(Brightness brightness) => const Color(0xFF5B5147);

Color _onAccent(Color color) =>
    ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : const Color(0xFF241A13);

// ---------------------------------------------------------------------------
// The polaroid print. Every photo in the album — grid tile, cover, viewer
// thumbnail — is wrapped in the same white frame so the page reads as a stack
// of prints rather than a dashboard of image tiles.

class AlbumPhotoTile extends StatefulWidget {
  final AlbumPhoto photo;
  final VoidCallback onTap;
  final bool showSpec;
  final AlbumPrintStyle printStyle;
  final BoxFit fit;

  /// Decode bound for the print. Small mosaic prints pass a smaller number so
  /// a wall of cheki never keeps full-size bitmaps in the image cache.
  final int cacheWidth;

  const AlbumPhotoTile({
    super.key,
    required this.photo,
    required this.onTap,
    this.showSpec = false,
    this.printStyle = AlbumPrintStyle.classic,
    this.fit = BoxFit.cover,
    this.cacheWidth = 420,
  });

  @override
  State<AlbumPhotoTile> createState() => _AlbumPhotoTileState();

  Widget _buildPrint(BuildContext context, Future<AlbumPhotoFile?>? rendition) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final primary = photo.primaryMember;
    final paper =
        albumCaptionPaper(primary?.colorHex ?? '', brightness, printStyle);
    final accent =
        albumAccent(primary?.colorHex ?? '', brightness, paper: paper);
    final badge = _photoBadge();

    return Semantics(
      button: true,
      label: '${photo.memberCaption}，${albumDayTitle(photo.activityDay)}，'
          '${photo.specLabel}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                    alpha: brightness == Brightness.dark ? 0.34 : 0.10),
                blurRadius: 7,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(5, 5, 5, 0),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2.5),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AlbumPhotoThumb(
                        photo: photo,
                        rendition: rendition,
                        cacheWidth: cacheWidth,
                        fit: fit,
                        hero: true,
                      ),
                      if (badge != null)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: badge,
                        ),
                    ],
                  ),
                ),
              ),
              AlbumPrintCaption(
                style: printStyle,
                colorHexes:
                    photo.members.map((member) => member.colorHex).toList(),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(1, 4, 1, 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        photo.memberCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: photo.members.isEmpty
                              ? albumPrintInk(brightness)
                              : accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        showSpec
                            ? '${photo.dayCaption} · ${photo.specLabel}'
                            : photo.dayCaption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: albumPrintInk(brightness),
                          fontSize: 9,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _photoBadge() {
    if (photo.isGroup) {
      return _MiniPrintBadge(
        label: '同框',
        background: const Color(0xFF2E2740),
        foreground: Colors.white,
      );
    }
    if (!photo.isScan) {
      return const _MiniPrintBadge(
        label: '纪念',
        background: Color(0xFFFFE7A8),
        foreground: Color(0xFF5B4211),
      );
    }
    return null;
  }
}

class _AlbumPhotoTileState extends State<AlbumPhotoTile> {
  Future<AlbumPhotoFile?>? _rendition;
  late final StreamSubscription<String> _rescans;

  Future<AlbumPhotoFile?>? _prepare() {
    final photo = widget.photo;
    if (!photo.isScan) return null;
    return AlbumPhotoFiles.prepare(photo.path,
        rectifyCut: photo.canAutoRectify, isScan: true);
  }

  @override
  void initState() {
    super.initState();
    _rendition = _prepare();
    _rescans = AlbumPhotoFiles.rescanned.listen((path) {
      if (mounted && widget.photo.path == path) {
        setState(() {
          _rendition = _prepare();
        });
      }
    });
  }

  @override
  void dispose() {
    _rescans.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(AlbumPhotoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final a = oldWidget.photo, b = widget.photo;
    if (a.path != b.path ||
        a.isScan != b.isScan ||
        a.canAutoRectify != b.canAutoRectify) {
      _rendition = _prepare();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rendition = _rendition;
    final print = widget._buildPrint(context, rendition);
    if (rendition == null) return print;
    return FutureBuilder<AlbumPhotoFile?>(
      future: rendition,
      builder: (context, snapshot) {
        final photo = snapshot.data;
        if (photo == null || photo.width / photo.height <= .72) return print;
        return LayoutBuilder(
          builder: (context, space) {
            // Slot sizes stay fixed for the month jump. Only shorten the
            // paper inside it, keeping all of the image and its signature.
            final paperHeight =
                (space.maxWidth - 10) * photo.height / photo.width + 41;
            if (!space.hasBoundedWidth || paperHeight >= space.maxHeight) {
              return print;
            }
            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: space.maxWidth,
                height: paperHeight,
                child: print,
              ),
            );
          },
        );
      },
    );
  }
}

/// A printed paper band only in the existing 36dp caption, never on photos.
Color albumCaptionPaper(
        String hex, Brightness brightness, AlbumPrintStyle style) =>
    style == AlbumPrintStyle.classic
        ? AppTheme.polaroid(brightness)
        : Color.alphaBlend(
            albumRawAccent(hex, brightness).withValues(alpha: 0.12),
            AppTheme.polaroid(brightness));

class AlbumPrintCaption extends StatelessWidget {
  final AlbumPrintStyle style;
  final List<String> colorHexes;
  final Widget child;
  const AlbumPrintCaption(
      {super.key,
      required this.style,
      required this.colorHexes,
      required this.child});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final hexes = colorHexes.isEmpty ? [''] : colorHexes;
    return SizedBox(
        height: 36,
        child: ColoredBox(
          color: albumCaptionPaper(hexes.first, brightness, style),
          child: CustomPaint(
            foregroundPainter: style == AlbumPrintStyle.supporter
                ? _SupporterEdgePainter(hexes
                    .map((hex) => albumRawAccent(hex, brightness))
                    .toList())
                : null,
            child:
                SizedBox(width: double.infinity, child: Center(child: child)),
          ),
        ));
  }
}

class _SupporterEdgePainter extends CustomPainter {
  final List<Color> colors;
  _SupporterEdgePainter(this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    // Two pixels already reserved by caption padding: keep all ink off text.
    final paint = Paint();
    for (var i = 0; i < colors.length; i++) {
      paint.color = colors[i];
      canvas.drawRect(
          Rect.fromLTRB(size.width * i / colors.length, size.height - 2,
              size.width * (i + 1) / colors.length, size.height),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SupporterEdgePainter oldDelegate) =>
      !listEquals(oldDelegate.colors, colors);
}

class _MiniPrintBadge extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const _MiniPrintBadge({
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// Small lazy thumbnail. Decoding is bounded by [cacheWidth] so a grid of
/// hundreds of full-resolution cheki never decodes originals on the UI thread.
class AlbumPhotoThumb extends StatefulWidget {
  final AlbumPhoto photo;
  final int cacheWidth;
  final Future<AlbumPhotoFile?>? rendition;
  final BoxFit fit;
  final bool hero;

  const AlbumPhotoThumb({
    super.key,
    required this.photo,
    this.rendition,
    this.cacheWidth = 420,
    this.fit = BoxFit.cover,
    this.hero = false,
  });

  @override
  State<AlbumPhotoThumb> createState() => _AlbumPhotoThumbState();
}

class _AlbumPhotoThumbState extends State<AlbumPhotoThumb> {
  late final StreamSubscription<String> _rescans;

  @override
  void initState() {
    super.initState();
    _rescans = AlbumPhotoFiles.rescanned.listen((path) {
      if (mounted && widget.rendition == null && widget.photo.path == path) {
        setState(() {
          _file = _prepare();
        });
      }
    });
  }

  @override
  void dispose() {
    _rescans.cancel();
    super.dispose();
  }

  late Future<AlbumPhotoFile?> _file = _prepare();

  Future<AlbumPhotoFile?> _prepare() =>
      widget.rendition ??
      AlbumPhotoFiles.prepare(
        widget.photo.path,
        rectifyCut: widget.photo.canAutoRectify,
        isScan: widget.photo.isScan,
      );

  @override
  void didUpdateWidget(AlbumPhotoThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rendition != widget.rendition ||
        oldWidget.photo.path != widget.photo.path ||
        oldWidget.photo.canAutoRectify != widget.photo.canAutoRectify ||
        oldWidget.photo.isScan != widget.photo.isScan) {
      _file = _prepare();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = FutureBuilder<AlbumPhotoFile?>(
      future: _file,
      builder: (context, snapshot) {
        final placeholder = ColoredBox(
          color: scheme.surfaceContainerHigh,
          child: const SizedBox.expand(),
        );
        if (snapshot.connectionState != ConnectionState.done) {
          return placeholder;
        }
        return Image.file(
          snapshot.data?.thumbnail ?? File(widget.photo.path),
          // Never trim a signed paper edge to fill a tile.
          fit: widget.photo.isScan ? BoxFit.contain : widget.fit,
          cacheWidth: widget.cacheWidth,
          filterQuality: FilterQuality.medium,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
              wasSynchronouslyLoaded || frame != null ? child : placeholder,
          errorBuilder: (context, error, stackTrace) => ColoredBox(
            color: scheme.surfaceContainerHigh,
            child: Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
    if (!widget.hero) return image;
    return Hero(tag: widget.photo.heroTag, child: image);
  }
}

// ---------------------------------------------------------------------------
// Timeline section headers

class AlbumMonthHeader extends StatelessWidget {
  final AlbumMonth month;

  const AlbumMonthHeader({super.key, required this.month});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final accent = AppTheme.readableAccent(scheme.secondary, brightness);
    return ColoredBox(
      color: AppTheme.paper(brightness),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _WashiTape(
                    width: 24,
                    height: 9,
                    color: accent.withValues(alpha: 0.48),
                    angle: -0.05,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${month.month.month}月',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 21,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      '${month.month.year}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  _StickerBadge(
                    label: albumCountLabel(month.count),
                    accent: accent,
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            color: scheme.outlineVariant.withValues(alpha: 0.65),
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }
}

class AlbumDayHeader extends StatelessWidget {
  final DateTime? day;
  final int count;
  final bool undated;

  const AlbumDayHeader({
    super.key,
    required this.day,
    required this.count,
    this.undated = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final accent = AppTheme.readableAccent(scheme.secondary, brightness);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 14,
            height: 3,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              undated ? '日期不明' : albumDayTitle(day),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                fontSize: 13,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            undated ? '没有拍到日期' : albumWeekday(day!),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 10,
              height: 1.1,
            ),
          ),
          const Spacer(),
          Text(
            albumCountLabel(count),
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 10,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

class AlbumUndatedHeader extends StatelessWidget {
  final int count;

  const AlbumUndatedHeader({super.key, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final accent = AppTheme.readableAccent(scheme.secondary, brightness);
    return ColoredBox(
      color: AppTheme.paper(brightness),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.help_outline_rounded,
                    size: 18,
                    color: accent,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    '日期不明',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  const Spacer(),
                  _StickerBadge(
                    label: albumCountLabel(count),
                    accent: accent,
                    compact: true,
                  ),
                ],
              ),
            ),
          ),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            color: scheme.outlineVariant.withValues(alpha: 0.65),
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Member covers (人物 view)

class AlbumMemberCover extends StatelessWidget {
  final AlbumMemberAlbum album;
  final VoidCallback onTap;

  const AlbumMemberCover({
    super.key,
    required this.album,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final rawAccent = albumRawAccent(album.member.colorHex, brightness);
    final accent = albumSurfaceAccent(album.member.colorHex, brightness);
    final cover = album.cover;
    final tilt =
        (album.member.key.codeUnits.fold<int>(0, (sum, unit) => sum + unit) %
                5) -
            2;

    return Semantics(
      button: true,
      label: '${album.member.displayName}的切册，${album.total}张',
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              color: AppTheme.wash(rawAccent, scheme.surface, brightness),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: rawAccent.withValues(
                    alpha: brightness == Brightness.dark ? 0.38 : 0.26),
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                  child: Column(
                    children: [
                      Expanded(
                        child: Transform.rotate(
                          angle: tilt * 0.012,
                          child: _MemberPrint(photo: cover, accent: accent),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        album.member.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface,
                          fontSize: 16,
                          height: 1.1,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        album.member.displayGroup,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 10.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        albumMemberCountLabel(
                            album.soloCount, album.groupCount),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: _StickerBadge(
                    label: '${album.total} 张',
                    accent: accent,
                    compact: true,
                  ),
                ),
                Positioned(
                  top: -1,
                  left: 18,
                  child: _WashiTape(
                    width: 48,
                    height: 13,
                    color: rawAccent.withValues(alpha: 0.52),
                    angle: -0.05,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemberPrint extends StatelessWidget {
  final AlbumPhoto? photo;
  final Color accent;

  const _MemberPrint({required this.photo, required this.accent});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 5, 5, 0),
      decoration: BoxDecoration(
        color: AppTheme.polaroid(brightness),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black
                .withValues(alpha: brightness == Brightness.dark ? 0.35 : 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: photo == null
                  ? ColoredBox(
                      color:
                          AppTheme.wash(accent, Colors.white, Brightness.light)
                              .withValues(alpha: 0.9),
                      child: Center(
                        child: Icon(
                          Icons.photo_camera_outlined,
                          size: 26,
                          color: accent.withValues(alpha: 0.6),
                        ),
                      ),
                    )
                  : AlbumPhotoThumb(
                      photo: photo!,
                      cacheWidth: 360,
                      fit: BoxFit.cover,
                    ),
            ),
          ),
          SizedBox(
            height: 16,
            child: Center(
              child: Container(
                width: 26,
                height: 2.5,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Session header (场次 view)

class AlbumSessionHeader extends StatelessWidget {
  final AlbumSession session;

  const AlbumSessionHeader({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final primary = session.members.isEmpty ? null : session.members.first;
    final rawAccent = albumRawAccent(primary?.colorHex ?? '', brightness);
    final accent = albumAccent(primary?.colorHex ?? '', brightness);
    final memberLimit = 5;
    final chips = session.members.take(memberLimit).toList(growable: false);
    final hiddenMembers = session.members.length - chips.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                  alpha: brightness == Brightness.dark ? 0.30 : 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 5,
              child: ColoredBox(color: rawAccent.withValues(alpha: 0.75)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SessionDateStamp(day: session.day, accent: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          session.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            height: 1.18,
                          ),
                        ),
                        if (session.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            session.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                        if (chips.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 5,
                            runSpacing: 5,
                            children: [
                              for (final member in chips)
                                _MemberChip(member: member),
                              if (hiddenMembers > 0)
                                _MemberChip(
                                  member: null,
                                  label: '+$hiddenMembers',
                                  colorHex: primary?.colorHex ?? '',
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StickerBadge(
                    label: '${session.count} 张',
                    accent: accent,
                    compact: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionDateStamp extends StatelessWidget {
  final DateTime? day;
  final Color accent;

  const _SessionDateStamp({required this.day, required this.accent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (day == null) {
      return Container(
        constraints: const BoxConstraints(minWidth: 56, minHeight: 62),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          '日期\n不明',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontSize: 10,
            height: 1.3,
          ),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 56, minHeight: 62),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.30)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${day!.month}月',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${day!.day}',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: accent,
                fontSize: 24,
                height: 1.05,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              albumWeekday(day!),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberChip extends StatelessWidget {
  final AlbumMemberRef? member;
  final String? label;
  final String? colorHex;

  const _MemberChip({
    this.member,
    this.label,
    this.colorHex,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final rawAccent =
        albumRawAccent(member?.colorHex ?? colorHex ?? '', brightness);
    final textColor =
        albumSurfaceAccent(member?.colorHex ?? colorHex ?? '', brightness);
    final name = label ?? member?.displayName ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 3, 8, 3),
      decoration: BoxDecoration(
        color: AppTheme.wash(
          rawAccent,
          theme.colorScheme.surfaceContainerLow,
          brightness,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: rawAccent.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: rawAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sticker + paper decoration (local to the album, deliberately easy to swap
// for Track A's shared dream kit at merge time).

class _StickerBadge extends StatelessWidget {
  final String label;
  final Color accent;
  final bool compact;

  const _StickerBadge({
    required this.label,
    required this.accent,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final onAccent = _onAccent(accent);
    return Transform.rotate(
      angle: -0.02,
      child: Container(
        padding: EdgeInsets.all(compact ? 2.5 : 3),
        decoration: BoxDecoration(
          color: AppTheme.polaroid(brightness),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 9,
            vertical: compact ? 3 : 4,
          ),
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: onAccent,
              fontSize: compact ? 9.5 : 11,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}

class _WashiTape extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final double angle;

  const _WashiTape({
    required this.width,
    required this.height,
    required this.color,
    this.angle = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: SizedBox(
        width: width,
        height: height,
        child: CustomPaint(painter: _WashiTapePainter(color: color)),
      ),
    );
  }
}

class _WashiTapePainter extends CustomPainter {
  final Color color;

  const _WashiTapePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final teeth = math.max(3, size.width ~/ 8);
    final toothWidth = size.width / teeth;
    final path = Path()..moveTo(0, 0);
    for (var i = 0; i < teeth; i++) {
      final x = toothWidth * i;
      path.lineTo(x + toothWidth / 2, size.height * 0.12);
      path.lineTo(x + toothWidth, 0);
    }
    path.lineTo(size.width, size.height * 0.82);
    for (var i = teeth - 1; i >= 0; i--) {
      final x = toothWidth * i;
      path.lineTo(x + toothWidth / 2, size.height);
      path.lineTo(x, size.height * 0.82);
    }
    path.close();
    canvas.drawPath(path, paint);

    final highlight = Paint()..color = Colors.white.withValues(alpha: 0.22);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.30, size.width, size.height * 0.16),
      highlight,
    );
  }

  @override
  bool shouldRepaint(covariant _WashiTapePainter oldDelegate) =>
      oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// Empty states

class AlbumEmptyState extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const AlbumEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.photo_camera_outlined,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = AppTheme.readableAccent(
      theme.colorScheme.secondary,
      theme.brightness,
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 16, 28, 96),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 118,
                  height: 144,
                  child: CustomPaint(
                    painter: _DashedPrintPainter(
                      color: accent.withValues(alpha: 0.55),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                      child: Column(
                        children: [
                          Expanded(
                            child: Center(
                              child: Icon(
                                icon,
                                size: 34,
                                color: accent.withValues(alpha: 0.65),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 22,
                            child: Center(
                              child: Container(
                                width: 42,
                                height: 3,
                                decoration: BoxDecoration(
                                  color: accent.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 14),
                  FilledButton.tonal(
                    onPressed: onAction,
                    child: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedPrintPainter extends CustomPainter {
  final Color color;

  const _DashedPrintPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final radius = Radius.circular(4);
    final path = Path()
      ..addRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(0.5, 0.5, size.width - 0.5, size.height - 0.5),
          topLeft: radius,
          topRight: radius,
          bottomLeft: radius,
          bottomRight: radius,
        ),
      );
    _drawDashedPath(canvas, path, paint, dash: 5, gap: 4);
    // Polaroid bottom margin line.
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    final y = size.height - 28;
    for (var x = 10.0; x < size.width - 10; x += 7) {
      canvas.drawLine(Offset(x, y),
          Offset(math.min(x + 3.5, size.width - 10), y), linePaint);
    }
  }

  void _drawDashedPath(
    Canvas canvas,
    Path path,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedPrintPainter oldDelegate) =>
      oldDelegate.color != color;
}
