import 'package:flutter/material.dart';

import '../models/ticket_type_model.dart';
import '../theme/app_theme.dart';

/// Home summary of live tickets, drawn as a real ticket: a yellow body and a
/// tear-off stub separated by a perforation with punched notches.
class TicketStubCard extends StatelessWidget {
  final TicketStats stats;
  final VoidCallback? onTap;
  final VoidCallback onAdd;

  const TicketStubCard({
    super.key,
    required this.stats,
    required this.onAdd,
    this.onTap,
  });

  static const double _stubWidth = 132;
  static const double _radius = 14;
  static const double _notchRadius = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final ticketPaper = AppTheme.ticketPaper(brightness);
    const ink = AppTheme.ticketInk;
    const inkMuted = AppTheme.ticketInkMuted;
    final topTypes = stats.countByType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final typeLine = [
      for (final entry in topTypes.take(3)) '${entry.key} ${entry.value}',
      if (topTypes.length > 3) '等 ${topTypes.length} 种',
    ].join(' · ');

    return PhysicalShape(
      clipper: const _TicketClipper(
        stubWidth: _stubWidth,
        radius: _radius,
        notchRadius: _notchRadius,
      ),
      clipBehavior: Clip.antiAlias,
      color: AppTheme.polaroid(brightness),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: CustomPaint(
            painter: _TicketPainter(
              paper: ticketPaper,
              perforation: isDark
                  ? Colors.white.withValues(alpha: 0.28)
                  : ink.withValues(alpha: 0.28),
              outline: scheme.onSurface.withValues(alpha: isDark ? 0.10 : 0.08),
              stubWidth: _stubWidth,
              radius: _radius,
              notchRadius: _notchRadius,
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.local_activity_rounded,
                                size: 16,
                                color: inkMuted,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '现场门票',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: inkMuted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${stats.ticketCount}',
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 32,
                                  height: 1.1,
                                  color: ink,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.only(left: 4, bottom: 6),
                                child: Text(
                                  '张门票',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: inkMuted,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            stats.isEmpty
                                ? '还没有门票记录'
                                : '免费 ${stats.freeTicketCount} · 付费 ${stats.paidTicketCount}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: ink,
                              fontSize: 12,
                            ),
                          ),
                          if (typeLine.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              typeLine,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: inkMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _stubWidth,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  stats.isEmpty
                                      ? '去看演出吧'
                                      : '¥${_formatAmount(stats.amount)}',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 18,
                                    color: scheme.onSurface,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                stats.isEmpty ? '记录你的第一张票' : '累计门票金额',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: onAdd,
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: const Text('记门票'),
                            style: FilledButton.styleFrom(
                              backgroundColor: ticketPaper,
                              foregroundColor: ink,
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              textStyle: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
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
        ),
      ),
    );
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

/// Rounded ticket outline with half-circle notches punched into the top and
/// bottom edges where the stub tears off.
Path _ticketPath(
  Size size, {
  required double stubWidth,
  required double radius,
  required double notchRadius,
}) {
  final x = size.width - stubWidth;
  final outline = Path()
    ..addRRect(
      RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
    );
  final notches = Path()
    ..addOval(Rect.fromCircle(center: Offset(x, 0), radius: notchRadius))
    ..addOval(
      Rect.fromCircle(center: Offset(x, size.height), radius: notchRadius),
    );
  return Path.combine(PathOperation.difference, outline, notches);
}

class _TicketClipper extends CustomClipper<Path> {
  final double stubWidth;
  final double radius;
  final double notchRadius;

  const _TicketClipper({
    required this.stubWidth,
    required this.radius,
    required this.notchRadius,
  });

  @override
  Path getClip(Size size) => _ticketPath(
        size,
        stubWidth: stubWidth,
        radius: radius,
        notchRadius: notchRadius,
      );

  @override
  bool shouldReclip(_TicketClipper oldClipper) =>
      oldClipper.stubWidth != stubWidth ||
      oldClipper.radius != radius ||
      oldClipper.notchRadius != notchRadius;
}

/// Paints the ticket body color, the dashed perforation and the edge. The stub keeps the
/// surface color from [PhysicalShape].
class _TicketPainter extends CustomPainter {
  final Color paper;
  final Color perforation;
  final Color outline;
  final double stubWidth;
  final double radius;
  final double notchRadius;

  _TicketPainter({
    required this.paper,
    required this.perforation,
    required this.outline,
    required this.stubWidth,
    required this.radius,
    required this.notchRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width - stubWidth;
    canvas.drawRect(
        Rect.fromLTWH(0, 0, x, size.height), Paint()..color = paper);
    final dash = Paint()
      ..color = perforation
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const dashLength = 4.0;
    const gap = 4.0;
    var y = notchRadius + 4;
    final end = size.height - notchRadius - 4;
    while (y < end) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, (y + dashLength).clamp(0, end)),
        dash,
      );
      y += dashLength + gap;
    }
    // Hairline edge so the white stub still reads on the light page.
    canvas.drawPath(
      _ticketPath(
        size,
        stubWidth: stubWidth,
        radius: radius,
        notchRadius: notchRadius,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = outline,
    );
  }

  @override
  bool shouldRepaint(_TicketPainter oldDelegate) =>
      oldDelegate.paper != paper ||
      oldDelegate.perforation != perforation ||
      oldDelegate.outline != outline ||
      oldDelegate.radius != radius ||
      oldDelegate.stubWidth != stubWidth ||
      oldDelegate.notchRadius != notchRadius;
}
