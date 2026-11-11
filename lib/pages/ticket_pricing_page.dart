import 'package:flutter/material.dart';

import '../models/ticket_type_model.dart';
import '../services/ticket_pricing_service.dart';
import '../widgets/app_page_background.dart';
import '../widgets/no_autofill_text_field.dart';

class TicketPricingPage extends StatefulWidget {
  const TicketPricingPage({super.key});

  @override
  State<TicketPricingPage> createState() => _TicketPricingPageState();
}

class _TicketPricingPageState extends State<TicketPricingPage> {
  List<TicketTypeModel> _types = [];
  List<TicketPricePreset> _presets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final types = await TicketPricingService.getTicketTypes();
    final presets = await TicketPricingService.getPresets();
    if (!mounted) return;
    setState(() {
      _types = types;
      _presets = presets;
      _loading = false;
    });
  }

  Future<void> _showTypeDialog({TicketTypeModel? initial}) async {
    final nameController = TextEditingController(text: initial?.name ?? '');
    final priceController = TextEditingController(
      text: initial == null ? '0' : _formatPrice(initial.defaultPrice),
    );
    var isFree = initial?.isFree ?? false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(initial == null ? '添加票种' : '编辑票种'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NoAutofillTextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '票种名称',
                    hintText: '例如 预售票 / 现场票 / 学生票',
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: isFree,
                  title: const Text('免费票种'),
                  subtitle: const Text('免费票种会自动把单价设为 0'),
                  onChanged: (value) {
                    setDialogState(() {
                      isFree = value;
                      if (value) priceController.text = '0';
                    });
                  },
                ),
                const SizedBox(height: 4),
                NoAutofillTextField(
                  controller: priceController,
                  enabled: !isFree,
                  decoration: InputDecoration(
                    labelText: '默认单价',
                    prefixText: '¥',
                    hintText: isFree ? '免费' : '第一次记录后会自动记住',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final price = isFree
                    ? 0.0
                    : (double.tryParse(priceController.text.trim()) ?? 0);
                try {
                  await TicketPricingService.upsertTicketType(
                    TicketTypeModel(
                      id: initial?.id,
                      name: name,
                      defaultPrice: price,
                      isFree: isFree,
                      sortOrder: initial?.sortOrder ?? _types.length,
                      updatedAt: DateTime.now(),
                    ),
                  );
                } catch (error) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(
                      SnackBar(content: Text('保存票种失败：$error')),
                    );
                  }
                  return;
                }
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    priceController.dispose();
    await _load();
  }

  Future<void> _importFromHistory() async {
    final imported = await TicketPricingService.rebuildFromHistory();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          imported == 0 ? '没有找到带票种的历史门票' : '已从 $imported 条历史门票更新场次价格',
        ),
      ),
    );
  }

  Future<void> _deleteType(TicketTypeModel type) async {
    if (type.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除票种'),
        content: Text('删除“${type.name}”？已有门票记录不会被删除。'),
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
    if (confirmed != true) return;
    await TicketPricingService.deleteTicketType(type.id!);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('门票价格'),
        actions: [
          IconButton(
            tooltip: '从历史门票导入价格',
            onPressed: _importFromHistory,
            icon: const Icon(Icons.history_rounded),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showTypeDialog(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加票种'),
      ),
      body: AppPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      gradient: LinearGradient(
                        colors: [
                          scheme.tertiaryContainer,
                          scheme.primaryContainer,
                        ],
                      ),
                      border: Border.all(
                        color: scheme.tertiary.withValues(alpha: 0.16),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(15),
                            color: scheme.surface.withValues(alpha: 0.72),
                          ),
                          child: Icon(
                            Icons.local_activity_rounded,
                            color: scheme.tertiary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '票种与自动价格',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '录入门票时优先带入演出名单文案里的票价，其次才是'
                                '同场次上次价格；都没有时使用这里的默认价。免费场次'
                                '可以直接打开开关。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 2),
                              TextButton.icon(
                                onPressed: _importFromHistory,
                                icon:
                                    const Icon(Icons.history_rounded, size: 16),
                                label: const Text('从历史门票导入'),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 0,
                                    vertical: 2,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '票种',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_types.isEmpty)
                    const Text('还没有票种，点右下角添加。')
                  else
                    for (final type in _types) ...[
                      Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: type.isFree
                                ? scheme.tertiaryContainer
                                : scheme.primaryContainer,
                            child: Icon(
                              type.isFree
                                  ? Icons.card_giftcard_rounded
                                  : Icons.confirmation_num_outlined,
                              color: type.isFree
                                  ? scheme.onTertiaryContainer
                                  : scheme.onPrimaryContainer,
                            ),
                          ),
                          title: Text(type.name),
                          subtitle: Text(
                            type.isFree
                                ? '免费票种'
                                : type.defaultPrice > 0
                                    ? '默认 ¥${_formatPrice(type.defaultPrice)}'
                                    : '默认价待第一次记录后学习',
                          ),
                          trailing: Wrap(
                            spacing: 2,
                            children: [
                              IconButton(
                                tooltip: '编辑',
                                onPressed: () => _showTypeDialog(initial: type),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: '删除',
                                onPressed: () => _deleteType(type),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  if (_presets.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      '场次价格记忆',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '每次保存门票记录都会自动更新；这里只展示最近 200 条。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final preset in _presets.take(20)) ...[
                      Card(
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            preset.isFree
                                ? Icons.card_giftcard_outlined
                                : Icons.receipt_long_outlined,
                            color: scheme.primary,
                          ),
                          title: Text(
                            preset.eventName.isEmpty
                                ? preset.groupName
                                : preset.eventName,
                          ),
                          subtitle: Text(
                            [
                              preset.ticketType,
                              if (preset.venueName.isNotEmpty) preset.venueName,
                            ].join(' · '),
                          ),
                          trailing: Text(
                            preset.isFree
                                ? '免费'
                                : '¥${_formatPrice(preset.unitPrice)}',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ],
              ),
      ),
    );
  }

  static String _formatPrice(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}
