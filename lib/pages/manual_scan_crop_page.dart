import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/record_scan_service.dart';

class ManualScanCropPage extends StatefulWidget {
  final RecordScanManualDraft draft;

  const ManualScanCropPage({
    super.key,
    required this.draft,
  });

  @override
  State<ManualScanCropPage> createState() => _ManualScanCropPageState();
}

class _ManualScanCropPageState extends State<ManualScanCropPage> {
  late RecordScanQuad _quad;

  @override
  void initState() {
    super.initState();
    _quad = widget.draft.suggestedQuad;
  }

  void _resetQuad() {
    setState(() {
      _quad = widget.draft.suggestedQuad;
    });
  }

  void _updateHandle(
    _ManualHandle handle,
    DragUpdateDetails details,
    double scaleX,
    double scaleY,
  ) {
    final deltaX = details.delta.dx / scaleX;
    final deltaY = details.delta.dy / scaleY;

    setState(() {
      switch (handle) {
        case _ManualHandle.topLeft:
          _quad = _quad.copyWith(
            topLeftX: _quad.topLeftX + deltaX,
            topLeftY: _quad.topLeftY + deltaY,
          );
          break;
        case _ManualHandle.topRight:
          _quad = _quad.copyWith(
            topRightX: _quad.topRightX + deltaX,
            topRightY: _quad.topRightY + deltaY,
          );
          break;
        case _ManualHandle.bottomLeft:
          _quad = _quad.copyWith(
            bottomLeftX: _quad.bottomLeftX + deltaX,
            bottomLeftY: _quad.bottomLeftY + deltaY,
          );
          break;
        case _ManualHandle.bottomRight:
          _quad = _quad.copyWith(
            bottomRightX: _quad.bottomRightX + deltaX,
            bottomRightY: _quad.bottomRightY + deltaY,
          );
          break;
      }
      _quad = _quad.clampToBounds(
        imageWidth: widget.draft.imageWidth,
        imageHeight: widget.draft.imageHeight,
      );
    });
  }

  bool get _isUsableQuad {
    final topWidth = _distance(
      _quad.topLeftX,
      _quad.topLeftY,
      _quad.topRightX,
      _quad.topRightY,
    );
    final bottomWidth = _distance(
      _quad.bottomLeftX,
      _quad.bottomLeftY,
      _quad.bottomRightX,
      _quad.bottomRightY,
    );
    final leftHeight = _distance(
      _quad.topLeftX,
      _quad.topLeftY,
      _quad.bottomLeftX,
      _quad.bottomLeftY,
    );
    final rightHeight = _distance(
      _quad.topRightX,
      _quad.topRightY,
      _quad.bottomRightX,
      _quad.bottomRightY,
    );
    return topWidth >= 60 &&
        bottomWidth >= 60 &&
        leftHeight >= 60 &&
        rightHeight >= 60;
  }

  double _distance(double ax, double ay, double bx, double by) {
    final dx = ax - bx;
    final dy = ay - by;
    return math.sqrt((dx * dx) + (dy * dy));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = widget.draft.usedFallback
        ? '自动识别不太稳定，拖动四个圆点手动框住整张拍立得。'
        : '已经帮你框出大致范围，可以直接拖四个角微调。';

    return Scaffold(
      appBar: AppBar(
        title: const Text('手动框选切图'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  hint,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: AspectRatio(
                    aspectRatio:
                        widget.draft.imageWidth / widget.draft.imageHeight,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final scaleX =
                            constraints.maxWidth / widget.draft.imageWidth;
                        final scaleY =
                            constraints.maxHeight / widget.draft.imageHeight;
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.memory(
                                Uint8List.fromList(widget.draft.sourceBytes),
                                fit: BoxFit.fill,
                                gaplessPlayback: true,
                              ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _ManualScanOverlayPainter(
                                    quad: _quad,
                                    scaleX: scaleX,
                                    scaleY: scaleY,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                              ..._ManualHandle.values.map((handle) {
                                final point = switch (handle) {
                                  _ManualHandle.topLeft => Offset(
                                      _quad.topLeftX * scaleX,
                                      _quad.topLeftY * scaleY,
                                    ),
                                  _ManualHandle.topRight => Offset(
                                      _quad.topRightX * scaleX,
                                      _quad.topRightY * scaleY,
                                    ),
                                  _ManualHandle.bottomLeft => Offset(
                                      _quad.bottomLeftX * scaleX,
                                      _quad.bottomLeftY * scaleY,
                                    ),
                                  _ManualHandle.bottomRight => Offset(
                                      _quad.bottomRightX * scaleX,
                                      _quad.bottomRightY * scaleY,
                                    ),
                                };
                                return Positioned(
                                  left: point.dx - 18,
                                  top: point.dy - 18,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanUpdate: (details) => _updateHandle(
                                      handle,
                                      details,
                                      scaleX,
                                      scaleY,
                                    ),
                                    child: Container(
                                      width: 36,
                                      height: 36,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white.withAlpha(224),
                                        border: Border.all(
                                          color: theme.colorScheme.primary,
                                          width: 3,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            blurRadius: 10,
                                            color: Colors.black26,
                                          ),
                                        ],
                                      ),
                                      child: Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _resetQuad,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('恢复自动框'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isUsableQuad
                          ? () => Navigator.of(context).pop(_quad)
                          : null,
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('生成切图'),
                    ),
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

enum _ManualHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class _ManualScanOverlayPainter extends CustomPainter {
  final RecordScanQuad quad;
  final double scaleX;
  final double scaleY;
  final Color color;

  const _ManualScanOverlayPainter({
    required this.quad,
    required this.scaleX,
    required this.scaleY,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final topLeft = Offset(quad.topLeftX * scaleX, quad.topLeftY * scaleY);
    final topRight = Offset(quad.topRightX * scaleX, quad.topRightY * scaleY);
    final bottomRight = Offset(
      quad.bottomRightX * scaleX,
      quad.bottomRightY * scaleY,
    );
    final bottomLeft = Offset(
      quad.bottomLeftX * scaleX,
      quad.bottomLeftY * scaleY,
    );

    final areaPath = Path()
      ..moveTo(topLeft.dx, topLeft.dy)
      ..lineTo(topRight.dx, topRight.dy)
      ..lineTo(bottomRight.dx, bottomRight.dy)
      ..lineTo(bottomLeft.dx, bottomLeft.dy)
      ..close();

    final overlayPaint = Paint()
      ..color = Colors.black.withAlpha(70)
      ..style = PaintingStyle.fill;
    final fullPath = Path()..addRect(Offset.zero & size);
    final maskPath = Path.combine(
      PathOperation.difference,
      fullPath,
      areaPath,
    );
    canvas.drawPath(maskPath, overlayPaint);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;
    canvas.drawPath(areaPath, linePaint);

    final guidePaint = Paint()
      ..color = Colors.white.withAlpha(180)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(topLeft, bottomRight, guidePaint);
    canvas.drawLine(topRight, bottomLeft, guidePaint);
  }

  @override
  bool shouldRepaint(covariant _ManualScanOverlayPainter oldDelegate) {
    return quad != oldDelegate.quad ||
        scaleX != oldDelegate.scaleX ||
        scaleY != oldDelegate.scaleY ||
        color != oldDelegate.color;
  }
}
