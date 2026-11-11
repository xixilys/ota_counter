import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Central design tokens and Material 3 theme for OTA Counter.
///
/// The visual language is intentionally quiet: warm off-white surfaces,
/// indigo primary actions, sakura accents, large rounded shapes and a single
/// soft aurora background. Member colors are applied as small accents instead
/// of flooding an entire card, which keeps long Chinese names readable.
class AppTheme {
  const AppTheme._();

  static const Color seed = Color(0xFF5B4BE0);
  static const Color sakura = Color(0xFFE85D7A);
  static const Color mint = Color(0xFF0F9E8E);
  static const Color amber = Color(0xFFF2A93B);
  static const Color sky = Color(0xFF4E8DF5);

  // Home "cheki" palette: a white-framed print, a berry stage lit by member
  // penlights, a yellow live ticket. Surfaces stay neutral; these colors live
  // inside those objects and in the metric tiles.
  static const Color stickerPaper = Color(0xFFFFFBF7);
  static const Color ticketInk = Color(0xFF2B2111);
  static const Color ticketInkMuted = Color(0xFF5E5348);

  /// Metric colors, one per cheki kind.
  static const Color cheki3 = Color(0xFFF0427A);
  static const Color cheki5 = Color(0xFF3B8BEB);
  static const Color cheki3s = Color(0xFF12B886);
  static const Color cheki5s = Color(0xFFFF7A3D);
  static const Color chekiGroup = Color(0xFFF5B400);
  static const Color chekiCustom = Color(0xFF8A63E8);

  static bool _dark(Brightness b) => b == Brightness.dark;

  /// 应援粉: the one accent on the home page (primary action, sticker text).
  /// 5.0:1 against white in light mode, 7.0:1 against the dark surface.
  static Color oshi(Brightness b) =>
      _dark(b) ? const Color(0xFFFF7AA8) : const Color(0xFFD3245F);

  static Color onOshi(Brightness b) =>
      _dark(b) ? const Color(0xFF2A0A18) : Colors.white;

  /// Page background, a barely warm neutral.
  static Color paper(Brightness b) =>
      _dark(b) ? const Color(0xFF131115) : const Color(0xFFF6F4F2);

  /// The white border of a cheki print, one step above [paper].
  static Color polaroid(Brightness b) =>
      _dark(b) ? const Color(0xFF221E25) : Colors.white;

  /// The dark berry "photo" inside the overview print.
  /// The dark berry "photo" inside the overview print. Same in both themes,
  /// it is a picture, not a surface.
  static Color stage(Brightness b) => const Color(0xFF4A0F35);

  static Color ticketPaper(Brightness b) =>
      _dark(b) ? const Color(0xFFE9C14A) : const Color(0xFFFFD84D);

  static ThemeData light({String? fontFamily}) {
    return _build(Brightness.light, fontFamily);
  }

  static ThemeData dark({String? fontFamily}) {
    return _build(Brightness.dark, fontFamily);
  }

