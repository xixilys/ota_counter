import 'dart:io';

import 'package:flutter/material.dart';

import '../models/merch_purchase_model.dart';
import '../services/merch_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_page_background.dart';
import '../widgets/dream/dream_kit.dart';
import '../widgets/merch/merch_purchase_dialog.dart';

/// 周边手帐: one purchase ledger with totals by kind, member and month. The
/// data is separate from cheki activity records, so chart/MCP stats are not
/// polluted by merch purchases.
class MerchPage extends StatefulWidget {
  const MerchPage({super.key});

  @override
  State<MerchPage> createState() => _MerchPageState();
}

class _MerchPageState extends State<MerchPage> {
  List<MerchKindModel> _kinds = const [];
  List<MerchPurchaseModel> _purchases = const [];
  MerchStats _stats = MerchStats.empty;
  String? _kindFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kinds = await MerchService.getKinds();
    final purchases = await MerchService.getPurchases();
    final stats = MerchStats.fromPurchases(purchases);
    if (!mounted) return;
    setState(() {
      _kinds = kinds;
      _purchases = purchases;
      _stats = stats;
      _loading = false;
    });
  }

  Future<void> _openPurchaseDialog({MerchPurchaseModel? initial}) async {
    final purchase = await showMerchPurchaseDialog(
      context,
      initial: initial,
    );
    if (purchase == null || !mounted) return;
    try {
      await MerchService.savePurchase(purchase);
      final previousPhoto = initial?.photoPath.trim() ?? '';
      if (previousPhoto.isNotEmpty && previousPhoto != purchase.photoPath) {
        await MerchService.deletePhoto(previousPhoto);
      }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(initial == null ? '周边已记下' : '周边记录已更新'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  Future<void> _deletePurchase(MerchPurchaseModel purchase) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除周边记录'),
        content: Text(
          '删除「${purchase.kindLabel}」这条记录？照片也会一起删除。',
        ),
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
    if (confirmed != true || purchase.id == null) return;
    try {
      await MerchService.deletePurchase(purchase.id!);
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$error')),
      );
    }
  }

  Future<void> _manageKinds() async {
    final usage = await MerchService.getKindUsageCounts();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _KindManagerSheet(
        kinds: _kinds,
        usageCounts: usage,
        onChanged: _load,
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = _kindFilter == null
        ? _purchases
        : _purchases
            .where((purchase) => purchase.kindLabel == _kindFilter)
            .toList(growable: false);
    final monthPurchases = _purchases.where((purchase) {
      final now = DateTime.now();
      return purchase.occurredAt.year == now.year &&
          purchase.occurredAt.month == now.month;
    });
    final monthStats = MerchStats.fromPurchases(monthPurchases);

    return Scaffold(
      appBar: AppBar(
        title: const Text('周边手帐'),
        actions: [
          IconButton(
            tooltip: '管理周边种类',
            onPressed: _manageKinds,
            icon: const Icon(Icons.category_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openPurchaseDialog(),
        backgroundColor: AppTheme.oshi(theme.brightness),
        foregroundColor: AppTheme.onOshi(theme.brightness),
        icon: const Icon(Icons.add_rounded),
        label: const Text('记一笔周边'),
      ),
      body: AppPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  children: [
                    _MerchSummaryCard(
                      stats: _stats,
                      monthStats: monthStats,
                      kindCount: _stats.amountByKind.length,
                    ),
                    const SizedBox(height: 12),
                    if (_stats.isEmpty)
                      _EmptyMerch(onAdd: () => _openPurchaseDialog())
                    else ...[
                      _StatsPaper(
                        stats: _stats,
                        selectedKind: _kindFilter,
                        onSelectKind: (kind) {
                          setState(() {
                            _kindFilter = _kindFilter == kind ? null : kind;
                          });
                        },
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Text(
                            '购买记录',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _kindFilter == null
                                ? '${_purchases.length} 条'
                                : '只看「$_kindFilter」',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final entry in _groupByMonth(filtered).entries) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
                          child: Text(
                            _monthLabel(entry.key),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        for (final purchase in entry.value) ...[
                          _PurchaseCard(
                            purchase: purchase,
                            onTap: () => _openPurchaseDialog(initial: purchase),
                            onDelete: () => _deletePurchase(purchase),
                          ),
                          const SizedBox(height: 8),
                        ],
                        const SizedBox(height: 6),
                      ],
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  static Map<String, List<MerchPurchaseModel>> _groupByMonth(
    List<MerchPurchaseModel> purchases,
  ) {
    final grouped = <String, List<MerchPurchaseModel>>{};
    for (final purchase in purchases) {
      final key = _monthKey(purchase.occurredAt);
      grouped.putIfAbsent(key, () => []).add(purchase);
    }
    return grouped;
  }

  static String _monthKey(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}';
  }

  static String _monthLabel(String key) {
    final parts = key.split('-');
    if (parts.length != 2) return key;
    return '${parts[0]} 年 ${int.tryParse(parts[1]) ?? parts[1]} 月';
  }
}

class _MerchSummaryCard extends StatelessWidget {
  final MerchStats stats;
  final MerchStats monthStats;
  final int kindCount;

  const _MerchSummaryCard({
    required this.stats,
    required this.monthStats,
    required this.kindCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.65),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '¥${_formatAmount(stats.amount)}',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${stats.itemCount} 件',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                stats.isEmpty
                    ? '买过的周边会在这里变成一本小账本'
                    : '${stats.purchaseCount} 次购买 · $kindCount 种周边',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (!stats.isEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                  decoration: BoxDecoration(
                    color: AppTheme.wash(
                      AppTheme.sakura,
                      scheme.surface,
                      brightness,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_month_outlined, size: 15),
                      const SizedBox(width: 6),
                      Text(
                        '本月 ¥${_formatAmount(monthStats.amount)} · ${monthStats.itemCount} 件',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        Positioned(
          top: -7,
          left: 26,
          child: WashiTape(
            color: DreamPalette.tape(AppTheme.sakura, brightness),
            width: 58,
            height: 16,
            angle: -0.08,
          ),
        ),
      ],
    );
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _StatsPaper extends StatelessWidget {
  final MerchStats stats;
  final String? selectedKind;
  final ValueChanged<String> onSelectKind;

  const _StatsPaper({
    required this.stats,
    required this.selectedKind,
    required this.onSelectKind,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '按种类',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '点一下只看这类',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in _sorted(stats.amountByKind).take(10))
                ChoiceChip(
                  label: Text(
                    '${entry.key} ${stats.countByKind[entry.key] ?? 0} · ¥${_formatAmount(entry.value)}',
                  ),
                  labelStyle: theme.textTheme.bodySmall,
                  selected: selectedKind == entry.key,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => onSelectKind(entry.key),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '按成员',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          for (final entry in _sorted(stats.amountByMember).take(5))
            _BarRow(
              label: entry.key,
              primary: '¥${_formatAmount(entry.value)}',
              secondary: '${stats.countByMember[entry.key] ?? 0} 件',
              fraction: stats.amount <= 0 ? 0 : entry.value / stats.amount,
              color: AppTheme.sakura,
            ),
          if (stats.amountByMember.isEmpty)
            Text(
              '还没关联成员',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '按月',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          for (final entry in _sorted(stats.amountByMonth))
            _BarRow(
              label: _monthLabel(entry.key),
              primary: '¥${_formatAmount(entry.value)}',
              secondary: '${stats.countByMonth[entry.key] ?? 0} 件',
              fraction: stats.amount <= 0 ? 0 : entry.value / stats.amount,
              color: AppTheme.sky,
            ),
        ],
      ),
    );
  }

  static List<MapEntry<String, double>> _sorted(Map<String, double> values) {
    final entries = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }

  static String _monthLabel(String key) {
    final parts = key.split('-');
    if (parts.length != 2) return key;
    return '${parts[0]} 年 ${int.tryParse(parts[1]) ?? parts[1]} 月';
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _BarRow extends StatelessWidget {
  final String label;
  final String primary;
  final String secondary;
  final double fraction;
  final Color color;

  const _BarRow({
    required this.label,
    required this.primary,
    required this.secondary,
    required this.fraction,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: fraction.clamp(0, 1),
                backgroundColor: color.withValues(
                    alpha: brightness == Brightness.dark ? 0.2 : 0.1),
                color: color.withValues(alpha: 0.8),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            primary,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 42,
            child: Text(
              secondary,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PurchaseCard extends StatelessWidget {
  final MerchPurchaseModel purchase;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _PurchaseCard({
    required this.purchase,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final photo = purchase.photoPath.trim();
    final hasPhoto = photo.isNotEmpty && File(photo).existsSync();
    final meta = [
      if (purchase.memberLabel.isNotEmpty) purchase.memberLabel,
      if (purchase.eventLabel.isNotEmpty) purchase.eventLabel,
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasPhoto)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(photo),
                    width: 52,
                    height: 60,
                    fit: BoxFit.cover,
                  ),
                )
              else
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.wash(
                      AppTheme.sakura,
                      scheme.surface,
                      brightness,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.shopping_bag_outlined,
                    size: 19,
                    color: AppTheme.readableAccent(
                      AppTheme.sakura,
                      brightness,
                    ),
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            purchase.kindLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '¥${_formatAmount(purchase.resolvedTotalAmount)}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                    const SizedBox(height: 3),
                    Text(
                      [
                        '${purchase.quantity} 件 × ¥${_formatAmount(purchase.unitPrice)}',
                        if (purchase.note.isNotEmpty) purchase.note,
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '记录操作',
                onSelected: (value) {
                  if (value == 'edit') onTap();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('编辑'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('删除'),
                  ),
                ],
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _KindManagerSheet extends StatefulWidget {
  final List<MerchKindModel> kinds;
  final Map<String, int> usageCounts;
  final Future<void> Function() onChanged;

  const _KindManagerSheet({
    required this.kinds,
    required this.usageCounts,
    required this.onChanged,
  });

  @override
  State<_KindManagerSheet> createState() => _KindManagerSheetState();
}

class _KindManagerSheetState extends State<_KindManagerSheet> {
  late List<MerchKindModel> _kinds;

  @override
  void initState() {
    super.initState();
    _kinds = List<MerchKindModel>.from(widget.kinds);
  }

  Future<void> _addCustomKind() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加周边种类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '种类名称',
            hintText: '例如 应援扇 / 手幅',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || !mounted) return;
    try {
      await MerchService.addCustomKind(value);
      await widget.onChanged();
      final kinds = await MerchService.getKinds();
      if (!mounted) return;
      setState(() => _kinds = kinds);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('添加种类失败：$error')),
      );
    }
  }

  Future<void> _deleteKind(MerchKindModel kind) async {
    if (kind.id == null || kind.isPreset) return;
    final used = widget.usageCounts[kind.name] ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除周边种类'),
        content: Text(
          used > 0
              ? '「${kind.name}」已经用在 $used 件周边上。删除只会移除这个种类入口，'
                  '已有记录会保留名称。确定删除？'
              : '删除「${kind.name}」？',
        ),
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
    await MerchService.deleteKind(kind.id!);
    await widget.onChanged();
    final kinds = await MerchService.getKinds();
    if (!mounted) return;
    setState(() => _kinds = kinds);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '周边种类',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _addCustomKind,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('自定义'),
                ),
              ],
            ),
            Text(
              '预置种类固定保留；自定义种类可以删除。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final kind in _kinds)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: Icon(
                        kind.isPreset
                            ? Icons.bookmark_outline_rounded
                            : Icons.bookmark_added_outlined,
                        color: kind.isPreset
                            ? scheme.onSurfaceVariant
                            : AppTheme.sakura,
                      ),
                      title: Text(kind.name),
                      subtitle: Text(
                        '${widget.usageCounts[kind.name] ?? 0} 件'
                        '${kind.isPreset ? ' · 预置' : ' · 自定义'}',
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: kind.isPreset
                          ? null
                          : IconButton(
                              tooltip: '删除种类',
                              onPressed: () => _deleteKind(kind),
                              icon: const Icon(Icons.delete_outline),
                            ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyMerch extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyMerch({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 26, 22, 24),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.local_mall_outlined,
            size: 42,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            '还没有周边记录',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '生写真、吧唧、应援棒……买过的都能记在这里，'
            '按种类、成员和月份看花了多少。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('记第一笔周边'),
          ),
        ],
      ),
    );
  }
}
