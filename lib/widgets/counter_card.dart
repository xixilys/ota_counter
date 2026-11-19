import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/member_short_name.dart';
import '../services/settings_service.dart';
import 'dream/dream_kit.dart';

class CounterCountBadgeData {
  final String label;
  final int value;

  const CounterCountBadgeData({
    required this.label,
    required this.value,
  });
}

/// A member summary printed as a collectible cheki trading card.
///
/// The card is a polaroid print in the member's 応援色: a small tinted "stage"
/// photo with the member's initial, washi tape, the name and group on the white
/// bottom margin and the total as a die-cut sticker. In 3-5 column grids the
/// photo shrinks so cards stay scannable; in 1-2 column grids the full
/// breakdown is printed underneath. The member's own colour, not a generic
/// grey surface, carries the card identity.
class CounterCard extends StatelessWidget {
  final CounterModel counter;
  final int totalCount;
  final List<CounterCountBadgeData> breakdownEntries;
  final double percentage;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final bool isLocked;
  final int gridColumns;

  /// Member-card-only text scale. When omitted the 卡片字号 setting is used.
  final double? textScale;

  const CounterCard({
    super.key,
    required this.counter,
    required this.totalCount,
    this.breakdownEntries = const [],
    required this.percentage,
    required this.onTap,
    this.onLongPress,
    required this.onDelete,
    required this.onEdit,
    this.isLocked = false,
    required this.gridColumns,
    this.textScale,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final rawColor = counter.colorValue;
    final accent = DreamPalette.accent(rawColor, brightness);
    final photoColor = DreamPalette.photo(rawColor, brightness);
    final tapeColor = DreamPalette.tape(rawColor, brightness);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = gridColumns >= 3;
        final ultraCompact = gridColumns >= 5 || width < 88;
        final dense = gridColumns >= 4 || width < 104;
        final showBreakdown = gridColumns <= 2;
        final cardScale = textScale ?? SettingsService.fontScale.value;
        final safeCardScale = cardScale > 0 ? cardScale : 1.0;
        final systemTextScale = MediaQuery.textScalerOf(context).scale(1.0);
        final effectiveTextScale = systemTextScale * safeCardScale;

        final photoHeight = compact
            ? (ultraCompact
                ? 25.0
                : dense
                    ? 31.0
                    : 48.0)
            : (width < 190 ? 96.0 : (width < 280 ? 124.0 : 140.0));
        final nameFontSize = ultraCompact
            ? 9.5
            : compact
                ? (dense ? 10.5 : 11.5)
                : (width < 190 ? 15.0 : 17.0);
        final groupFontSize = ultraCompact
            ? 8.0
            : compact
                ? (dense ? 8.5 : 9.5)
                : (width < 190 ? 11.0 : 12.0);
        final countFontSize = ultraCompact
            ? 16.0
            : compact
                ? (dense ? 19.0 : 21.0)
                : (width < 190 ? 30.0 : 36.0);
        final framePadding = compact
            ? const EdgeInsets.fromLTRB(3, 3, 3, 3)
            : const EdgeInsets.fromLTRB(5, 5, 5, 5);
        final tapeSize = compact
            ? (ultraCompact ? const Size(24, 8) : const Size(30, 10))
            : const Size(46, 14);

        final stage = _ChekiStage(
          name: counter.name,
          shortName: counter.displayShortName,
          photoColor: photoColor,
          accent: accent,
          photoHeight: photoHeight,
          compact: compact,
          ultraCompact: ultraCompact,
          isLocked: isLocked,
          isHidden: counter.isHidden,
          menu: _CardMenu(
            onEdit: onEdit,
            onDelete: onDelete,
            onLongPress: onLongPress,
            color: DreamPalette.onColor(photoColor).withValues(alpha: 0.86),
            iconSize: ultraCompact ? 16 : (compact ? 17 : 20),
            compact: compact,
          ),
        );

        final Widget cardContent;
        if (gridColumns == 1) {
          cardContent = _WideMemberCard(
            stage: stage,
            name: counter.name,
            groupName: counter.groupName,
            totalCount: totalCount,
            percentage: percentage,
            breakdownEntries: breakdownEntries,
            accent: accent,
            scheme: scheme,
            rawColor: rawColor,
            brightness: brightness,
            countFontSize: countFontSize,
          );
        } else {
          cardContent = PolaroidFrame(
            frameColor: DreamPalette.frame(brightness),
            framePadding: framePadding,
            photoRadius: compact ? 2 : 3,
            tapeColor: tapeColor,
            tapeWidth: tapeSize.width,
            tapeHeight: tapeSize.height,
            tapeAngle: -0.16,
            tapeTop: compact ? -3 : -5,
            tapeLeft: compact ? -5 : -8,
            expandPhoto: compact,
            captionTop: compact ? 4 : 6,
            captionBottom: compact ? 1 : 4,
            photo: stage,
            caption: _CardCaption(
              name: counter.name,
              groupName: counter.groupName,
              totalCount: totalCount,
              percentage: percentage,
              nameFontSize: nameFontSize,
              groupFontSize: groupFontSize,
              countFontSize: countFontSize,
              accent: accent,
              scheme: scheme,
              compact: compact,
              ultraCompact: ultraCompact,
              showBreakdown: showBreakdown,
              breakdownEntries: breakdownEntries,
            ),
          );
        }

        final card = Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: isLocked ? null : onTap,
            onLongPress: isLocked ? null : onLongPress,
            borderRadius: BorderRadius.circular(8),
            child: cardContent,
          ),
        );

