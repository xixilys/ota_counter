import 'package:flutter/material.dart';

import '../models/ticket_type_model.dart';
import '../services/ticket_pricing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_page_background.dart';
import '../widgets/dream/dream_kit.dart';
import '../widgets/no_autofill_text_field.dart';
import 'ticket_organize_page.dart';

class TicketPricingPage extends StatefulWidget {
  const TicketPricingPage({super.key});

  @override
  State<TicketPricingPage> createState() => _TicketPricingPageState();
}

class _TicketPricingPageState extends State<TicketPricingPage> {
  List<TicketTypeModel> _types = [];
  List<TicketPricePreset> _presets = [];
  Map<String, TicketTypeUsage> _usage = const {};
  TicketStats _stats = TicketStats.empty;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final types = await TicketPricingService.getTicketTypes();
    final presets = await TicketPricingService.getPresets();
    final usage = await TicketPricingService.getTypeUsage();
    final stats = await TicketPricingService.getStats();
    if (!mounted) return;
    setState(() {
      _types = types;
      _presets = presets;
      _usage = usage;
      _stats = stats;
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
          imported == 0 ? '还没有带票种的历史门票可学习' : '已从 $imported 条历史门票更新场次价格',
        ),
      ),
    );
  }

  Future<void> _openOrganizer() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const TicketOrganizePage(),
      ),
    );
    await _load();
  }

  Future<void> _deleteType(TicketTypeModel type) async {
    if (type.id == null) return;
    final used = _usage[type.name]?.ticketCount ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除票种'),
        content: Text(
          used > 0
              ? '「${type.name}」已经用在 $used 张门票上。删除只会移除这个票种入口，'
                  '已有门票记录会保留原票种名称。确定删除？'
              : '删除「${type.name}」？',
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
    await TicketPricingService.deleteTicketType(type.id!);
    await _load();
  }

  void _showExplainer() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('票种与自动价格'),
        content: const Text(
          '录门票时优先带入演出名单里的票价，其次记住同一场次上次的价格，'
          '最后才用票种的默认价。默认价会在第一次记录该票种后自动学习。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _importFromHistory();
            },
            child: const Text('重建场次价格'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usedTypes = _types
        .where((type) => type.name.trim().isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) {
        final countA = _usage[a.name]?.ticketCount ?? 0;
        final countB = _usage[b.name]?.ticketCount ?? 0;
        final countCompare = countB.compareTo(countA);
        if (countCompare != 0) return countCompare;
        return a.sortOrder.compareTo(b.sortOrder);
      });
    final activeTypes = usedTypes
        .where((type) => (_usage[type.name]?.ticketCount ?? 0) > 0)
        .toList(growable: false);
    final idleTypes = usedTypes
        .where((type) => (_usage[type.name]?.ticketCount ?? 0) <= 0)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('门票整理'),
        actions: [
          IconButton(
            tooltip: '票种怎么用',
            onPressed: _showExplainer,
            icon: const Icon(Icons.info_outline_rounded),
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
        backgroundColor: AppTheme.oshi(theme.brightness),
        foregroundColor: AppTheme.onOshi(theme.brightness),
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加票种'),
      ),
      body: AppPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  _TicketLedgerHeader(
                    stats: _stats,
                    onOrganize: _openOrganizer,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(
                        Icons.auto_awesome_outlined,
                        size: 15,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '默认价会随第一次记录的票种自动学习',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '查看规则',
                        onPressed: _showExplainer,
                        icon: const Icon(
                          Icons.info_outline_rounded,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _SectionLabel(
                    title: '票种账本',
                    trailing: '${activeTypes.length} 种在用',
                  ),
                  const SizedBox(height: 8),
                  if (activeTypes.isEmpty)
                    _EmptyTypeHint(onAdd: () => _showTypeDialog())
                  else
                    for (final type in activeTypes) ...[
                      _TypeLedgerRow(
                        type: type,
                        usage: _usage[type.name],
                        onTap: () => _showTypeDialog(initial: type),
                        onDelete: () => _deleteType(type),
                      ),
                      const SizedBox(height: 8),
                    ],
                  if (idleTypes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _IdleTypesSection(
                      types: idleTypes,
                      onEdit: (type) => _showTypeDialog(initial: type),
                      onDelete: _deleteType,
                    ),
                  ],
                  if (_presets.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _PresetSection(presets: _presets),
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

class _TicketLedgerHeader extends StatelessWidget {
  final TicketStats stats;
  final VoidCallback onOrganize;

  const _TicketLedgerHeader({
    required this.stats,
    required this.onOrganize,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final uncategorized = stats.uncategorizedCount;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
          decoration: BoxDecoration(
            color: AppTheme.polaroid(brightness),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '门票手帐',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${stats.ticketCount}',
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 5, bottom: 6),
                    child: Text(
                      '张门票',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '¥${_formatAmount(stats.amount)}',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '免费 ${stats.freeTicketCount} · 付费 ${stats.paidTicketCount}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (uncategorized > 0)
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: onOrganize,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
                      decoration: BoxDecoration(
                        color: AppTheme.wash(
                            AppTheme.amber, scheme.surface, brightness),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: AppTheme.amber.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.confirmation_num_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '未分类 $uncategorized 张 · ¥${_formatAmount(stats.uncategorizedAmount)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '去归类',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else
                Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 17,
                      color: scheme.tertiary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '所有门票都有票种了',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        Positioned(
          top: -7,
          left: 26,
          child: WashiTape(
            color: DreamPalette.tape(AppTheme.amber, brightness),
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

class _TypeLedgerRow extends StatelessWidget {
  final TicketTypeModel type;
  final TicketTypeUsage? usage;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _TypeLedgerRow({
    required this.type,
    required this.usage,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final resolved = usage ?? TicketTypeUsage(typeName: type.name);
    final accent = _accentFor(type, brightness);
    final lastPrice = resolved.lastUsedAt == null
        ? (type.isFree
            ? '免费票种'
            : type.defaultPrice > 0
                ? '默认 ¥${_formatPrice(type.defaultPrice)}'
                : '默认价待第一次记录后学习')
        : resolved.lastIsFree
            ? '上次免费'
            : '上次 ¥${_formatPrice(resolved.lastUnitPrice)}';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
          decoration: BoxDecoration(
            color: AppTheme.wash(accent, scheme.surface, brightness),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 5,
                height: 42,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            type.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (type.isFree) ...[
                          const SizedBox(width: 6),
                          _TinyTag(
                            label: '免费',
                            color: accent,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _Metric(
                          label: '${resolved.ticketCount} 张',
                        ),
                        _Metric(
                          label: '¥${_formatAmount(resolved.amount)}',
                        ),
                        _Metric(
                          label: '均价 ¥${_formatPrice(resolved.averagePrice)}',
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lastPrice,
                      maxLines: 1,
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
                tooltip: '票种操作',
                onSelected: (value) {
                  if (value == 'edit') onTap();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.edit_outlined),
                      title: Text('编辑票种'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline),
                      title: Text('删除票种'),
                    ),
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

  static Color _accentFor(TicketTypeModel type, Brightness brightness) {
    if (type.isFree) return AppTheme.mint;
    final hues = [AppTheme.sakura, AppTheme.sky, AppTheme.amber, AppTheme.mint];
    final seed = type.name.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
    return hues[seed % hues.length];
  }

  static String _formatPrice(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _IdleTypesSection extends StatelessWidget {
  final List<TicketTypeModel> types;
  final ValueChanged<TicketTypeModel> onEdit;
  final ValueChanged<TicketTypeModel> onDelete;

  const _IdleTypesSection({
    required this.types,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color:
            theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          leading: Icon(
            Icons.inventory_2_outlined,
            color: scheme.onSurfaceVariant,
          ),
          title: Text(
            '未使用票种 ${types.length}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '还没记录过，点开可以改默认价',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          children: [
            for (final type in types)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                title: Text(type.name),
                subtitle: Text(
                  type.isFree
                      ? '免费票种'
                      : type.defaultPrice > 0
                          ? '默认 ¥${_formatPrice(type.defaultPrice)}'
                          : '默认价待第一次记录后学习',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'edit') onEdit(type);
                    if (value == 'delete') onDelete(type);
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
                ),
              ),
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

class _PresetSection extends StatelessWidget {
  final List<TicketPricePreset> presets;

  const _PresetSection({required this.presets});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visible = presets.take(12).toList(growable: false);
    return Container(
      decoration: BoxDecoration(
        color:
            theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          leading:
              Icon(Icons.receipt_long_outlined, color: scheme.onSurfaceVariant),
          title: Text(
            '场次价格记忆 ${presets.length}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '最近 ${visible.length} 条 · 保存门票时自动更新',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 11,
            ),
          ),
          children: [
            for (final preset in visible)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(
                  preset.isFree
                      ? Icons.card_giftcard_outlined
                      : Icons.local_activity_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                title: Text(
                  preset.eventName.isEmpty
                      ? preset.groupName
                      : preset.eventName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                subtitle: Text(
                  [
                    preset.ticketType,
                    if (preset.venueName.isNotEmpty) preset.venueName,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Text(
                  preset.isFree ? '免费' : '¥${_formatPrice(preset.unitPrice)}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
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

class _SectionLabel extends StatelessWidget {
  final String title;
  final String trailing;

  const _SectionLabel({required this.title, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const Spacer(),
        Text(
          trailing,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;

  const _Metric({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 11,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _TinyTag extends StatelessWidget {
  final String label;
  final Color color;

  const _TinyTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppTheme.readableAccent(color, theme.brightness),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyTypeHint extends StatelessWidget {
  final VoidCallback onAdd;

  const _EmptyTypeHint({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.confirmation_num_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '还没有在用票种。先记一张门票，或添加一个票种。',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          TextButton(onPressed: onAdd, child: const Text('添加')),
        ],
      ),
    );
  }
}
