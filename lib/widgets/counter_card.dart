import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../models/counter_model.dart';

class CounterCard extends StatelessWidget {
  final CounterModel counter;
  final double percentage;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final bool isLocked;
  final int gridColumns;

  const CounterCard({
    super.key,
    required this.counter,
    required this.percentage,
    required this.onTap,
    this.onLongPress,
    required this.onDelete,
    required this.onEdit,
    this.isLocked = false,
    required this.gridColumns,
  });

  // 判断颜色是否为深色
  bool _isDarkColor(Color color) {
    return color.computeLuminance() < 0.5;
  }

  // 获取文本颜色
  Color _getTextColor(Color backgroundColor) {
    return _isDarkColor(backgroundColor)
        ? Colors.white.withValues(alpha: 0.9)
        : Colors.black87;
  }

  Widget _buildStatusIcons({
    required bool isLocked,
    required bool isHidden,
    required double size,
  }) {
    final icons = <Widget>[];

    if (isHidden) {
      icons.add(
        Icon(
          Icons.visibility_off_rounded,
          size: size,
          color: Colors.grey[700],
        ),
      );
    }
    if (isLocked) {
      if (icons.isNotEmpty) {
        icons.add(const SizedBox(width: 4));
      }
      icons.add(
        Icon(
          Icons.lock,
          size: size,
          color: Colors.grey[600],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: icons,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardColor = counter.colorValue;
    final textColor = _getTextColor(cardColor);
    final secondaryTextColor = textColor.withValues(alpha: 0.7);

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth;
        final statusIconSize = gridColumns >= 4 ? 12.0 : 14.0;
        final compact = gridColumns >= 3;
        final ultraCompact = gridColumns >= 5 || cardWidth < 80;
        final extraCompact = gridColumns >= 4 || cardWidth < 100;
        final showBreakdown = gridColumns <= 2;
        final showPercentage = !compact;
        final horizontalPadding = ultraCompact
            ? 7.0
            : compact
                ? 9.0
                : 12.0;
        final verticalPadding = ultraCompact
            ? 6.0
            : compact
                ? 7.0
                : 10.0;
        final buttonHeight = ultraCompact
            ? 14.0
            : compact
                ? (cardWidth * (extraCompact ? 0.18 : 0.16)).clamp(16.0, 22.0)
                : (constraints.maxHeight * 0.12).clamp(24.0, 36.0);
        final buttonIconSize = ultraCompact
            ? 10.0
            : compact
                ? (buttonHeight * 0.52).clamp(10.0, 13.0)
                : (buttonHeight * 0.5).clamp(14.0, 18.0);
        final buttonPadding = ultraCompact
            ? 0.5
            : compact
                ? (buttonHeight * 0.12).clamp(1.5, 3.5)
                : (buttonHeight * 0.15).clamp(4.0, 6.0);
        final metricWidth = math.min(
          88.0,
          cardWidth * 0.34,
        );
        final nameFontSize = ultraCompact
            ? 9.0
            : compact
                ? (extraCompact ? 10.0 : 11.5)
                : cardWidth < 200
                    ? 16.0
                    : 18.0;
        final groupFontSize = compact ? 9.5 : 12.0;
        final countFontSize = ultraCompact
            ? 22.0
            : compact
                ? (extraCompact ? 26.0 : 30.0)
                : cardWidth < 200
                    ? 32.0
                    : 36.0;
        final percentFontSize = compact ? 0.0 : 12.0;
        final headerGap = compact ? 0.0 : 10.0;
        final showGroupName =
            !compact && counter.groupName.isNotEmpty && cardWidth >= 95;
        final compactNameLines = gridColumns >= 5
            ? 2
            : gridColumns >= 4
                ? 3
                : 4;
        final actionSpacing = extraCompact ? buttonPadding : buttonPadding * 2;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: RepaintBoundary(
                child: GestureDetector(
                  onTap: isLocked ? null : onTap,
                  onLongPress: isLocked ? null : onLongPress,
                  child: Stack(
                    children: [
                      Opacity(
                        opacity: counter.isHidden ? 0.58 : 1,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: horizontalPadding,
                            vertical: verticalPadding,
                          ),
                          decoration: BoxDecoration(
                            color: cardColor.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(15),
                            boxShadow: [
                              BoxShadow(
                                color: cardColor.withValues(alpha: 0.3),
                                blurRadius: 8,
                                spreadRadius: 0.5,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (compact)
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.start,
                                    children: [
                                      if (isLocked || counter.isHidden)
                                        Align(
                                          alignment: Alignment.topRight,
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 4),
                                            child: _buildStatusIcons(
                                              isLocked: isLocked,
                                              isHidden: counter.isHidden,
                                              size: statusIconSize,
                                            ),
                                          ),
                                        ),
                                      Flexible(
                                        fit: FlexFit.loose,
                                        child: Text(
                                          counter.name,
                                          maxLines: compactNameLines,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: nameFontSize,
                                            fontWeight: FontWeight.w700,
                                            color: textColor,
                                            height: 1.08,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        height: ultraCompact ? 1 : 3,
                                      ),
                                      SizedBox(
                                        height: countFontSize,
                                        width: double.infinity,
                                        child: Align(
                                          alignment: Alignment.centerRight,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerRight,
                                            child: Text(
                                              counter.count.toString(),
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: countFontSize,
                                                fontWeight: FontWeight.bold,
                                                color: textColor,
                                                height: 1,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                )
                              else
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            counter.name,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: nameFontSize,
                                              fontWeight: FontWeight.w700,
                                              color: textColor,
                                            ),
                                          ),
                                          if (showGroupName) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              counter.groupName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: groupFontSize,
                                                color: secondaryTextColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: headerGap),
                                    SizedBox(
                                      width: metricWidth,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          if (isLocked || counter.isHidden)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 4,
                                              ),
                                              child: _buildStatusIcons(
                                                isLocked: isLocked,
                                                isHidden: counter.isHidden,
                                                size: statusIconSize,
                                              ),
                                            ),
                                          Text(
                                            counter.count.toString(),
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              fontSize: countFontSize,
                                              fontWeight: FontWeight.bold,
                                              color: textColor,
                                              height: 1,
                                            ),
                                          ),
                                          if (showPercentage) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              '${(percentage * 100).toStringAsFixed(1)}%',
                                              textAlign: TextAlign.right,
                                              style: TextStyle(
                                                fontSize: percentFontSize,
                                                color: secondaryTextColor,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              if (showBreakdown) ...[
                                const SizedBox(height: 12),
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.topLeft,
                                    child: _CountGrid(
                                      counter: counter,
                                      backgroundColor: cardColor,
                                      textColor: textColor,
                                    ),
                                  ),
                                ),
                              ] else if (!compact)
                                const Spacer(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: ultraCompact ? 0 : buttonPadding),
            SizedBox(
              height: buttonHeight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _ActionButton(
                      icon: Icons.edit,
                      onPressed: onEdit,
                      color: cardColor,
                      textColor: textColor,
                      size: buttonHeight,
                      iconSize: buttonIconSize,
                      padding: buttonPadding,
                    ),
                    SizedBox(width: actionSpacing),
                    _ActionButton(
                      icon: Icons.delete,
                      onPressed: onDelete,
                      color: cardColor,
                      textColor: textColor,
                      size: buttonHeight,
                      iconSize: buttonIconSize,
                      padding: buttonPadding,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CountGrid extends StatelessWidget {
  final CounterModel counter;
  final Color backgroundColor;
  final Color textColor;

  const _CountGrid({
    required this.counter,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final entries = counter.countEntries
        .where((entry) => entry.key != CounterCountField.groupCut)
        .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 300 ? 4 : 2;
        final itemWidth = math.max(
          0.0,
          (constraints.maxWidth - ((columns - 1) * 6)) / columns,
        );

        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: entries.map((entry) {
            return SizedBox(
              width: itemWidth,
              child: _CountBadge(
                field: entry.key,
                value: entry.value,
                backgroundColor: backgroundColor,
                textColor: textColor,
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _CountBadge extends StatelessWidget {
  final CounterCountField field;
  final int value;
  final Color backgroundColor;
  final Color textColor;

  const _CountBadge({
    required this.field,
    required this.value,
    required this.backgroundColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final isZero = value == 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor.withValues(alpha: isZero ? 0.12 : 0.22),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: textColor.withValues(alpha: isZero ? 0.08 : 0.16),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            field.shortLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: isZero ? 0.6 : 0.85),
            ),
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$value',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: textColor.withValues(alpha: isZero ? 0.65 : 0.95),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;
  final Color textColor;
  final double size;
  final double iconSize;
  final double padding;

  const _ActionButton({
    required this.icon,
    required this.onPressed,
    required this.color,
    required this.textColor,
    required this.size,
    required this.iconSize,
    required this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(size / 2),
          child: Container(
            padding: EdgeInsets.all(padding),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(size / 2),
            ),
            child: Icon(
              icon,
              size: iconSize,
              color: textColor.withValues(alpha: 0.8),
            ),
          ),
        ),
      ),
    );
  }
}
