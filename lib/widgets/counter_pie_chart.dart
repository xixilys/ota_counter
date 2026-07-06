import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../models/counter_model.dart';
import 'dart:math';

class CounterPieChart extends StatefulWidget {
  final List<CounterModel> counters;
  final int total;
  final bool showLegend; // 添加控制图例显示的参数

  const CounterPieChart({
    super.key,
    required this.counters,
    required this.total,
    this.showLegend = true, // 默认显示图例
  });

  @override
  State<CounterPieChart> createState() => _CounterPieChartState();
}

class _CounterPieChartState extends State<CounterPieChart> {
  int? _touchedIndex;
  bool _showName = true; // 显示名称
  bool _showCount = true; // 显示数量
  bool _showPercent = true; // 显示百分比
  // 计算文字位置，确保在屏幕内
  Offset _calculateTextPosition(
    double centerX,
    double centerY,
    double radius,
    double startAngle,
    double sweepAngle,
    Size textSize,
    Size chartSize,
  ) {
    // 计算扇形中心角度
    final angle = startAngle + sweepAngle / 2;

    // 计算基础位置（比半径远一点）
    final distance = radius * 1.3;
    var x = centerX + distance * cos(angle);
    var y = centerY + distance * sin(angle);

    // 调整文字位置确保在屏幕内
    final padding = 8.0;

    // 左边界
    if (x - textSize.width / 2 < padding) {
      x = padding + textSize.width / 2;
    }
    // 右边界
    if (x + textSize.width / 2 > chartSize.width - padding) {
      x = chartSize.width - padding - textSize.width / 2;
    }
    // 上边界
    if (y - textSize.height / 2 < padding) {
      y = padding + textSize.height / 2;
    }
    // 下边界
    if (y + textSize.height / 2 > chartSize.height - padding) {
      y = chartSize.height - padding - textSize.height / 2;
    }

    return Offset(x, y);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.counters.isEmpty || widget.total == 0) {
      return const Center(child: Text('暂无数据'));
    }

    // 获取屏幕尺寸
    final screenSize = MediaQuery.of(context).size;
    final isPortrait = screenSize.height > screenSize.width;

    // 使用父组件传入的尺寸，或者使用默认计算
    final chartSize = isPortrait
        ? screenSize.width * 0.95 // 从0.9增加到0.95
        : screenSize.height * 0.85; // 从0.7增加到0.85

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: chartSize,
            width: chartSize,
            child: Stack(
              children: [
                PieChart(
                  PieChartData(
                    pieTouchData: PieTouchData(
                      touchCallback: (FlTouchEvent event, pieTouchResponse) {
                        setState(() {
                          if (!event.isInterestedForInteractions ||
                              pieTouchResponse == null ||
                              pieTouchResponse.touchedSection == null) {
                            _touchedIndex = -1;
                            return;
                          }
                          _touchedIndex = pieTouchResponse
                              .touchedSection!.touchedSectionIndex;
                        });
                      },
                    ),
                    sectionsSpace: 0,
                    centerSpaceRadius: 0,
                    sections: _generateSections(Size(chartSize, chartSize)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 修改控制按钮
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('名称'),
                selected: _showName,
                onSelected: (selected) {
                  setState(() {
                    _showName = selected;
                  });
                },
                checkmarkColor: Colors.white,
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: _showName ? Colors.white : Colors.black,
                ),
              ),
              FilterChip(
                label: const Text('数量'),
                selected: _showCount,
                onSelected: (selected) {
                  setState(() {
                    _showCount = selected;
                  });
                },
                checkmarkColor: Colors.white,
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: _showCount ? Colors.white : Colors.black,
                ),
              ),
              FilterChip(
                label: const Text('百分比'),
                selected: _showPercent,
                onSelected: (selected) {
                  setState(() {
                    _showPercent = selected;
                  });
                },
                checkmarkColor: Colors.white,
                selectedColor: Theme.of(context).colorScheme.primary,
                labelStyle: TextStyle(
                  color: _showPercent ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
          if (widget.showLegend) ...[
            // 根据参数决定是否显示图例
            const SizedBox(height: 10),
            SizedBox(
              width: chartSize * 0.6,
              child: Wrap(
                direction: isPortrait ? Axis.vertical : Axis.horizontal,
                spacing: 10, // 从 12 减小到 10
                runSpacing: 6, // 从 8 减小到 6
                alignment: WrapAlignment.center,
                children: _buildLegends(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<PieChartSectionData> _generateSections(Size chartSize) {
    double startAngle = -pi / 2;
    const minPercentageForLabel = 0.05;

    return List.generate(widget.counters.length, (i) {
      final counter = widget.counters[i];
      final percentage = counter.count / widget.total;
      final sweepAngle = 2 * pi * percentage;
      final isTouched = i == _touchedIndex;
      final radius =
          isTouched ? chartSize.width * 0.38 : chartSize.width * 0.35;

      final shouldShowLabel = percentage >= minPercentageForLabel;

      final textPos = _calculateTextPosition(
        chartSize.width / 2,
        chartSize.height / 2,
        radius,
        startAngle,
        sweepAngle,
        Size(80, 50),
        chartSize,
      );

      String getLabelText() {
        if (!shouldShowLabel) {
          return '';
        }
        List<String> parts = [];
        if (_showName) parts.add(counter.name);
        if (_showCount) parts.add('${counter.count}');
        if (_showPercent) {
          parts.add('(${(percentage * 100).toStringAsFixed(1)}%)');
        }
        return parts.join('\n');
      }

      final section = PieChartSectionData(
        color: counter.colorValue,
        value: counter.count.toDouble(),
        radius: radius,
        title: isTouched ? '' : getLabelText(),
        titleStyle: TextStyle(
          fontSize: 12, // 减小字号
          fontWeight: FontWeight.bold,
          color: _isDarkColor(counter.colorValue) ? Colors.white : Colors.black,
        ),
        titlePositionPercentageOffset: 0.65,
        borderSide: const BorderSide(
          color: Colors.white,
          width: 1,
        ),
        badgeWidget: isTouched
            ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                constraints: BoxConstraints(
                  // 添加最大宽度限制
                  maxWidth: chartSize.width * 0.4, // 限制为饼图宽度的40%
                ),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      counter.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14, // 减小字号
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                      softWrap: true, // 允许换行
                      overflow: TextOverflow.visible,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${counter.count}\n(${(percentage * 100).toStringAsFixed(1)}%)',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12, // 减小字号
                        color: Colors.white,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              )
            : null,
        badgePositionPercentageOffset: _calculateBadgeOffset(
          textPos,
          chartSize,
          radius,
        ),
      );

      startAngle += sweepAngle;
      return section;
    });
  }

  // 计算徽章偏移量
  double _calculateBadgeOffset(Offset position, Size chartSize, double radius) {
    final center = Offset(chartSize.width / 2, chartSize.height / 2);
    final distance = (position - center).distance;
    return distance / radius;
  }

  List<Widget> _buildLegends() {
    return widget.counters.map((counter) {
      final percentage = counter.count / widget.total;
      return _LegendItem(
        name: counter.name,
        value: '${counter.count} (${(percentage * 100).toStringAsFixed(1)}%)',
        color: counter.colorValue,
      );
    }).toList();
  }

  bool _isDarkColor(Color color) {
    return color.computeLuminance() < 0.5;
  }
}

class _LegendItem extends StatelessWidget {
  final String name;
  final String value;
  final Color color;

  const _LegendItem({
    required this.name,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          name,
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.black54,
          ),
        ),
      ],
    );
  }
}
