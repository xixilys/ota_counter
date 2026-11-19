import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The small hand-drawn sparkle/star family used across the scrapbook.
enum SparkleVariant { sparkle, star, burst }

/// A tiny drawn sparkle. Use it instead of emoji for decoration.
class SparkleMark extends StatelessWidget {
  final double size;
  final Color? color;
  final SparkleVariant variant;

  /// A small satellite dot, like a penlight flare.
  final bool dot;

  const SparkleMark({
    super.key,
    this.size = 14,
    this.color,
    this.variant = SparkleVariant.sparkle,
    this.dot = false,
  });

  @override
  Widget build(BuildContext context) {
    final paintColor = color ?? Theme.of(context).colorScheme.primary;
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.square(size),
        painter: _SparklePainter(
          color: paintColor,
          variant: variant,
          dot: dot,
        ),
      ),
    );
  }
}

class _SparklePainter extends CustomPainter {
  final Color color;
  final SparkleVariant variant;
  final bool dot;

  const _SparklePainter({
    required this.color,
    required this.variant,
    required this.dot,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (variant) {
      case SparkleVariant.sparkle:
        final path = Path();
        const points = 4;
        for (var i = 0; i < points * 2; i++) {
          final angle = -math.pi / 2 + i * math.pi / points;
          final r = i.isEven ? radius : radius * 0.24;
          final point = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
          if (i == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        path.close();
        canvas.drawPath(path, paint);
      case SparkleVariant.star:
        final path = Path();
        const points = 5;
        for (var i = 0; i < points * 2; i++) {
          final angle = -math.pi / 2 + i * math.pi / points;
          final r = i.isEven ? radius : radius * 0.42;
          final point = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
          if (i == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        path.close();
        canvas.drawPath(path, paint);
      case SparkleVariant.burst:
        final stroke = Paint()
          ..color = color
          ..strokeWidth = math.max(1.2, radius * 0.16)
          ..strokeCap = StrokeCap.round;
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4;
          final inner = center +
              Offset(math.cos(angle) * radius * 0.35,
                  math.sin(angle) * radius * 0.35);
          final outer = center +
              Offset(math.cos(angle) * radius, math.sin(angle) * radius);
          canvas.drawLine(inner, outer, stroke);
        }
    }

    if (dot) {
      canvas.drawCircle(
        center + Offset(radius * 0.85, radius * 0.55),
        math.max(1.0, radius * 0.16),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SparklePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.variant != variant ||
      oldDelegate.dot != dot;
}
