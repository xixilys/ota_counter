import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dream_palette.dart';

/// A strip of washi / masking tape with torn, uneven ends.
///
/// Purely decorative unless [label] is supplied. The strip is painted (not an
/// image) so it stays crisp at any size and costs nothing to bundle. Use it to
/// "stick" a polaroid, the selected calendar day or a journal entry to the
/// page; keep it to one strip per surface so it stays a signature, not noise.
class WashiTape extends StatelessWidget {
  final Color color;
  final double width;
  final double height;
  final String? label;
  final Color? textColor;
  final double angle;

  /// When false the ends are cut straight, for layering under photos.
  final bool tornEnds;

  /// Fine diagonal folds printed on the tape.
  final bool folds;

  const WashiTape({
    super.key,
    required this.color,
    this.width = 48,
    this.height = 15,
    this.label,
    this.textColor,
    this.angle = -0.14,
    this.tornEnds = true,
    this.folds = true,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final ink = textColor ?? DreamPalette.ink(brightness);
    final content = label == null
        ? SizedBox(width: width, height: height)
        : SizedBox(
            width: width,
            height: height,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label!,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: math.min(9.0, height - 4),
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ),
            ),
          );

    return Transform.rotate(
      angle: angle,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _WashiPainter(
            color: color,
            tornEnds: tornEnds,
            folds: folds,
          ),
          child: content,
        ),
      ),
    );
  }
}

class _WashiPainter extends CustomPainter {
  final Color color;
  final bool tornEnds;
  final bool folds;

  const _WashiPainter({
    required this.color,
    required this.tornEnds,
    required this.folds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = _tapePath(size, tornEnds: tornEnds);
    final fill = Paint()..color = color;
    canvas.drawPath(path, fill);

    if (folds) {
      final white = Colors.white.withValues(alpha: 0.16);
      final stripe = Paint()
        ..color = white
        ..strokeWidth = 1.2;
      for (var x = -size.height; x < size.width + size.height; x += 11) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x + size.height * 0.55, size.height),
          stripe,
        );
      }
    }

    final shade = Paint()
      ..color = Colors.black.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    canvas.drawPath(path, shade..style = PaintingStyle.stroke);
  }

  Path _tapePath(Size size, {required bool tornEnds}) {
    final jag = tornEnds ? math.min(4.0, size.width * 0.10) : 0.0;
    final h = size.height;
    final path = Path()..moveTo(jag, 0);
    path.lineTo(size.width - jag, 0);
    if (jag > 0) {
      // Right edge: three torn points, alternating in and out.
      for (var i = 1; i <= 3; i++) {
        path.lineTo(
          size.width - (i.isEven ? jag : 0),
          h * i / 3,
        );
      }
    } else {
      path.lineTo(size.width, h);
    }
    path.lineTo(jag, h);
    if (jag > 0) {
      for (var i = 3; i >= 1; i--) {
        path.lineTo(
          i.isEven ? jag : 0,
          h * (i - 1) / 3,
        );
      }
    } else {
      path.lineTo(0, 0);
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(_WashiPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.tornEnds != tornEnds ||
      oldDelegate.folds != folds;
}
