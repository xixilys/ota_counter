import 'package:flutter/material.dart';

import '../models/activity_record_model.dart';
import '../models/ticket_type_model.dart';
import '../services/ticket_classify_service.dart';
import '../services/ticket_pricing_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_page_background.dart';

/// 归类 flow for tickets saved before ticket types existed: group them by
/// 场次 + price, pre-suggest a type, and assign a type to a multi-selection in
/// one action. All updates go through TicketPricingService.
class TicketOrganizePage extends StatefulWidget {
  const TicketOrganizePage({super.key});

  @override
  State<TicketOrganizePage> createState() => _TicketOrganizePageState();
}

class _TicketOrganizePageState extends State<TicketOrganizePage> {
  List<TicketTypeModel> _types = const [];
  List<TicketClassifyGroup> _groups = const [];
  final Set<int> _selectedRecordIds = <int>{};
  bool _loading = true;
  bool _assigning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final types = await TicketPricingService.getTicketTypes();
    final records = await TicketPricingService.getUncategorizedTickets();
    final groups = TicketClassifyService.groupRecords(records, types);
    if (!mounted) return;
    setState(() {
      _types = types;
      _groups = groups;
      _selectedRecordIds.removeWhere(
        (id) => !records.any((record) => record.id == id),
      );
      _loading = false;
    });
  }

  int get _selectedCount => _selectedRecordIds.length;

  double get _selectedAmount {
    var amount = 0.0;
    for (final group in _groups) {
      for (final record in group.records) {
        if (_selectedRecordIds.contains(record.id)) {
          amount += record.totalAmount;
        }
      }
    }
    return amount;
  }

  void _toggleRecord(int? id, bool selected) {
    if (id == null) return;
    setState(() {
      if (selected) {
        _selectedRecordIds.add(id);
      } else {
        _selectedRecordIds.remove(id);
      }
    });
  }

  void _toggleGroup(TicketClassifyGroup group, bool selected) {
    setState(() {
      for (final record in group.records) {
        final id = record.id;
        if (id == null) continue;
        if (selected) {
          _selectedRecordIds.add(id);
        } else {
          _selectedRecordIds.remove(id);
        }
      }
    });
  }

  void _selectSuggested(TicketClassifyGroup group) {
    setState(() {
      _selectedRecordIds.addAll(group.suggestedRecordIds);
    });
  }

  void _selectAll() {
    setState(() {
      _selectedRecordIds
        ..clear()
        ..addAll(
          _groups
              .expand((group) => group.records)
              .map((record) => record.id)
              .whereType<int>(),
        );
    });
  }

  Future<void> _chooseTypeAndAssign() async {
    if (_selectedCount == 0 || _assigning) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _TypePickerSheet(
        types: _types,
        selectedCount: _selectedCount,
      ),
    );
    if (selected == null || !mounted) return;
    await _assignType(selected);
  }

  Future<void> _assignType(String typeName) async {
    setState(() => _assigning = true);
    try {
      final result = await TicketPricingService.assignTypeToTickets(
        recordIds: _selectedRecordIds,
        typeName: typeName,
      );
      if (!mounted) return;
      setState(() {
        _assigning = false;
        _selectedRecordIds.clear();
      });
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.assigned == 0
                ? '没有可归类的门票'
                : '已把 ${result.assigned} 张门票归到「$typeName」，场次价格已重新学习',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _assigning = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('归类失败：$error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('归类未分类门票'),
        actions: [
          if (_groups.isNotEmpty)
            TextButton(
              onPressed: _selectedCount ==
                      _groups.fold<int>(
                        0,
                        (sum, group) => sum + group.records.length,
                      )
                  ? () => setState(_selectedRecordIds.clear)
                  : _selectAll,
              child: Text(
                _selectedCount ==
                        _groups.fold<int>(
                          0,
                          (sum, group) => sum + group.records.length,
                        )
                    ? '取消全选'
                    : '全选',
              ),
            ),
        ],
      ),
      body: AppPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _groups.isEmpty
                ? _EmptyOrganizer(onBack: () => Navigator.of(context).pop())
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      _selectedCount > 0 ? 120 : 24,
                    ),
                    children: [
                      _OrganizerHeader(
                        ticketCount: _groups.fold<int>(
                          0,
                          (sum, group) => sum + group.quantity,
                        ),
                        groupCount: _groups.length,
                      ),
                      const SizedBox(height: 12),
                      for (final group in _groups) ...[
                        _GroupCard(
                          group: group,
                          selectedIds: _selectedRecordIds,
                          onToggleRecord: _toggleRecord,
                          onToggleGroup: _toggleGroup,
                          onSelectSuggested: () => _selectSuggested(group),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
      ),
      bottomNavigationBar: _selectedCount == 0
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                decoration: BoxDecoration(
                  color: AppTheme.polaroid(theme.brightness),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.7),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: 0.12),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '已选 $_selectedCount 张',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            '合计 ¥${_formatAmount(_selectedAmount)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _assigning ? null : _chooseTypeAndAssign,
                      icon: _assigning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.label_outline_rounded, size: 18),
                      label: const Text('归类为…'),
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

class _OrganizerHeader extends StatelessWidget {
  final int ticketCount;
  final int groupCount;

  const _OrganizerHeader({
    required this.ticketCount,
    required this.groupCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
      decoration: BoxDecoration(
        color: AppTheme.wash(AppTheme.amber, scheme.surface, brightness),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppTheme.amber.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.auto_awesome_outlined, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$ticketCount 张门票，按建议票种和票价分成 $groupCount 组',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '同一票种、同一价位的门票已经放在一起，勾一组就能一次归类。已归类的会保留原来的价格和免费状态。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  final TicketClassifyGroup group;
  final Set<int> selectedIds;
  final void Function(int? id, bool selected) onToggleRecord;
  final void Function(TicketClassifyGroup group, bool selected) onToggleGroup;
  final VoidCallback onSelectSuggested;

  const _GroupCard({
    required this.group,
    required this.selectedIds,
    required this.onToggleRecord,
    required this.onToggleGroup,
    required this.onSelectSuggested,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final recordIds =
        group.records.map((record) => record.id).whereType<int>().toList();
    final selectedInGroup = recordIds.where(selectedIds.contains).length;
    final allSelected =
        recordIds.isNotEmpty && selectedInGroup == recordIds.length;
    final singleTicket = recordIds.length <= 1;
    final title = group.suggestedTypeName == null
        ? '未识别票种'
        : group.suggestedTypeName!;
    final dateLabels = group.dateLabels;
    final meta = [
      '¥${_formatAmount(group.unitPrice)}/张',
      '${group.quantity} 张',
      if (dateLabels.length == 1)
        dateLabels.first
      else
        '${dateLabels.length} 个日期',
      if (group.eventLabels.length > 1)
        '${group.eventLabels.length} 个场次',
    ].join(' · ');
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.polaroid(brightness),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (group.suggestedTypeName != null)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.wash(
                                  AppTheme.amber,
                                  scheme.surface,
                                  brightness,
                                ),
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color:
                                      AppTheme.amber.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Text(
                                '建议',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
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
                  ),
                ),
                if (!singleTicket)
                  Checkbox(
                    value: allSelected
                        ? true
                        : selectedInGroup > 0
                            ? null
                            : false,
                    tristate: true,
                    onChanged: (value) => onToggleGroup(group, value ?? false),
                  )
                else
                  const SizedBox(width: 12),
              ],
            ),
          ),
          if (group.hasSuggestion && group.records.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 13,
                    color: AppTheme.readableAccent(
                      AppTheme.amber,
                      brightness,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      group.suggestionReason,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: onSelectSuggested,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('选中建议项'),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 2),
          for (final record in group.records)
            _TicketChoiceRow(
              record: record,
              suggestion: group.suggestionForRecord(record.id),
              value: selectedIds.contains(record.id),
              onChanged: (value) => onToggleRecord(record.id, value),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
            child: Row(
              children: [
                Text(
                  '${group.quantity} 张 · ¥${_formatAmount(group.amount)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _TicketChoiceRow extends StatelessWidget {
  final ActivityRecordModel record;
  final TicketTypeSuggestion? suggestion;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _TicketChoiceRow({
    required this.record,
    required this.suggestion,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final session = record.sessionLabel.trim();
    final event = record.resolvedActivityName.trim();
    final label = session.isEmpty
        ? (event.isEmpty
            ? (record.note.trim().isEmpty ? '门票记录' : record.note.trim())
            : event)
        : session;
    final date = record.occurredAt;
    final meta = [
      if (event.isNotEmpty && event != label) event,
      if (record.venueName.trim().isNotEmpty &&
          record.venueName.trim() != event)
        record.venueName.trim(),
      '${date.year}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}',
      '¥${_formatAmount(record.ticketUnitPrice)} × ${record.ticketQuantity}',
    ].join(' · ');
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: (next) => onChanged(next ?? false),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (meta.isNotEmpty)
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
              ),
            ),
            if (suggestion != null)
              Container(
                margin: const EdgeInsets.only(left: 8, right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.wash(
                      AppTheme.mint, scheme.surface, theme.brightness),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  suggestion!.typeName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    color: AppTheme.readableAccent(
                      AppTheme.mint,
                      theme.brightness,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatAmount(double value) {
    if (value == value.roundToDouble()) return value.toStringAsFixed(0);
    return value.toStringAsFixed(2);
  }
}

class _TypePickerSheet extends StatelessWidget {
  final List<TicketTypeModel> types;
  final int selectedCount;

  const _TypePickerSheet({
    required this.types,
    required this.selectedCount,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '归类 $selectedCount 张门票',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '选一个票种。价格和免费状态不会改变。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final type in types)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: CircleAvatar(
                        backgroundColor: type.isFree
                            ? scheme.tertiaryContainer
                            : scheme.primaryContainer,
                        child: Icon(
                          type.isFree
                              ? Icons.card_giftcard_rounded
                              : Icons.confirmation_num_outlined,
                          size: 20,
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
                                : '还没有学到默认价',
                        style: theme.textTheme.bodySmall,
                      ),
                      onTap: () => Navigator.of(context).pop(type.name),
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

class _EmptyOrganizer extends StatelessWidget {
  final VoidCallback onBack;

  const _EmptyOrganizer({required this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: 48,
              color: scheme.tertiary,
            ),
            const SizedBox(height: 12),
            Text(
              '没有未分类的门票',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '新记录门票时选上票种，这里就会保持清爽。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onBack,
              child: const Text('返回门票整理'),
            ),
          ],
        ),
      ),
    );
  }
}
