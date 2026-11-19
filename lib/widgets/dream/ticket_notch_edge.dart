import 'package:flutter/material.dart';

/// Which vertical edges carry the punched notch.
enum TicketNotchSide { left, right, both }

/// A ticket-stub edge: rounded rectangle with a punched semicircle notch on
/// one or both sides, plus a hairline edge.
///
/// The widget only clips and paints; tap/ripple handling stays with the caller
/// (wrap the child in a [Material] / [InkWell] as usual). Use it for period
/// KPIs and the home ticket card so numbers read as paper stubs, not dashboard
/// tiles.
class TicketNotchEdge extends StatelessWidget {
  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;
  final double notchRadius;
  final TicketNotchSide notchSide;

  /// Vertical notch centre as a fraction of the height (0.5 = middle).
  final double notchPosition;
  final Color? borderColor;
  final double borderWidth;

  const TicketNotchEdge({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.notchRadius = 7,
    this.notchSide = TicketNotchSide.both,
    this.notchPosition = 0.5,
    this.borderColor,
    this.borderWidth = 1,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = color ?? theme.colorScheme.surface;
    final border = borderColor ?? theme.colorScheme.outlineVariant;

    return ClipPath(
      clipper: _TicketNotchClipper(
        borderRadius: borderRadius,
        notchRadius: notchRadius,
        notchSide: notchSide,
        notchPosition: notchPosition,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(color: fill),
        child: CustomPaint(
          foregroundPainter: _TicketEdgePainter(
            borderRadius: borderRadius,
            notchRadius: notchRadius,
            notchSide: notchSide,
            notchPosition: notchPosition,
            color: border,
            width: borderWidth,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _TicketNotchClipper extends CustomClipper<Path> {
  final BorderRadius borderRadius;
  final double notchRadius;
  final TicketNotchSide notchSide;
  final double notchPosition;

  const _TicketNotchClipper({
    required this.borderRadius,
    required this.notchRadius,
    required this.notchSide,
    required this.notchPosition,
  });

  @override
  Path getClip(Size size) => ticketStubPath(
        size,
        borderRadius: borderRadius,
        notchRadius: notchRadius,
        notchSide: notchSide,
        notchPosition: notchPosition,
      );

  @override
  bool shouldReclip(_TicketNotchClipper oldClipper) =>
      oldClipper.borderRadius != borderRadius ||
      oldClipper.notchRadius != notchRadius ||
      oldClipper.notchSide != notchSide ||
      oldClipper.notchPosition != notchPosition;
}

/// Shared geometry so callers/tests can reuse the punched path.
Path ticketStubPath(
  Size size, {
  BorderRadius borderRadius = const BorderRadius.all(Radius.circular(16)),
  double notchRadius = 7,
  TicketNotchSide notchSide = TicketNotchSide.both,
  double notchPosition = 0.5,
}) {
  final rect = Offset.zero & size;
  var path = Path()
    ..addRRect(borderRadius.toRRect(rect));
  final y = size.height * notchPosition.clamp(0.0, 1.0);
  if (notchSide == TicketNotchSide.left ||
      notchSide == TicketNotchSide.both) {
    path = Path.combine(
      PathOperation.difference,
      path,
      Path()
        ..addOval(
          Rect.fromCircle(
            center: Offset(0, y),
            radius: notchRadius,
          ),
        ),
    );
  }
  if (notchSide == TicketNotchSide.right ||
      notchSide == TicketNotchSide.both) {
    path = Path.combine(
      PathOperation.difference,
      path,
      Path()
        ..addOval(
          Rect.fromCircle(
            center: Offset(size.width, y),
            radius: notchRadius,
          ),
        ),
    );
  }
  return path;
}

class _TicketEdgePainter extends CustomPainter {
  final BorderRadius borderRadius;
  final double notchRadius;
  final TicketNotchSide notchSide;
  final double notchPosition;
  final Color color;
  final double width;

  const _TicketEdgePainter({
    required this.borderRadius,
    required this.notchRadius,
    required this.notchSide,
    required this.notchPosition,
    required this.color,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final path = ticketStubPath(
      size,
      borderRadius: borderRadius,
      notchRadius: notchRadius,
      notchSide: notchSide,
      notchPosition: notchPosition,
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_TicketEdgePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.width != width ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.notchRadius != notchRadius ||
      oldDelegate.notchSide != notchSide ||
      oldDelegate.notchPosition != notchPosition;
}
