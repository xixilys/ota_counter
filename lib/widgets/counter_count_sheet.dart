import 'dart:async';

import 'package:flutter/material.dart';

import '../models/counter_model.dart';

class CounterCountSheet extends StatefulWidget {
  final CounterModel counter;
  final Future<void> Function(CounterModel updatedCounter) onCounterChanged;

  const CounterCountSheet({
    super.key,
    required this.counter,
    required this.onCounterChanged,
  });

  @override
  State<CounterCountSheet> createState() => _CounterCountSheetState();
}

class _CounterCountSheetState extends State<CounterCountSheet> {
  late CounterModel _counter;

  @override
  void initState() {
    super.initState();
    _counter = widget.counter;
  }

  void _changeCount(CounterCountField field, int delta) {
    final updatedCounter = _counter.changeCount(field, delta);
    if (updatedCounter.countForField(field) == _counter.countForField(field)) {
      return;
    }

    setState(() {
      _counter = updatedCounter;
    });
    unawaited(widget.onCounterChanged(updatedCounter));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _counter.name,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '总计 ${_counter.count}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '点按 +/- 会立即保存当前规格数量。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            ...CounterCountField.values.map((field) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _CountAdjustRow(
                  field: field,
                  value: _counter.countForField(field),
                  onDecrement: () => _changeCount(field, -1),
                  onIncrement: () => _changeCount(field, 1),
                ),
              );
            }),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.check),
                label: const Text('完成'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountAdjustRow extends StatelessWidget {
  final CounterCountField field;
  final int value;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  const _CountAdjustRow({
    required this.field,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              field.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton.filledTonal(
            onPressed: value > 0 ? onDecrement : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          IconButton.filled(
            onPressed: onIncrement,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}
