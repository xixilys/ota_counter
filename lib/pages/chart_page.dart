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

  Map<CounterCountField, int> get _typeTotals {
    return {
      for (final field in CounterCountField.values)
        field: counters.fold<int>(
          0,
          (sum, counter) => sum + counter.countForField(field),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final typeTotals = _typeTotals;

    return Scaffold(
      appBar: AppBar(
        title: const Text('统计分布'),
        backgroundColor:
            Theme.of(context).colorScheme.inversePrimary.withAlpha(204),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SizedBox(
            height: 380,
            child: CounterPieChart(
              counters: counters,
              total: total,
              showLegend: false,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '规格汇总',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: CounterCountField.values.map((field) {
                    return _TypeTotalChip(
                      label: field.label,
                      value: typeTotals[field] ?? 0,
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '成员占比',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          ..._sortedCounters.map((counter) {
            final percentage = total == 0
                ? '0.0'
                : (counter.count / total * 100).toStringAsFixed(1);

            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
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
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  counter.countEntries
                      .where((entry) => entry.value > 0)
                      .map((entry) => '${entry.key.shortLabel} ${entry.value}')
                      .join(' / ')
                      .ifEmpty('暂无规格记录'),
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
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _TypeTotalChip extends StatelessWidget {
  final String label;
  final int value;

  const _TypeTotalChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) {
    return isEmpty ? fallback : this;
  }
}
