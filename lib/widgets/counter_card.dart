import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../services/settings_service.dart';
import '../theme/app_theme.dart';

class CounterCountBadgeData {
  final String label;
  final int value;

  const CounterCountBadgeData({
    required this.label,
    required this.value,
  });
}

/// A member summary tile.
///
/// The card is a light wash of the member's chosen color with a slim accent
/// rail, so the name, group and count keep strong contrast in both themes.
/// Compact grids (3-5 columns) drop the breakdown and use a shorter layout.
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
    final isDark = theme.brightness == Brightness.dark;
    final accent =
        AppTheme.readableAccent(counter.colorValue, theme.brightness);
    final background = AppTheme.wash(accent, scheme.surface, theme.brightness);
    final borderColor = Color.alphaBlend(
      accent.withValues(alpha: isDark ? 0.34 : 0.20),
      scheme.surface,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = gridColumns >= 3;
        final ultraCompact = gridColumns >= 5 || width < 88;
        final extraCompact = gridColumns >= 4 || width < 104;
        final showBreakdown = gridColumns <= 2;
        final cardScale = textScale ?? SettingsService.fontScale.value;
        final safeCardScale = cardScale > 0 ? cardScale : 1.0;
        final systemTextScale = MediaQuery.textScalerOf(context).scale(1.0);
        final effectiveTextScale = systemTextScale * safeCardScale;
        final horizontalPadding = ultraCompact ? 7.0 : (compact ? 9.0 : 14.0);
        final verticalPadding = ultraCompact ? 7.0 : (compact ? 9.0 : 13.0);
        final radius = compact ? 18.0 : 22.0;
        final nameFontSize = ultraCompact
            ? 9.5
            : compact
                ? (extraCompact ? 10.5 : 11.5)
                : (width < 190 ? 15.0 : 17.0);
        final countFontSize = ultraCompact
            ? 23.0
            : compact
                ? (extraCompact ? 27.0 : 30.0)
                : (width < 190 ? 38.0 : 44.0);

        final card = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: compact
                ? null
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: isDark ? 0 : 0.05),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(radius),
            clipBehavior: Clip.antiAlias,
            child: Ink(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    background,
                    Color.alphaBlend(
                      accent.withValues(alpha: isDark ? 0.045 : 0.025),
                      scheme.surface,
                    ),
                  ],
                ),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: borderColor),
              ),
              child: InkWell(
                onTap: isLocked ? null : onTap,
                onLongPress: isLocked ? null : onLongPress,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: compact ? 3 : 4,
                      // The member's 应援色 as a solid penlight stripe.
                      child: ColoredBox(color: accent),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding + 3,
                        verticalPadding,
                        horizontalPadding,
                        verticalPadding,
                      ),
                      child: compact
                          ? _CompactCardBody(
                              counter: counter,
                              totalCount: totalCount,
                              accent: accent,
                              nameFontSize: nameFontSize,
                              countFontSize: countFontSize,
                              isLocked: isLocked,
                              isHidden: counter.isHidden,
                              showAvatar: gridColumns <= 4,
                              onEdit: onEdit,
                              onDelete: onDelete,
                              onLongPress: onLongPress,
                            )
                          : _RegularCardBody(
                              counter: counter,
                              totalCount: totalCount,
                              breakdownEntries: breakdownEntries,
                              percentage: percentage,
                              accent: accent,
                              nameFontSize: nameFontSize,
                              countFontSize: countFontSize,
                              isLocked: isLocked,
                              showBreakdown: showBreakdown,
                              onEdit: onEdit,
                              onDelete: onDelete,
                              onLongPress: onLongPress,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        // Scale only this card's text, on top of the phone's own font size.
        // The rest of the app keeps the normal MaterialApp text scaling.
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

class _RegularCardBody extends StatelessWidget {
  final CounterModel counter;
  final int totalCount;
  final List<CounterCountBadgeData> breakdownEntries;
  final double percentage;
  final Color accent;
  final double nameFontSize;
  final double countFontSize;
  final bool isLocked;
  final bool showBreakdown;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;

  const _RegularCardBody({
    required this.counter,
    required this.totalCount,
    required this.breakdownEntries,
    required this.percentage,
    required this.accent,
    required this.nameFontSize,
    required this.countFontSize,
    required this.isLocked,
    required this.showBreakdown,
    required this.onEdit,
    required this.onDelete,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visibleBreakdown = breakdownEntries
        .where((entry) => entry.value > 0)
        .toList(growable: false);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Avatar, status icons and the menu share the top row; the name and
        // group get the full width underneath.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(
              label: _initial(counter.name),
              accent: accent,
              size: 38,
            ),
            const Spacer(),
            if (isLocked || counter.isHidden)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2, right: 2),
                child: _StatusIcons(
                  isLocked: isLocked,
                  isHidden: counter.isHidden,
                  color: scheme.onSurfaceVariant,
                  size: 13,
                ),
              ),
            _CardMenu(
              onEdit: onEdit,
              onDelete: onDelete,
              onLongPress: onLongPress,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          counter.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontSize: nameFontSize,
            fontWeight: FontWeight.w800,
            height: 1.18,
            color: scheme.onSurface,
          ),
        ),
        if (counter.groupName.trim().isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            counter.groupName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              fontSize: 11,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '$totalCount',
                      style: TextStyle(
                        fontSize: countFontSize,
                        fontWeight: FontWeight.w900,
                        height: 0.95,
                        letterSpacing: -1.2,
                        color: scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 5),
                      child: Text(
                        '张',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            _PercentBadge(
              percentage: percentage,
              accent: accent,
            ),
          ],
        ),
        if (showBreakdown) ...[
          if (visibleBreakdown.isNotEmpty) ...[
            const SizedBox(height: 10),
            _CountChips(
              entries: visibleBreakdown,
              accent: accent,
            ),
          ],
        ],
      ],
    );
  }

  static String _initial(String name) {
    final trimmed = name.trim();
    return trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
  }
}

