import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A page of scrapbook paper: a quiet dot grid, optional ruled lines and two
/// tiny sparkle accents in the member/period colour.
///
/// Decoration stays below 8% opacity so it never fights the content. Wrap a
/// page body with this once; do not stack it inside cards.
class DreamPaperBackground extends StatelessWidget {
  final Widget child;
  final Color? accent;
  final bool dots;
  final bool ruled;

  const DreamPaperBackground({
    super.key,
    required this.child,
    this.accent,
    this.dots = true,
    this.ruled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return CustomPaint(
      painter: _PaperPainter(
        dotColor: scheme.onSurface.withValues(
          alpha: brightness == Brightness.dark ? 0.085 : 0.065,
        ),
        ruleColor: scheme.onSurface.withValues(
          alpha: brightness == Brightness.dark ? 0.05 : 0.035,
        ),
        accent: (accent ?? scheme.primary).withValues(
          alpha: brightness == Brightness.dark ? 0.16 : 0.12,
        ),
        dots: dots,
        ruled: ruled,
      ),
      child: child,
    );
  }
}

class _PaperPainter extends CustomPainter {
  final Color dotColor;
  final Color ruleColor;
  final Color accent;
  final bool dots;
  final bool ruled;

  const _PaperPainter({
    required this.dotColor,
    required this.ruleColor,
    required this.accent,
    required this.dots,
    required this.ruled,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (dots) {
      final dot = Paint()..color = dotColor;
      const spacing = 22.0;
      for (var y = 12.0; y < size.height; y += spacing) {
        for (var x = 12.0; x < size.width; x += spacing) {
          canvas.drawCircle(Offset(x, y), 1.0, dot);
        }
      }
    }

    if (ruled) {
      final line = Paint()
        ..color = ruleColor
        ..strokeWidth = 1;
      for (var y = 30.0; y < size.height; y += 30) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    }

    // Two paper-corner accents, drawn not printed: a sparkle top-right and a
    // small star bottom-left. They only show where content leaves space.
    _sparkle(
      canvas,
      Offset(size.width - 26, 22),
      7,
      accent,
    );
    _sparkle(
      canvas,
      Offset(18, size.height - 26),
      5,
      accent.withValues(alpha: accent.a * 0.7),
    );
  }

  void _sparkle(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final angle = -math.pi / 2 + i * math.pi / 4;
      final r = i.isEven ? radius : radius * 0.28;
      final point = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_PaperPainter oldDelegate) =>
      oldDelegate.dotColor != dotColor ||
      oldDelegate.ruleColor != ruleColor ||
      oldDelegate.accent != accent ||
      oldDelegate.dots != dots ||
      oldDelegate.ruled != ruled;
}
