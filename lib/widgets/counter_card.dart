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
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              // 将容器高度分成三份，分别给数字、百分比和名称
                              final containerHeight = constraints.maxHeight;
                              final numberHeight =
                                  containerHeight * 0.5; // 数字占50%
                              final percentageHeight =
                                  containerHeight * 0.25; // 百分比占25%
                              final nameHeight =
                                  containerHeight * 0.25; // 名称占25%

                              // 计算字体大小
                              final numberStr = counter.count.toString();
                              final numberSize =
                                  (numberHeight * 0.6).clamp(20.0, 48.0);
                              final adjustedNumberSize = numberStr.length > 3
                                  ? numberSize * (3 / numberStr.length)
                                  : numberSize;
                              final percentageSize =
                                  (percentageHeight * 0.5).clamp(12.0, 16.0);
                              final nameSize =
                                  (nameHeight * 0.5).clamp(14.0, 18.0);

                              return Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  SizedBox(
                                    height: numberHeight,
                                    child: Center(
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          numberStr,
                                          style: TextStyle(
                                            fontSize: adjustedNumberSize,
                                            fontWeight: FontWeight.bold,
                                            color: textColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    height: percentageHeight,
                                    child: Center(
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          '${(percentage * 100).toStringAsFixed(1)}%',
                                          style: TextStyle(
                                            fontSize: percentageSize,
                                            color: secondaryTextColor,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    height: nameHeight,
                                    child: Center(
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          counter.name,
                                          style: TextStyle(
                                            fontSize: nameSize,
                                            color: textColor,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          textAlign: TextAlign.center,
                                          maxLines: 1,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                      if (isLocked)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(
                            Icons.lock,
                            size: 16,
                            color: Colors.grey[600],
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