  static ThemeData _build(Brightness brightness, String? fontFamily) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(
      primary: isDark ? const Color(0xFFC9C0FF) : const Color(0xFF5B4BE0),
      onPrimary: isDark ? const Color(0xFF241A5E) : Colors.white,
      primaryContainer:
          isDark ? const Color(0xFF3B2F78) : const Color(0xFFE9E5FF),
      onPrimaryContainer:
          isDark ? const Color(0xFFEDE9FF) : const Color(0xFF241A5E),
      secondary: isDark ? const Color(0xFFFFB1C2) : sakura,
      onSecondary: isDark ? const Color(0xFF52101F) : Colors.white,
      secondaryContainer:
          isDark ? const Color(0xFF63283A) : const Color(0xFFFFE3EA),
      onSecondaryContainer:
          isDark ? const Color(0xFFFFE3EA) : const Color(0xFF54101F),
      tertiary: isDark ? const Color(0xFF7BE0D2) : mint,
      onTertiary: isDark ? const Color(0xFF003730) : Colors.white,
      tertiaryContainer:
          isDark ? const Color(0xFF11554C) : const Color(0xFFD8F6F1),
      onTertiaryContainer:
          isDark ? const Color(0xFFD8F6F1) : const Color(0xFF003730),
      surface: isDark ? const Color(0xFF1A1722) : const Color(0xFFFFFFFF),
      surfaceContainerLowest:
          isDark ? const Color(0xFF0E0C13) : const Color(0xFFFFFFFF),
      surfaceContainerLow:
          isDark ? const Color(0xFF211D2B) : const Color(0xFFFBFAFF),
      surfaceContainer:
          isDark ? const Color(0xFF272232) : const Color(0xFFF4F1FB),
      surfaceContainerHigh:
          isDark ? const Color(0xFF2F293C) : const Color(0xFFEDE9F7),
      surfaceContainerHighest:
          isDark ? const Color(0xFF3A3348) : const Color(0xFFE5E0F0),
      onSurface: isDark ? const Color(0xFFF2EFF8) : const Color(0xFF1D1B26),
      onSurfaceVariant:
          isDark ? const Color(0xFFC9C1DA) : const Color(0xFF625E70),
      outline: isDark ? const Color(0xFF8D84A3) : const Color(0xFF7B7590),
      outlineVariant:
          isDark ? const Color(0xFF3B3449) : const Color(0xFFE7E2F0),
      error: isDark ? const Color(0xFFFFB4AB) : const Color(0xFFC0392B),
      onError: isDark ? const Color(0xFF690005) : Colors.white,
      inverseSurface:
          isDark ? const Color(0xFFF2EFF8) : const Color(0xFF2A2634),
      onInverseSurface:
          isDark ? const Color(0xFF2A2634) : const Color(0xFFF7F4FF),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
    );

    final textTheme = base.textTheme.copyWith(
      displayLarge: base.textTheme.displayLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.8,
      ),
      displayMedium: base.textTheme.displayMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
      ),
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.4,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w800,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.45),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.45),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      labelMedium: base.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );

    final rounded16 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    final rounded20 = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    );

    return base.copyWith(
      scaffoldBackgroundColor: paper(brightness),
      canvasColor: scheme.surface,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      appBarTheme: AppBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w800,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: isDark ? 0.3 : 0.06),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: rounded16,
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: rounded16,
          side: BorderSide(color: scheme.outlineVariant),
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: rounded16,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor:
            isDark ? scheme.surfaceContainer : scheme.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle: textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        textStyle: textTheme.bodyMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.primaryContainer,
        shape: rounded16,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.primaryContainer,
        disabledColor: scheme.surfaceContainerHigh,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        labelStyle: textTheme.labelMedium,
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        indicatorColor: scheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelMedium),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 1,
        highlightElevation: 0,
        shape: rounded20,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.primaryContainer,
        circularTrackColor: scheme.primaryContainer,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: textTheme.labelMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        waitDuration: const Duration(milliseconds: 450),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        shape: rounded16,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(textTheme.labelLarge),
          shape: WidgetStatePropertyAll(rounded16),
        ),
      ),
    );
  }

  /// Turns an arbitrary member color into a readable accent for the current
  /// brightness, without losing the hue the user picked.
  static Color readableAccent(Color color, Brightness brightness) {
    final hsl = HSLColor.fromColor(color);
    final lightness = brightness == Brightness.dark
        ? hsl.lightness.clamp(0.62, 0.80)
        : hsl.lightness.clamp(0.32, 0.48);
    return hsl
        .withLightness(lightness)
        .withSaturation(
          hsl.saturation.clamp(0.35, 0.9),
        )
        .toColor();
  }

  /// A very light wash of [accent] over [surface]. Used for member cards.
  static Color wash(Color accent, Color surface, Brightness brightness) {
    return Color.alphaBlend(
      accent.withValues(alpha: brightness == Brightness.dark ? 0.16 : 0.08),
      surface,
    );
  }

  /// Accent used by an overview metric, keyed by its label.
  static Color metricColor(String label, ColorScheme scheme) {
    if (label.contains('团切')) {
      return chekiGroup;
    }
    if (label.contains('宿')) {
      return label.startsWith('5') ? cheki5s : cheki3s;
    }
    if (label.startsWith('5')) {
      return cheki5;
    }
    if (label.startsWith('3')) {
      return cheki3;
    }
    return chekiCustom;
  }
}
