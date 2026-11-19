import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Colour helpers for the "切奇手帐" (cheki scrapbook) visual kit.
///
/// Everything here is derived from a member's 応援色 plus the current theme, so
/// the same decorative widget reads correctly in light and dark mode. Text
/// colours are contrast-checked against the fill they sit on, not guessed.
class DreamPalette {
  const DreamPalette._();

  /// A saturated but readable version of a member colour, for small marks,
  /// tape and sticker text. Wraps [AppTheme.readableAccent].
  static Color accent(Color base, Brightness brightness) =>
      AppTheme.readableAccent(base, brightness);

  /// The pastel "photo" field of a polaroid: the member colour softened to a
  /// tint in light mode and deepened toward stage-night in dark mode.
  static Color photo(Color base, Brightness brightness) {
    final hsl = HSLColor.fromColor(base);
    if (brightness == Brightness.dark) {
      return HSLColor.fromAHSL(
        1.0,
        hsl.hue,
        hsl.saturation.clamp(0.28, 0.72),
        0.20,
      ).toColor();
    }
    return HSLColor.fromAHSL(
      1.0,
      hsl.hue,
      hsl.saturation.clamp(0.32, 0.78),
      0.90,
    ).toColor();
  }

  /// A slightly stronger tint for the second stop inside the photo field.
  static Color photoDeep(Color base, Brightness brightness) {
    final photo = DreamPalette.photo(base, brightness);
    final hsl = HSLColor.fromColor(photo);
    return hsl
        .withLightness(
          brightness == Brightness.dark ? 0.14 : 0.84,
        )
        .toColor();
  }

  /// Translucent washi tape colour built from the member accent.
  static Color tape(Color base, Brightness brightness) {
    final accent = DreamPalette.accent(base, brightness);
    if (brightness == Brightness.dark) {
      return Color.alphaBlend(
        accent.withValues(alpha: 0.34),
        const Color(0xFF2A222D),
      );
    }
    return Color.alphaBlend(
      accent.withValues(alpha: 0.26),
      const Color(0xFFFFFDF8),
    );
  }

  /// Die-cut sticker fill: saturated enough to read against the frame, but
  /// still the member's own colour.
  static Color sticker(Color base, Brightness brightness) =>
      DreamPalette.accent(base, brightness);

  /// Small status glue dots, labels and captions.
  static Color ink(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFFF2EFF8)
      : const Color(0xFF2B2111);

  static Color mutedInk(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFFC9C1DA)
      : const Color(0xFF5E5348);

  /// Hairline drawn on the paper, never a heavy divider.
  static Color hairline(Brightness brightness) =>
      brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.10)
          : const Color(0xFF2B2111).withValues(alpha: 0.10);

  /// The white polaroid frame colour (one step above the page paper).
  static Color frame(Brightness brightness) => AppTheme.polaroid(brightness);

  /// A small wash of a member colour over the page, used for journal entries.
  static Color wash(
    Color base,
    Color surface,
    Brightness brightness, {
    double strength = 0.07,
  }) {
    final accent = DreamPalette.accent(base, brightness);
    return Color.alphaBlend(
      accent.withValues(alpha: brightness == Brightness.dark ? 0.16 : strength),
      surface,
    );
  }

  /// Best readable ink for text sitting on [fill] (black or white).
  static Color onColor(Color fill) {
    final luminance = fill.computeLuminance();
    final contrastWithBlack = (luminance + 0.05) / 0.05;
    final contrastWithWhite = 1.05 / (luminance + 0.05);
    return contrastWithWhite >= contrastWithBlack
        ? Colors.white
        : const Color(0xFF1C1410);
  }

  /// Soft, neutral page shadow. Dark mode uses surface steps instead, so the
  /// shadow fades away there.
  static List<BoxShadow>? pageShadow(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return null;
    }
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.05),
        blurRadius: 12,
        offset: const Offset(0, 4),
      ),
    ];
  }

  /// Three or four small, deterministic tape accents for a group/month.
  static Color washiTint(Color base, Brightness brightness, int index) {
    final extras = <Color>[
      const Color(0xFFF0A6C0),
      const Color(0xFF8CCFE8),
      const Color(0xFFF0D58A),
      const Color(0xFFA8D8B2),
    ];
    final source = index == 0 ? base : extras[(index - 1) % extras.length];
    return DreamPalette.tape(source, brightness);
  }
}
