import 'package:flutter/material.dart';
import '../models/counter_model.dart';
import '../widgets/counter_pie_chart.dart';

class ChartPage extends StatelessWidget {
  final List<CounterModel> counters;
  final int total;

  const ChartPage({
    super.key,
    required this.counters,
    required this.total,
  });

  List<CounterModel> get _sortedCounters {
    final sorted = List<CounterModel>.from(counters);
    sorted.sort((a, b) => b.count.compareTo(a.count)); // 降序排序
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计分布'),
        backgroundColor:
            Theme.of(context).colorScheme.inversePrimary.withAlpha(204),
      ),
      body: Column(
        children: [
          // 饼图部分
          Expanded(
            flex: 4,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16), // 四周都加上内边距
                child: CounterPieChart(
                  counters: counters,
                  total: total,
                  showLegend: false,
                ),
              ),
            ),
          ),
          // 分割线
          const Divider(height: 1, thickness: 1),
          // 列表部分
          Expanded(
            flex: 2, // 占据下部分空间
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _sortedCounters.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final counter = _sortedCounters[index];
                final percentage =
                    (counter.count / total * 100).toStringAsFixed(1);

                return ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: counter.colorValue,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(
                    counter.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  trailing: Text(
                    '${counter.count} ($percentage%)',
                    style: TextStyle(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.6),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