        final scaledCard = safeCardScale == 1.0
            ? card
            : MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(effectiveTextScale),
                ),
                child: card,
              );
        return RepaintBoundary(
          child: Opacity(
            opacity: counter.isHidden ? 0.58 : 1,
            child: scaledCard,
          ),
        );
      },
    );
  }
}

/// One-column member "album page": a portrait print on the left, the same
/// caption stack on the right. Keeps a wide phone row from turning into a
/// full-width card with a large empty middle.
class _WideMemberCard extends StatelessWidget {
  final Widget stage;
  final String name;
  final String groupName;
  final int totalCount;
  final double percentage;
  final List<CounterCountBadgeData> breakdownEntries;
  final Color accent;
  final ColorScheme scheme;
  final Color rawColor;
  final Brightness brightness;
  final double countFontSize;

  const _WideMemberCard({
    required this.stage,
    required this.name,
    required this.groupName,
    required this.totalCount,
    required this.percentage,
    required this.breakdownEntries,
    required this.accent,
    required this.scheme,
    required this.rawColor,
    required this.brightness,
    required this.countFontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: DreamPalette.frame(brightness),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: DreamPalette.hairline(brightness)),
            boxShadow: DreamPalette.pageShadow(brightness),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  width: 150,
                  height: 170,
                  child: stage,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 4, 6),
                  child: _CardCaption(
                    name: name,
                    groupName: groupName,
                    totalCount: totalCount,
                    percentage: percentage,
                    nameFontSize: 17,
                    groupFontSize: 12,
                    countFontSize: countFontSize,
                    accent: accent,
                    scheme: scheme,
                    compact: false,
                    ultraCompact: false,
                    showBreakdown: true,
                    breakdownEntries: breakdownEntries,
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(
          top: -6,
          left: 24,
          child: WashiTape(
            color: DreamPalette.tape(rawColor, brightness),
            width: 50,
            height: 15,
            angle: -0.12,
          ),
        ),
      ],
    );
  }
}

/// The tinted "photo" area of the print: member colour, the member's short
/// text as a watermark and a tiny penlight bar. No circles, no generic avatar.
class _ChekiStage extends StatelessWidget {
  final String name;

  /// 1-4 characters printed in the photo. Defaults to a name-derived short
  /// name (see [resolveMemberShortName]).
  final String? shortName;
  final Color photoColor;
  final Color accent;
  final double photoHeight;
  final bool compact;
  final bool ultraCompact;
  final bool isLocked;
  final bool isHidden;
  final Widget menu;

