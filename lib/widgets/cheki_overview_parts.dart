import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One member's light in the overview's penlight crowd.
class PenlightData {
  final Color color;
  final int count;

  const PenlightData({required this.color, required this.count});
}

/// Draws a row of penlights rising from the bottom edge, one per member, in
/// the member's own color. Taller lights mean more cheki with that member, so
/// the "photo" on the overview card is a real picture of the collection.
class PenlightCrowd extends StatelessWidget {
  final List<PenlightData> lights;

  /// Upper bound so very large collections still read as individual lights.
  final int maxLights;

  const PenlightCrowd({super.key, required this.lights, this.maxLights = 28});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        painter: _PenlightPainter(
          lights.length > maxLights ? lights.sublist(0, maxLights) : lights,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _PenlightPainter extends CustomPainter {
  final List<PenlightData> lights;

  _PenlightPainter(this.lights);

  static Color _tube(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness(hsl.lightness.clamp(0.56, 0.70))
        .withSaturation(hsl.saturation < 0.12 ? hsl.saturation : 0.92)
        .toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (lights.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final maxCount = lights.map((l) => l.count).fold<int>(1, math.max);
    final slot = size.width / lights.length;
    final tubeWidth = math.min(9.0, math.max(3.0, slot * 0.46));
    final gripHeight = math.min(10.0, size.height * 0.18);
    final grip = Paint()..color = const Color(0xFF1A0613);

    for (var i = 0; i < lights.length; i++) {
      final light = lights[i];
      final share = math.sqrt(light.count / maxCount);
      final tubeHeight = (size.height - gripHeight) * (0.34 + 0.62 * share);
      final cx = slot * (i + 0.5);
      // A small, fixed lean per light so the row reads as a crowd waving,
      // not as a bar chart. Deterministic, so goldens stay stable.
      final lean = (((i * 5) % 7) - 3) * 0.045;

      canvas.save();
      canvas.translate(cx, size.height);
      canvas.rotate(lean);

      final tubeRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -tubeWidth / 2,
          -gripHeight - tubeHeight,
          tubeWidth,
          tubeHeight,
        ),
        Radius.circular(tubeWidth / 2),
      );
      final tube = _tube(light.color);
      canvas.drawRRect(
        tubeRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(tube, Colors.white, 0.55)!,
              tube,
              tube,
            ],
            stops: const [0, 0.38, 1],
          ).createShader(tubeRect.outerRect),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            -tubeWidth / 2 - 0.5,
            -gripHeight,
            tubeWidth + 1,
            gripHeight + 2,
          ),
          const Radius.circular(2),
        ),
        grip,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PenlightPainter oldDelegate) {
    if (oldDelegate.lights.length != lights.length) {
      return true;
    }
    for (var i = 0; i < lights.length; i++) {
      if (oldDelegate.lights[i].color != lights[i].color ||
          oldDelegate.lights[i].count != lights[i].count) {
        return true;
      }
    }
    return false;
  }
}

/// A small label stuck onto the cheki photo at a slight angle, the way fans
/// decorate their prints.
class ChekiSticker extends StatelessWidget {
  final String text;

  const ChekiSticker({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The sticker is a physical object, so it looks the same in both themes.
    return Transform.rotate(
      angle: -0.05,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        decoration: BoxDecoration(
          color: AppTheme.stickerPaper,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          text,
          style: theme.textTheme.titleMedium?.copyWith(
            color: AppTheme.oshi(Brightness.light),
            fontWeight: FontWeight.w600,
            fontSize: 17,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// App mark: a tiny cheki print with three penlights in it.
class PolaroidMark extends StatelessWidget {
  final double width;

  const PolaroidMark({super.key, this.width = 28});

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final inset = width * 0.12;
    return ExcludeSemantics(
      child: Transform.rotate(
        angle: -0.08,
        child: Container(
          width: width,
          height: width * 1.18,
          padding: EdgeInsets.fromLTRB(inset, inset, inset, inset * 2.6),
          decoration: BoxDecoration(
            color: AppTheme.stickerPaper,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Colors.black.withValues(
                alpha: brightness == Brightness.dark ? 0 : 0.08,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: ColoredBox(
              color: AppTheme.stage(Brightness.light),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: PenlightCrowd(
                  lights: [
                    PenlightData(color: AppTheme.cheki3, count: 5),
                    PenlightData(color: AppTheme.chekiGroup, count: 9),
                    PenlightData(color: AppTheme.cheki3s, count: 6),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