class _CompactCardBody extends StatelessWidget {
  final CounterModel counter;
  final int totalCount;
  final Color accent;
  final double nameFontSize;
  final double countFontSize;
  final bool isLocked;
  final bool isHidden;
  final bool showAvatar;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;

  const _CompactCardBody({
    required this.counter,
    required this.totalCount,
    required this.accent,
    required this.nameFontSize,
    required this.countFontSize,
    required this.isLocked,
    required this.isHidden,
    required this.showAvatar,
    required this.onEdit,
    required this.onDelete,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final name = Text(
      counter.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(
        fontSize: nameFontSize,
        fontWeight: FontWeight.w800,
        height: 1.12,
        color: scheme.onSurface,
      ),
    );

    // The top row holds only the avatar, status icons and menu. The name and
    // group then use the full card width, which keeps 3-character names on one
    // line even in a 5-column grid.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showAvatar)
              _Avatar(
                label: counter.name.trim().isEmpty
                    ? '?'
                    : counter.name.trim().substring(0, 1).toUpperCase(),
                accent: accent,
                size: 24,
              ),
            const Spacer(),
            if (isLocked || isHidden)
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 1),
                child: _StatusIcons(
                  isLocked: isLocked,
                  isHidden: isHidden,
                  color: scheme.onSurfaceVariant,
                  size: 11,
                ),
              ),
            _CardMenu(
              onEdit: onEdit,
              onDelete: onDelete,
              onLongPress: onLongPress,
              color: scheme.onSurfaceVariant,
              iconSize: 18,
              compact: true,
            ),
          ],
        ),
        SizedBox(height: showAvatar ? 5 : 4),
        name,
        if (counter.groupName.trim().isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            counter.groupName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 9,
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
        const Spacer(),
        Align(
          alignment: Alignment.bottomRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              '$totalCount',
              maxLines: 1,
              style: TextStyle(
                fontSize: countFontSize,
                fontWeight: FontWeight.w900,
                height: 1,
                letterSpacing: -0.8,
                color: scheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  final String label;
  final Color accent;
  final double size;

  const _Avatar({
    required this.label,
    required this.accent,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent.withValues(alpha: 0.14),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
          color: accent,
        ),
      ),
    );
  }
}

class _PercentBadge extends StatelessWidget {
  final double percentage;
  final Color accent;

  const _PercentBadge({
    required this.percentage,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.14)),
      ),
      child: Text(
        '${(percentage * 100).toStringAsFixed(1)}%',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: accent,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
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
            color: color.withValues(alpha: 0.75),
          ),
        if (isHidden && isLocked) const SizedBox(width: 3),
        if (isLocked)
          Icon(
            Icons.lock_rounded,
            size: size,
            color: color.withValues(alpha: 0.75),
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
        width: compact ? 22 : 28,
        height: compact ? 24 : 28,
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
      spacing: 6,
      runSpacing: 6,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.075),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            '$value',
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 13,
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
/// Reserves two name lines, a full-width group line, the total row and enough
/// breakdown rows for [breakdownEntryCount]. Scaling this with the 卡片字号
/// setting keeps the fixed grid extent from clipping card content.
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
    final countFontSize = itemWidth < 190 ? 38.0 : 44.0;
    final innerWidth = math.max(0.0, itemWidth - 31.0);

    // Compact count chips sit in a Wrap. Estimate their width from the label
    // plus a two-digit value; the estimate is intentionally a little wide so
    // scaled-up text never makes the last chip spill out of the card.
    final chipWidth = 80.0 * scale;
    final chipHeight = 24.0 + 6.0 * math.max(1.0, scale);
    final chipColumns = breakdownEntryCount <= 0
        ? 0
        : math
            .max(
              1,
              ((innerWidth + 6.0) / (chipWidth + 6.0)).floor(),
            )
            .clamp(1, 5);
    final chipRows = chipColumns == 0
        ? 0
        : (breakdownEntryCount + chipColumns - 1) ~/ chipColumns;
    final chipBlockHeight = chipRows == 0
        ? 0.0
        : 10.0 + chipRows * chipHeight + (chipRows - 1) * 6.0;

    final contentHeight = 2 * 13.0 +
        38.0 +
        8.0 +
        2 * nameFontSize * 1.18 * scale +
        3.0 +
        11.0 * 1.2 * scale +
        10.0 +
        countFontSize * 0.95 * scale +
        chipBlockHeight;
    return math.max(0.0, contentHeight);
  }

  final verticalPadding = gridColumns >= 5 ? 7.0 : 9.0;
  final nameFontSize =
      gridColumns >= 5 ? 9.5 : (gridColumns >= 4 ? 10.5 : 11.5);
  final countFontSize =
      gridColumns >= 5 ? 23.0 : (gridColumns >= 4 ? 27.0 : 30.0);
  final contentHeight = 2 * verticalPadding +
      24.0 +
      (gridColumns <= 4 ? 5.0 : 4.0) +
      2 * nameFontSize * 1.12 * scale +
      2.0 +
      9.0 * 1.2 * scale +
      6.0 +
      countFontSize * scale +
      8.0;
  final baseHeight = switch (gridColumns) {
    3 => 140.0,
    4 => 108.0,
    _ => 94.0,
  };
  return math.max(baseHeight, contentHeight);
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
    // Group cuts are part of the counter total, so keep them visible in the
    // breakdown too; otherwise a card can show 301 while its tiles add up to
    // 297 and the missing count looks lost.
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