  const _ChekiStage({
    required this.name,
    this.shortName,
    required this.photoColor,
    required this.accent,
    required this.photoHeight,
    required this.compact,
    required this.ultraCompact,
    required this.isLocked,
    required this.isHidden,
    required this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final ink = DreamPalette.onColor(photoColor);
    final glyph = resolveMemberShortName(name: name, configured: shortName);
    final glyphLength = memberShortNameLength(glyph);
    // One character stays a giant watermark; 2-4 characters shrink just
    // enough to stay inside the photo at 2-5 columns.
    final glyphScale = switch (glyphLength) {
      1 => 1.0,
      2 => 0.66,
      3 => 0.5,
      _ => 0.4,
    };
    final deep = HSLColor.fromColor(photoColor)
        .withLightness(
          (HSLColor.fromColor(photoColor).lightness - 0.06).clamp(0.0, 1.0),
        )
        .toColor();

    return SizedBox(
      height: photoHeight,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 2 : 3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stageHeight = constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : photoHeight;
            return Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [photoColor, deep],
                    ),
                  ),
                ),
                CustomPaint(
                  painter: _StagePainter(ink: ink, accent: accent),
                ),
                if (!compact)
                  Positioned(
                    left: -8,
                    bottom: -photoHeight * 0.24,
                    child: Text(
                      glyph,
                      textScaler: TextScaler.noScaling,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: _fitGlyphFontSize(
                          desired: photoHeight * 0.92 * glyphScale,
                          maxWidth: constraints.maxWidth,
                          glyph: glyph,
                        ),
                        height: 1,
                        fontWeight: FontWeight.w900,
                        color: ink.withValues(alpha: 0.16),
                      ),
                    ),
                  )
                else
                  Positioned(
                    left: 6,
                    bottom: math.max(2.0, stageHeight * 0.04),
                    child: Text(
                      glyph,
                      textScaler: TextScaler.noScaling,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        fontSize: _fitGlyphFontSize(
                          desired: math.max(
                            9,
                            stageHeight *
                                (ultraCompact ? 0.46 : 0.52) *
                                glyphScale,
                          ),
                          maxWidth: constraints.maxWidth - 12,
                          glyph: glyph,
                        ),
                        height: 1,
                        fontWeight: FontWeight.w900,
                        color: ink.withValues(alpha: 0.92),
                      ),
                    ),
                  ),
                if (!compact)
                  Positioned(
                    right: 9,
                    bottom: 8,
                    child: SparkleMark(
                      size: 18,
                      color: ink.withValues(alpha: 0.66),
                      variant: SparkleVariant.sparkle,
                      dot: true,
                    ),
                  ),
                if (!compact)
                  Positioned(
                    right: 9,
                    bottom: 9,
                    child: Row(
                      children: [
                        for (var i = 0; i < 3; i++)
                          Container(
                            width: 3.5,
                            height: 18,
                            margin: const EdgeInsets.only(left: 3),
                            decoration: BoxDecoration(
                              color: ink.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (compact && stageHeight > 34)
                  Positioned(
                    right: 25,
                    top: 5,
                    child: SparkleMark(
                      size: math.min(11.0, stageHeight * 0.22),
                      color: ink.withValues(alpha: 0.52),
                      variant: SparkleVariant.sparkle,
                    ),
                  ),
                Positioned(
                  top: 1,
                  right: 0,
                  child: Row(
                    children: [
                      if (isLocked || isHidden)
                        Padding(
                          padding: const EdgeInsets.only(right: 1),
                          child: _StatusIcons(
                            isLocked: isLocked,
                            isHidden: isHidden,
                            color: ink.withValues(alpha: 0.8),
                            size: compact ? 10 : 12,
                          ),
                        ),
                      menu,
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Approximate width of one glyph relative to its font size.
double _glyphAspect(String glyph) =>
    RegExp(r'^[A-Za-z0-9]+$').hasMatch(glyph) ? 0.62 : 1.0;

/// Caps a desired font size so 1-4 characters stay inside [maxWidth].
double _fitGlyphFontSize({
  required double desired,
  required double maxWidth,
  required String glyph,
}) {
  final length = math.max(1, memberShortNameLength(glyph));
  final cap = maxWidth * 0.88 / (length * _glyphAspect(glyph));
  return math.min(desired, cap);
}

class _StagePainter extends CustomPainter {
  final Color ink;
  final Color accent;

  const _StagePainter({required this.ink, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    // Two soft light beams, like a small stage spotlight on the print.
    final beam = Path()
      ..moveTo(size.width * 0.18, size.height)
      ..lineTo(size.width * 0.44, 0)
      ..lineTo(size.width * 0.62, 0)
      ..lineTo(size.width * 0.36, size.height)
      ..close();
    canvas.drawPath(
      beam,
      Paint()..color = ink.withValues(alpha: 0.06),
    );
    // A fine diagonal "photo grain" line.
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 0.14),
      Offset(size.width * 0.92, size.height * 0.14),
      Paint()
        ..color = ink.withValues(alpha: 0.12)
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(_StagePainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.accent != accent;
}

class _CardCaption extends StatelessWidget {
  final String name;
  final String groupName;
  final int totalCount;
  final double percentage;
  final double nameFontSize;
  final double groupFontSize;
  final double countFontSize;
  final Color accent;
  final ColorScheme scheme;
  final bool compact;
  final bool ultraCompact;
  final bool showBreakdown;
  final List<CounterCountBadgeData> breakdownEntries;

  const _CardCaption({
    required this.name,
    required this.groupName,
    required this.totalCount,
    required this.percentage,
    required this.nameFontSize,
    required this.groupFontSize,
    required this.countFontSize,
    required this.accent,
    required this.scheme,
    required this.compact,
    required this.ultraCompact,
    required this.showBreakdown,
    required this.breakdownEntries,
  });

  @override
  Widget build(BuildContext context) {
    final visibleBreakdown = breakdownEntries
        .where((entry) => entry.value > 0)
        .toList(growable: false);
    final hasGroup = groupName.trim().isNotEmpty;
    final nameText = Text(
      name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: nameFontSize,
        fontWeight: FontWeight.w800,
        height: compact ? 1.14 : 1.18,
        color: scheme.onSurface,
      ),
    );
    final groupText = hasGroup
        ? Text(
            groupName,
            maxLines: compact ? 2 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: groupFontSize,
              fontWeight: FontWeight.w600,
              height: compact ? 1.12 : 1.2,
              color: scheme.onSurfaceVariant,
            ),
          )
        : null;

    final sticker = StickerBadge(
      value: '$totalCount',
      label: '张',
      color: accent,
      outlineWidth: compact ? 1.5 : 2.5,
      padding: EdgeInsets.symmetric(
        horizontal: ultraCompact ? 5 : (compact ? 7 : 10),
        vertical: ultraCompact ? 1.5 : (compact ? 2 : 3),
      ),
      valueFontSize: countFontSize,
      labelFontSize: ultraCompact ? 7.5 : (compact ? 8 : 9),
      minWidth: ultraCompact ? 27 : (compact ? 32 : 52),
      semanticLabel: '$name 共 $totalCount 张',
    );

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          nameText,
          if (groupText != null) ...[
            const SizedBox(height: 1),
            groupText,
          ],
          const SizedBox(height: 3),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: sticker,
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        nameText,
        if (groupText != null) ...[
          const SizedBox(height: 2),
          groupText,
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.bottomRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: sticker,
          ),
        ),
        if (percentage >= 0)
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '占 ${(percentage * 100).toStringAsFixed(1)}%',
              maxLines: 1,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        if (showBreakdown && visibleBreakdown.isNotEmpty) ...[
          const SizedBox(height: 8),
          _CountChips(entries: visibleBreakdown, accent: accent),
        ],
      ],
    );
  }
}

class _StatusIcons extends StatelessWidget {
  final bool isLocked;
  final bool isHidden;
  final Color color;
  final double size;

  const _StatusIcons({
    required this.isLocked,
    required this.isHidden,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isHidden)
          Icon(
            Icons.visibility_off_rounded,
            size: size,
            color: color,
          ),
        if (isHidden && isLocked) const SizedBox(width: 2),
        if (isLocked)
          Icon(
            Icons.lock_rounded,
            size: size,
            color: color,
          ),
      ],
    );
  }
}

class _CardMenu extends StatelessWidget {
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;
  final Color color;
  final double iconSize;
  final bool compact;

  const _CardMenu({
    required this.onEdit,
    required this.onDelete,
    required this.onLongPress,
    required this.color,
    this.iconSize = 20,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '卡片操作',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (value) {
        switch (value) {
          case 'edit':
            onEdit();
          case 'delete':
            onDelete();
          case 'manage':
            onLongPress?.call();
        }
      },
      child: SizedBox(
        width: compact ? 22 : 34,
        height: compact ? 24 : 34,
        child: Icon(
          Icons.more_horiz_rounded,
          size: iconSize,
          color: color,
        ),
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'edit',
          child: _MenuItem(
            icon: Icons.edit_outlined,
            label: '编辑',
          ),
        ),
        if (onLongPress != null)
          PopupMenuItem(
            value: 'manage',
            child: _MenuItem(
              icon: Icons.tune_rounded,
              label: '更多操作',
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          child: _MenuItem(
            icon: Icons.delete_outline_rounded,
            label: '删除',
            destructive: true,
          ),
        ),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;

  const _MenuItem({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : scheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _CountChips extends StatelessWidget {
  final List<CounterCountBadgeData> entries;
  final Color accent;

  const _CountChips({
    required this.entries,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final entry in entries)
          _SpecChip(
            key: ValueKey<String>('count-chip-${entry.label}'),
            label: entry.label,
            value: entry.value,
            accent: accent,
          ),
      ],
    );
  }
}

class _SpecChip extends StatelessWidget {
  final String label;
  final int value;
  final Color accent;

  const _SpecChip({
    super.key,
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$value',
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w900,
              height: 1,
              color: scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Height the home grid should give a member card.
///
/// Reserves the photo, two name lines, two group lines, the count sticker and
/// enough breakdown rows for [breakdownEntryCount]. Scaling this with the
/// 卡片字号 setting keeps the fixed grid extent from clipping card content.
double counterCardHeight({
  required int gridColumns,
  required double availableWidth,
  required double crossAxisSpacing,
  required double textScale,
  int breakdownEntryCount = 4,
}) {
  final scale = textScale > 0 ? textScale : 1.0;
  final itemWidth = math.max(
    0.0,
    (availableWidth - ((gridColumns - 1) * crossAxisSpacing)) / gridColumns,
  );

  if (gridColumns <= 2) {
    final nameFontSize = itemWidth < 190 ? 15.0 : 17.0;
    final groupFontSize = itemWidth < 190 ? 11.0 : 12.0;
    final countFontSize = itemWidth < 190 ? 30.0 : 36.0;
    final photoHeight = itemWidth < 190 ? 96.0 : 128.0;
    final innerWidth = math.max(0.0, itemWidth - 24.0);

    // The breakdown chips use a Wrap; approximate their footprint a little
    // wide so scaled-up text never spills out of the polaroid.
    final chipWidth = 72.0 * scale;
    final chipHeight = 22.0 + 4.0 * math.max(1.0, scale);
    final chipColumns = breakdownEntryCount <= 0
        ? 0
        : math
            .max(
              1,
              ((innerWidth + 5.0) / (chipWidth + 5.0)).floor(),
            )
            .clamp(1, 5);
    final chipRows = chipColumns == 0
        ? 0
        : (breakdownEntryCount + chipColumns - 1) ~/ chipColumns;

    final contentHeight = 2 * 5.0 +
        photoHeight +
        6.0 +
        2 * nameFontSize * 1.18 * scale +
        2.0 +
        2 * groupFontSize * 1.2 * scale +
        8.0 +
        (countFontSize + 18.0) * scale +
        8.0 +
        (chipRows == 0 ? 0.0 : chipRows * chipHeight + (chipRows - 1) * 5.0);
    return math.max(0.0, contentHeight);
  }

  final photoHeight = gridColumns >= 5
      ? 25.0
      : gridColumns >= 4
          ? 31.0
          : 48.0;
  final nameFontSize =
      gridColumns >= 5 ? 9.5 : (gridColumns >= 4 ? 10.5 : 11.5);
  final groupFontSize = gridColumns >= 5 ? 8.0 : (gridColumns >= 4 ? 8.5 : 9.5);
  final countFontSize =
      gridColumns >= 5 ? 16.0 : (gridColumns >= 4 ? 19.0 : 21.0);
  const padding = 3.0;
  const compactCaptionTop = 4.0;
  const compactCaptionBottom = 2.0;
  // The compact card now sizes its caption to its content and the grid gives
  // it exactly this extent, so reserve only what is actually printed: the
  // photo, name, group, the count sticker and the frame padding.
  final stickerHeight = countFontSize * 1.05 * scale +
      2 * (gridColumns >= 5 ? 1.5 : 2.0) +
      (gridColumns >= 5 ? 7.5 : 8.0) * 1.05 +
      2.0;
  final contentHeight = 2 * padding +
      photoHeight +
      compactCaptionTop +
      2 * nameFontSize * 1.14 * scale +
      1.0 +
      2 * groupFontSize * 1.12 * scale +
      3.0 +
      stickerHeight +
      compactCaptionBottom;
  return contentHeight;
}

/// Builds the count tiles shown on a home card.
///
/// Kept as a top-level function so tests can assert that the tiles add up to
/// the card's total (including group cuts and custom cheki types).
List<CounterCountBadgeData> buildHomeBreakdownEntries(
  CounterModel counter,
  Map<String, int> customCounts,
) {
  final sortedCustomEntries = customCounts.entries.toList()
    ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
  return [
    CounterCountBadgeData(
      label: CounterCountField.threeInch.shortLabel,
      value: counter.aggregatedThreeInchCount,
    ),
    CounterCountBadgeData(
      label: CounterCountField.fiveInch.shortLabel,
      value: counter.aggregatedFiveInchCount,
    ),
    CounterCountBadgeData(
      label: CounterCountField.threeInchShukudai.shortLabel,
      value: counter.threeInchShukudaiCount,
    ),
    CounterCountBadgeData(
      label: CounterCountField.fiveInchShukudai.shortLabel,
      value: counter.fiveInchShukudaiCount,
    ),
    if (counter.groupCutCount > 0)
      CounterCountBadgeData(
        label: CounterCountField.groupCut.shortLabel,
        value: counter.groupCutCount,
      ),
    ...sortedCustomEntries.map((entry) {
      return CounterCountBadgeData(
        label: entry.key,
        value: entry.value,
      );
    }),
  ];
}
