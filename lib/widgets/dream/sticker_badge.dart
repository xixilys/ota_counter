import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dream_palette.dart';

/// Shape of a die-cut sticker.
enum StickerShape {
  /// Soft rectangle with a white die-cut outline (counts, dates, labels).
  rounded,

  /// A round sticker; pair with [StickerBadge.size].
  circle,

  /// A scalloped starburst, for the one big number on a scrapbook page.
  burst,
}

/// A sticker printed on glossy paper: die-cut white outline, the member's
/// colour and a short value/label pair. The outline keeps it readable when it
/// overlaps a polaroid, tape or the page.
class StickerBadge extends StatelessWidget {
  final String value;
  final String? label;
  final Color? color;
  final Color? textColor;
  final StickerShape shape;
  final Color? outlineColor;
  final double outlineWidth;
  final EdgeInsets padding;
  final double? valueFontSize;
  final double? labelFontSize;
  final double? minWidth;

  /// Forces a square footprint for [StickerShape.circle] / `burst`.
  final double? size;
  final String? semanticLabel;
  final bool shadow;

  const StickerBadge({
    super.key,
    required this.value,
    this.label,
    this.color,
    this.textColor,
    this.shape = StickerShape.rounded,
    this.outlineColor,
    this.outlineWidth = 2.5,
    this.padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    this.valueFontSize,
    this.labelFontSize,
    this.minWidth,
    this.size,
    this.semanticLabel,
    this.shadow = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final fill = color ?? theme.colorScheme.primary;
    final ink = textColor ?? DreamPalette.onColor(fill);
    final outline = outlineColor ?? Colors.white;

    Widget content = Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            value,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: valueFontSize ?? 15,
              height: 1.05,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.4,
              color: ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (label != null) ...[
            const SizedBox(height: 1),
            Text(
              label!,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: labelFontSize ?? 8,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: ink.withValues(alpha: 0.82),
              ),
            ),
          ],
        ],
      ),
    );

    if (size != null) {
      if (shape == StickerShape.rounded) {
        content = ConstrainedBox(
          constraints: BoxConstraints(minWidth: size!),
          child: content,
        );
      } else {
        content = SizedBox(
          width: size,
          height: size,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: content,
            ),
          ),
        );
      }
    } else if (minWidth != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(minWidth: minWidth!),
        child: content,
      );
    }

    final body = Padding(
      padding: EdgeInsets.all(outlineWidth),
      child: content,
    );

    final sticker = RepaintBoundary(
      child: CustomPaint(
        painter: _StickerPainter(
          fill: fill,
          outline: outline,
          shape: shape,
          outlineWidth: outlineWidth,
          shadow: shadow && brightness == Brightness.light,
        ),
        child: body,
      ),
    );

    if (semanticLabel == null) {
      return sticker;
    }
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: sticker,
    );
  }
}

class _StickerPainter extends CustomPainter {
  final Color fill;
  final Color outline;
  final StickerShape shape;
  final double outlineWidth;
  final bool shadow;

  const _StickerPainter({
    required this.fill,
    required this.outline,
    required this.shape,
    required this.outlineWidth,
    required this.shadow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final outer = _path(rect, shape);
    if (shadow) {
      canvas.drawShadow(
        outer,
        Colors.black.withValues(alpha: 0.16),
        3,
        false,
      );
    }
    canvas.drawPath(outer, Paint()..color = outline);
    final inner = _path(
      Rect.fromLTWH(
        outlineWidth,
        outlineWidth,
        math.max(0, size.width - outlineWidth * 2),
        math.max(0, size.height - outlineWidth * 2),
      ),
      shape,
    );
    canvas.drawPath(inner, Paint()..color = fill);
  }

  Path _path(Rect rect, StickerShape shape) {
    switch (shape) {
      case StickerShape.rounded:
        return Path()
          ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.height)));
      case StickerShape.circle:
        return Path()..addOval(rect);
      case StickerShape.burst:
        final center = rect.center;
        final radiusX = rect.width / 2;
        final radiusY = rect.height / 2;
        final path = Path();
        const points = 12;
        for (var i = 0; i < points * 2; i++) {
          final angle = -math.pi / 2 + i * math.pi / points;
          final spike = i.isEven ? 1.0 : 0.82;
          final x = center.dx + math.cos(angle) * radiusX * spike;
          final y = center.dy + math.sin(angle) * radiusY * spike;
          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        path.close();
        return path;
    }
  }

  @override
  bool shouldRepaint(_StickerPainter oldDelegate) =>
      oldDelegate.fill != fill ||
      oldDelegate.outline != outline ||
      oldDelegate.shape != shape ||
      oldDelegate.outlineWidth != outlineWidth ||
      oldDelegate.shadow != shadow;
}
