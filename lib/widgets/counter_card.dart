import 'package:flutter/material.dart';
import '../models/counter_model.dart';

class CounterCard extends StatelessWidget {
  final CounterModel counter;
  final double percentage;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final bool isLocked;

  const CounterCard({
    super.key,
    required this.counter,
    required this.percentage,
    required this.onTap,
    required this.onDelete,
    required this.onEdit,
    this.isLocked = false,
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

  @override
  Widget build(BuildContext context) {
    final cardColor = counter.colorValue;
    final textColor = _getTextColor(cardColor);
    final secondaryTextColor = textColor.withValues(alpha: 0.7);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalHeight = constraints.maxHeight;
        final buttonHeight = (totalHeight * 0.12).clamp(24.0, 36.0);
        final buttonIconSize = (buttonHeight * 0.5).clamp(14.0, 18.0);
        final buttonPadding = (buttonHeight * 0.15).clamp(4.0, 6.0);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: RepaintBoundary(
                child: GestureDetector(
                  onTap: isLocked ? null : onTap,
                  child: Stack(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
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
                        child: Center(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      counter.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                                  ),
                                  if (isLocked)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: Icon(
                                        Icons.lock,
                                        size: 16,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Expanded(
                                child: Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          counter.count.toString(),
                                          style: TextStyle(
                                            fontSize: 44,
                                            fontWeight: FontWeight.bold,
                                            color: textColor,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '占比 ${(percentage * 100).toStringAsFixed(1)}%',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: secondaryTextColor,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              _CountGrid(
                                counter: counter,
                                backgroundColor: cardColor,
                                textColor: textColor,
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
            SizedBox(height: buttonPadding),
            SizedBox(
              height: buttonHeight,
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
                  SizedBox(width: buttonPadding * 2),
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
    final entries = counter.countEntries;
    final rows = <Widget>[];

    for (var i = 0; i < entries.length; i += 2) {
      rows.add(
        Padding(
          padding: EdgeInsets.only(bottom: i + 2 < entries.length ? 6 : 0),
          child: Row(
            children: [
              Expanded(
                child: _CountBadge(
                  field: entries[i].key,
                  value: entries[i].value,
                  backgroundColor: backgroundColor,
                  textColor: textColor,
                ),
              ),
              if (i + 1 < entries.length) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: _CountBadge(
                    field: entries[i + 1].key,
                    value: entries[i + 1].value,
                    backgroundColor: backgroundColor,
                    textColor: textColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: rows,
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
      child: Row(
        children: [
          Expanded(
            child: Text(
              field.shortLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: textColor.withValues(alpha: isZero ? 0.6 : 0.85),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '$value',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: textColor.withValues(alpha: isZero ? 0.65 : 0.95),
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
