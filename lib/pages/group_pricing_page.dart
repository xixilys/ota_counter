import 'package:flutter/material.dart';

import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../widgets/no_autofill_text_field.dart';

class GroupPricingPage extends StatefulWidget {
  const GroupPricingPage({super.key});

  @override
  State<GroupPricingPage> createState() => _GroupPricingPageState();
}

class _GroupPricingPageState extends State<GroupPricingPage> {
  final TextEditingController _searchController = TextEditingController();

  List<CounterModel> _counters = [];
  List<GroupPricingModel> _pricings = [];
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
    });

    final counters = await DatabaseService.getCounters();
    final pricings = await DatabaseService.getGroupPricings();

    if (!mounted) {
      return;
    }

    setState(() {
      _counters = counters;
      _pricings = pricings;
      _loading = false;
    });
  }

  List<_GroupPricingEntry> get _entries {
    final pricingByName = {
      for (final pricing in _pricings) pricing.groupName.trim(): pricing,
    };
    final groupNames = <String>{
      for (final counter in _counters)
        if (counter.groupName.trim().isNotEmpty) counter.groupName.trim(),
      ...pricingByName.keys,
    }.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final query = _query.trim().toLowerCase();
    return groupNames
        .where((groupName) {
          if (query.isEmpty) {
            return true;
          }
          return groupName.toLowerCase().contains(query);
        })
        .map(
          (groupName) => _GroupPricingEntry(
            groupName: groupName,
            pricing: pricingByName[groupName],
          ),
        )
        .toList();
  }

  Future<void> _editPricing({
    GroupPricingModel? pricing,
    String initialGroupName = '',
  }) async {
    final result = await showDialog<GroupPricingModel>(
      context: context,
      builder: (context) => _PricingEditorDialog(
        initialPricing: pricing,
        initialGroupName: initialGroupName,
      ),
    );

    if (result == null) {
      return;
    }

    await DatabaseService.upsertGroupPricing(result);
    await _loadData();
  }

  Future<void> _deletePricing(GroupPricingModel pricing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除价格配置'),
        content: Text('确定删除 ${pricing.groupName} 的默认价格吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true || pricing.id == null) {
      return;
    }

    await DatabaseService.deleteGroupPricing(pricing.id!);
    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;

    return Scaffold(
      appBar: AppBar(
        title: const Text('团体默认价格'),
        actions: [
          IconButton(
            onPressed: () => _editPricing(),
            icon: const Icon(Icons.add),
            tooltip: '新增价格配置',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  NoAutofillTextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: '搜索团体',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _query = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '后续新增的记录会自动带上当前默认价格和价格标签。老记录不会被新价格覆盖。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  if (entries.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color:
                            Theme.of(context).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('还没有可配置的团体，先新增成员或手动添加一个团体价格。'),
                    )
                  else
                    ...entries.map((entry) {
                      final pricing = entry.pricing;
                      final hasPricing = pricing != null;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entry.groupName,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          hasPricing
                                              ? '价格标签：${pricing.label}'
                                              : '未配置默认价格',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                color: hasPricing
                                                    ? null
                                                    : Theme.of(context)
                                                        .colorScheme
                                                        .error,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => _editPricing(
                                      pricing: pricing,
                                      initialGroupName: entry.groupName,
                                    ),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  if (pricing != null)
                                    IconButton(
                                      onPressed: () => _deletePricing(pricing),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  ...CounterCountField.visibleValues(
                                    enableUnsigned:
                                        pricing?.hasUnsignedPrices ?? false,
                                  ).map((field) {
                                    final value =
                                        pricing?.priceForField(field) ?? 0;
                                    return _PriceChip(
                                      label: field.label,
                                      value: value,
                                    );
                                  }),
                                  _PriceChip(
                                    label: '多人切参考价',
                                    value: pricing?.doubleCutPrice ?? 0,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
    );
  }
}

class _GroupPricingEntry {
  final String groupName;
  final GroupPricingModel? pricing;

  const _GroupPricingEntry({
    required this.groupName,
    required this.pricing,
  });
}

class _PriceChip extends StatelessWidget {
  final String label;
  final double value;

  const _PriceChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            '¥${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2)}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}

class _PricingEditorDialog extends StatefulWidget {
  final GroupPricingModel? initialPricing;
  final String initialGroupName;

  const _PricingEditorDialog({
    required this.initialPricing,
    required this.initialGroupName,
  });

  @override
  State<_PricingEditorDialog> createState() => _PricingEditorDialogState();
}

class _PricingEditorDialogState extends State<_PricingEditorDialog> {
  static const String _doubleCutPriceKey = 'doubleCutPrice';

  late final TextEditingController _groupController;
  late final TextEditingController _labelController;
  late final Map<String, TextEditingController> _priceControllers;
  late bool _enableUnsignedOptions;

  @override
  void initState() {
    super.initState();
    final pricing = widget.initialPricing;
    _groupController = TextEditingController(
      text: pricing?.groupName ?? widget.initialGroupName,
    );
    _labelController = TextEditingController(
      text: pricing?.label ?? '默认价格',
    );
    _enableUnsignedOptions = pricing?.hasUnsignedPrices ?? false;
    _priceControllers = {
      CounterCountField.threeInch.key: TextEditingController(
        text: _formatPrice(pricing?.threeInchPrice ?? 0),
      ),
      CounterCountField.fiveInch.key: TextEditingController(
        text: _formatPrice(pricing?.fiveInchPrice ?? 0),
      ),
      CounterCountField.unsignedThreeInch.key: TextEditingController(
        text: _formatPrice(pricing?.unsignedThreeInchPrice ?? 0),
      ),
      CounterCountField.unsignedFiveInch.key: TextEditingController(
        text: _formatPrice(pricing?.unsignedFiveInchPrice ?? 0),
      ),
      CounterCountField.groupCut.key: TextEditingController(
        text: _formatPrice(pricing?.groupCutPrice ?? 0),
      ),
      _doubleCutPriceKey: TextEditingController(
        text: _formatPrice(pricing?.doubleCutPrice ?? 0),
      ),
      CounterCountField.threeInchShukudai.key: TextEditingController(
        text: _formatPrice(pricing?.threeInchShukudaiPrice ?? 0),
      ),
      CounterCountField.fiveInchShukudai.key: TextEditingController(
        text: _formatPrice(pricing?.fiveInchShukudaiPrice ?? 0),
      ),
    };
  }

  @override
  void dispose() {
    _groupController.dispose();
    _labelController.dispose();
    for (final controller in _priceControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _formatPrice(double value) {
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
  }

  double _parsePrice(CounterCountField field) {
    return double.tryParse(_priceControllers[field.key]!.text.trim()) ?? 0;
  }

  double _parseDoubleCutPrice() {
    return double.tryParse(_priceControllers[_doubleCutPriceKey]!.text.trim()) ??
        0;
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialPricing != null;

    return AlertDialog(
      title: Text(isEditing ? '编辑团体价格' : '新增团体价格'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NoAutofillTextField(
              controller: _groupController,
              decoration: const InputDecoration(
                labelText: '团体名称',
                hintText: '例如 EA人间计划',
              ),
            ),
            const SizedBox(height: 12),
            NoAutofillTextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: '价格标签',
                hintText: '例如 2026 春巡 / 常规价',
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用无签选项'),
              subtitle: const Text('开启后可配置无签3寸和无签5寸价格'),
              value: _enableUnsignedOptions,
              onChanged: (value) {
                setState(() {
                  _enableUnsignedOptions = value;
                });
              },
            ),
            const SizedBox(height: 12),
            ...CounterCountField.visibleValues(
              enableUnsigned: _enableUnsignedOptions,
            ).map((field) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: NoAutofillTextField(
                  controller: _priceControllers[field.key]!,
                  decoration: InputDecoration(
                    labelText: '${field.label} 单价',
                    prefixText: '¥',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              );
            }),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: NoAutofillTextField(
                controller: _priceControllers[_doubleCutPriceKey]!,
                decoration: const InputDecoration(
                  labelText: '多人切参考价',
                  prefixText: '¥',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final groupName = _groupController.text.trim();
            if (groupName.isEmpty) {
              return;
            }

            Navigator.of(context).pop(
              GroupPricingModel(
                id: widget.initialPricing?.id,
                groupName: groupName,
                label: _labelController.text.trim().isEmpty
                    ? '默认价格'
                    : _labelController.text.trim(),
                enableUnsignedOptions: _enableUnsignedOptions,
                threeInchPrice: _parsePrice(CounterCountField.threeInch),
                fiveInchPrice: _parsePrice(CounterCountField.fiveInch),
                unsignedThreeInchPrice: _parsePrice(
                  CounterCountField.unsignedThreeInch,
                ),
                unsignedFiveInchPrice: _parsePrice(
                  CounterCountField.unsignedFiveInch,
                ),
                groupCutPrice: _parsePrice(CounterCountField.groupCut),
                doubleCutPrice: _parseDoubleCutPrice(),
                threeInchShukudaiPrice: _parsePrice(
                  CounterCountField.threeInchShukudai,
                ),
                fiveInchShukudaiPrice: _parsePrice(
                  CounterCountField.fiveInchShukudai,
                ),
                updatedAt: DateTime.now(),
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
