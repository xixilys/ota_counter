import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dream_palette.dart';
import 'washi_tape.dart';

/// A physical polaroid print: white frame, thin side margins, a deeper bottom
/// margin for a caption, a soft page shadow and an optional tape strip.
///
/// The frame is a plain widget rather than a Material card, so it can hold any
/// content (a photo, a member's cheki card, a calendar day) and keep the
/// paper-object feel. Tilt is intentionally tiny (1-2 degrees) and should be
/// reserved for single feature prints, not for scrolling lists.
class PolaroidFrame extends StatelessWidget {
  /// The "photo" area. The caller decides its height/aspect ratio.
  final Widget photo;

  /// Handwritten-style caption, printed on the bottom margin.
  final Widget? caption;

  /// Degrees, clockwise. Use 0 in grids, ±1.5 for a featured print.
  final double tilt;

  /// White frame colour; defaults to the theme's polaroid white.
  final Color? frameColor;

  /// Optional washi tape colour; drawn at the top-left corner.
  final Color? tapeColor;
  final String? tapeLabel;
  final double tapeWidth;
  final double tapeHeight;
  final double tapeAngle;
  final double tapeTop;
  final double tapeLeft;

  final double photoRadius;
  final EdgeInsets framePadding;
  final double captionTop;
  final double captionBottom;
  final bool shadow;

  /// When true the photo area takes all remaining height (the caller must
  /// provide a bounded frame height). Used by member cards in a fixed grid so
  /// the print fills its cell instead of leaving an invisible blank below.
  final bool expandPhoto;

  const PolaroidFrame({
    super.key,
    required this.photo,
    this.caption,
    this.tilt = 0,
    this.frameColor,
    this.tapeColor,
    this.tapeLabel,
    this.tapeWidth = 46,
    this.tapeHeight = 14,
    this.tapeAngle = -0.16,
    this.tapeTop = -5,
    this.tapeLeft = -8,
    this.photoRadius = 2,
    this.framePadding = const EdgeInsets.fromLTRB(5, 5, 5, 5),
    this.captionTop = 6,
    this.captionBottom = 8,
    this.shadow = true,
    this.expandPhoto = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final frame = frameColor ?? DreamPalette.frame(brightness);
    final captionWidget = caption;

    final print = DecoratedBox(
      decoration: BoxDecoration(
        color: frame,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: DreamPalette.hairline(brightness)),
        boxShadow: shadow ? DreamPalette.pageShadow(brightness) : null,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          framePadding.left,
          framePadding.top,
          framePadding.right,
          framePadding.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (expandPhoto)
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(photoRadius),
                  child: photo,
                ),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(photoRadius),
                child: photo,
              ),
            if (captionWidget != null) ...[
              SizedBox(height: captionTop),
              captionWidget,
              SizedBox(height: captionBottom),
            ],
          ],
        ),
      ),
    );

    final taped = Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        print,
        if (tapeColor != null)
          Positioned(
            top: tapeTop,
            left: tapeLeft,
            child: WashiTape(
              color: tapeColor!,
              width: tapeWidth,
              height: tapeHeight,
              label: tapeLabel,
              angle: tapeAngle,
            ),
          ),
      ],
    );

    if (tilt == 0) {
      return taped;
    }
    return Transform.rotate(angle: tilt * math.pi / 180, child: taped);
  }
}
