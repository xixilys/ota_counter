import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../models/activity_record_model.dart';
import '../models/counter_model.dart';
import '../models/group_pricing_model.dart';
import '../services/database_service.dart';
import '../widgets/add_activity_record_dialog.dart';
import 'group_pricing_page.dart';

class ChartPage extends StatefulWidget {
  final bool openComposerOnStart;

  const ChartPage({
    super.key,
    this.openComposerOnStart = false,
  });

  @override
  State<ChartPage> createState() => _ChartPageState();
}

class _ChartPageState extends State<ChartPage> {
  List<CounterModel> _counters = [];
  List<ActivityRecordModel> _records = [];
  List<GroupPricingModel> _pricings = [];
  bool _loading = true;
  bool _initialComposerHandled = false;
  StatsScope _scope = StatsScope.month;
  DateTime _anchor = DateTime.now();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
    });

    final counters = await DatabaseService.getCounters();
    final records = await DatabaseService.getActivityRecords();
    final pricings = await DatabaseService.getGroupPricings();

    if (!mounted) {
      return;
    }

    setState(() {
      _counters = counters;
      _records = records;
      _pricings = pricings;
      _loading = false;
    });

    _openInitialComposerIfNeeded();
  }

  void _openInitialComposerIfNeeded() {
    if (!widget.openComposerOnStart || _initialComposerHandled || !mounted) {
      return;
    }

    _initialComposerHandled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _openAddRecordDialog();
    });
  }

  DateTimeRange? get _activeRange => _scope.rangeFor(_anchor);

  List<ActivityRecordModel> get _filteredRecords {
    final range = _activeRange;
    if (range == null) {
      return _records;
    }

    return _records.where((record) {
      return !record.occurredAt.isBefore(range.start) &&
          record.occurredAt.isBefore(range.end);
    }).toList();
  }

  String _formatDate(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }

  String _formatDateTime(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${_formatDate(value)} ${twoDigits(value.hour)}:${twoDigits(value.minute)}';
  }

  String _formatOccurredAtLabel(DateTime value) {
    if (value.hour == 0 && value.minute == 0) {
      return _formatDate(value);
    }
    return _formatDateTime(value);
  }

  String get _scopeTitle {
    final range = _activeRange;
    if (range == null) {
      return '全部记录';
    }

    switch (_scope) {
      case StatsScope.day:
        return _formatDate(range.start);
      case StatsScope.week:
        final weekEnd = range.end.subtract(const Duration(days: 1));
        return '${_formatDate(range.start)} ~ ${_formatDate(weekEnd)}';
      case StatsScope.month:
        return '${range.start.year}-${range.start.month.toString().padLeft(2, '0')}';
      case StatsScope.year:
        return '${range.start.year} 年';
      case StatsScope.all:
        return '全部记录';
    }
  }

  void _moveScope(int offset) {
    if (_scope == StatsScope.all) {
      return;
    }

    setState(() {
      _anchor = _scope.shift(_anchor, offset);
    });
  }

  bool get _canMoveForward {
    if (_scope == StatsScope.all) {
      return false;
    }
    final nextRange = _scope.rangeFor(_scope.shift(_anchor, 1));
    if (nextRange == null) {
      return false;
    }
    final today = DateTime.now();
    return !nextRange.start.isAfter(
      DateTime(today.year, today.month, today.day),
    );
  }

  Future<void> _openPricingPage() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const GroupPricingPage()),
    );
    await _loadData();
  }

  Future<void> _openAddRecordDialog() async {
    final draft = await showDialog<ActivityRecordDraft>(
      context: context,
      builder: (context) => AddActivityRecordDialog(
        counters: _counters,
        pricings: _pricings,
      ),
    );

    if (draft == null) {
      return;
    }

    if (draft.type == ActivityRecordType.counter && draft.counter != null) {
      final counter = draft.counter!;
      if (counter.id == null) {
        return;
      }

      final updatedCounter = counter.copyWith(
        threeInchCount: counter.threeInchCount +
            (draft.counterDeltas[CounterCountField.threeInch] ?? 0),
        fiveInchCount: counter.fiveInchCount +
            (draft.counterDeltas[CounterCountField.fiveInch] ?? 0),
        groupCutCount: counter.groupCutCount +
            (draft.counterDeltas[CounterCountField.groupCut] ?? 0),
        threeInchShukudaiCount: counter.threeInchShukudaiCount +
            (draft.counterDeltas[CounterCountField.threeInchShukudai] ?? 0),
        fiveInchShukudaiCount: counter.fiveInchShukudaiCount +
            (draft.counterDeltas[CounterCountField.fiveInchShukudai] ?? 0),
      );

      final pricing = await DatabaseService.getGroupPricingByName(
        updatedCounter.groupName,
      );

      await DatabaseService.updateCounter(counter.id!, updatedCounter);
      await DatabaseService.insertActivityRecord(
        ActivityRecordModel.counterAdjustment(
          counter: updatedCounter,
          occurredAt: draft.occurredAt,
          deltas: draft.counterDeltas,
          pricing: pricing,
          note: draft.note,
        ),
      );
    } else if (draft.type == ActivityRecordType.ticket) {
      await DatabaseService.insertActivityRecord(
        ActivityRecordModel.ticket(
          eventName: draft.eventName,
          occurredAt: draft.occurredAt,
          sessionLabel: draft.sessionLabel,
          note: draft.note,
          quantity: draft.ticketQuantity,
          unitPrice: draft.ticketUnitPrice,
        ),
      );
    }

    await _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredRecords = _filteredRecords;
    final counterRecords = filteredRecords.where((record) => !record.isTicket);
    final ticketRecords = filteredRecords.where((record) => record.isTicket);
    final recordCount = filteredRecords.length;
    final counterCountTotal = counterRecords.fold<int>(
      0,
      (sum, record) => sum + record.counterCountTotal,
    );
    final ticketCountTotal = ticketRecords.fold<int>(
      0,
      (sum, record) => sum + record.ticketQuantity,
    );
    final totalAmount = filteredRecords.fold<double>(
      0,
      (sum, record) => sum + record.totalAmount,
    );

    final typeTotals = {
      for (final field in CounterCountField.values)
        field: counterRecords.fold<int>(
          0,
          (sum, record) => sum + record.countForField(field),
        ),
    };

    final memberTotals = <String, int>{};
    final memberSubtitle = <String, String>{};
    for (final record in counterRecords) {
      memberTotals.update(
        record.subjectName,
        (value) => value + record.counterCountTotal,
        ifAbsent: () => record.counterCountTotal,
      );
      memberSubtitle[record.subjectName] = record.groupName;
    }
    final memberEntries = memberTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final groupSummaries = <String, _GroupSummary>{};
    for (final record in counterRecords) {
      final key = record.groupName.trim().isEmpty ? '未分组' : record.groupName;
      final summary = groupSummaries.putIfAbsent(
        key,
        () => _GroupSummary(groupName: key),
      );
      summary.amount += record.totalAmount;
      summary.recordCount += 1;
      for (final field in CounterCountField.values) {
        summary.counts[field] =
            (summary.counts[field] ?? 0) + record.countForField(field);
      }
    }
    final sortedGroupSummaries = groupSummaries.values.toList()
      ..sort((a, b) => b.totalCount.compareTo(a.totalCount));

    final ticketSummaries = <String, _TicketSummary>{};
    for (final record in ticketRecords) {
      final dateKey = _formatDate(record.occurredAt);
      final sessionKey = record.sessionLabel.trim();
      final key = '$dateKey|${record.subjectName}|$sessionKey';
      final summary = ticketSummaries.putIfAbsent(
        key,
        () => _TicketSummary(
          eventName: record.subjectName,
          sessionLabel: sessionKey,
          date: dateKey,
        ),
      );
      summary.quantity += record.ticketQuantity;
      summary.amount += record.totalAmount;
      summary.notes.add(record.note);
    }
    final sortedTicketSummaries = ticketSummaries.values.toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    const piePalette = [
      Color(0xFF4F46E5),
      Color(0xFF06B6D4),
      Color(0xFF22C55E),
      Color(0xFFF97316),
      Color(0xFFEC4899),
      Color(0xFFEAB308),
      Color(0xFF8B5CF6),
      Color(0xFF14B8A6),
    ];

    final memberPieData = <_PieDatum>[];
    final visibleMembers = memberEntries.take(6).toList();
    for (var index = 0; index < visibleMembers.length; index++) {
      final entry = visibleMembers[index];
      if (entry.value <= 0) {
        continue;
      }
      memberPieData.add(
        _PieDatum(
          label: entry.key,
          value: entry.value.toDouble(),
          color: piePalette[index % piePalette.length],
        ),
      );
    }
    final remainingMemberTotal =
        memberEntries.skip(6).fold<int>(0, (sum, entry) => sum + entry.value);
    if (remainingMemberTotal > 0) {
      memberPieData.add(
        _PieDatum(
          label: '其他成员',
          value: remainingMemberTotal.toDouble(),
          color: const Color(0xFF94A3B8),
        ),
      );
    }

    final groupPieData = <_PieDatum>[];
    final visibleGroups = sortedGroupSummaries.take(5).toList();
    for (var index = 0; index < visibleGroups.length; index++) {
      final summary = visibleGroups[index];
      if (summary.totalCount <= 0) {
        continue;
      }
      groupPieData.add(
        _PieDatum(
          label: summary.groupName,
          value: summary.totalCount.toDouble(),
          color: piePalette[(index + 2) % piePalette.length],
        ),
      );
    }
    final remainingGroupTotal = sortedGroupSummaries
        .skip(5)
        .fold<int>(0, (sum, summary) => sum + summary.totalCount);
    if (remainingGroupTotal > 0) {
      groupPieData.add(
        _PieDatum(
          label: '其他团体',
          value: remainingGroupTotal.toDouble(),
          color: Color(0xFF94A3B8),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('统计与流水'),
        actions: [
          IconButton(
            onPressed: _openPricingPage,
            icon: const Icon(Icons.sell_outlined),
            tooltip: '团体价格',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddRecordDialog,
        icon: const Icon(Icons.add),
        label: const Text('新增记录'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary.withAlpha(16),
                    theme.colorScheme.secondary.withAlpha(10),
                    theme.colorScheme.surface,
                  ],
                ),
              ),
              child: RefreshIndicator(
                onRefresh: _loadData,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            theme.colorScheme.primary.withAlpha(28),
                            theme.colorScheme.secondary.withAlpha(18),
                          ],
                        ),
                        border: Border.all(
                          color: theme.colorScheme.primary.withAlpha(28),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: StatsScope.values.map((scope) {
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(scope.label),
                                    selected: _scope == scope,
                                    onSelected: (_) {
                                      setState(() {
                                        _scope = scope;
                                      });
                                    },
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              IconButton.filledTonal(
                                onPressed: _scope == StatsScope.all
                                    ? null
                                    : () => _moveScope(-1),
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      _scope.label,
                                      style: theme.textTheme.labelLarge,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _scopeTitle,
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.headlineSmall
                                          ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton.filledTonal(
                                onPressed: _canMoveForward
                                    ? () => _moveScope(1)
                                    : null,
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth > 720 ? 4 : 2;
                        final spacing = 12.0;
                        final itemWidth =
                            (constraints.maxWidth - (spacing * (columns - 1))) /
                                columns;

                        return Wrap(
                          spacing: spacing,
                          runSpacing: spacing,
                          children: [
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '记录数',
                                value: '$recordCount',
                                hint: '本周期共 $recordCount 条',
                                icon: Icons.receipt_long_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '拍切总数',
                                value: '$counterCountTotal',
                                hint: '成员记录规格求和',
                                icon: Icons.photo_library_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '门票总数',
                                value: '$ticketCountTotal',
                                hint: '门票记录数量求和',
                                icon: Icons.confirmation_num_outlined,
                              ),
                            ),
                            SizedBox(
                              width: itemWidth,
                              child: _SummaryCard(
                                label: '总金额',
                                value: '¥${_formatAmount(totalAmount)}',
                                hint: '按记录快照价格统计',
                                icon: Icons.payments_outlined,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    if (memberPieData.isNotEmpty || groupPieData.isNotEmpty)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final wide = constraints.maxWidth > 760;
                          final chartWidth = wide
                              ? (constraints.maxWidth - 12) / 2
                              : constraints.maxWidth;

                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              SizedBox(
                                width: chartWidth,
                                child: _PieBreakdownCard(
                                  title: '成员占比',
                                  emptyMessage: '当前周期内还没有成员记录。',
                                  centerLabel: '成员',
                                  data: memberPieData,
                                ),
                              ),
                              SizedBox(
                                width: chartWidth,
                                child: _PieBreakdownCard(
                                  title: '团体占比',
                                  emptyMessage: '当前周期内还没有团体数据。',
                                  centerLabel: '团体',
                                  data: groupPieData,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    if (memberPieData.isNotEmpty || groupPieData.isNotEmpty)
                      const SizedBox(height: 16),
                    _SectionCard(
                      title: '规格汇总',
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: CounterCountField.values.map((field) {
                          return _MetricChip(
                            label: field.label,
                            value: '${typeTotals[field] ?? 0}',
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '团体统计',
                      child: sortedGroupSummaries.isEmpty
                          ? const Text('当前周期内还没有成员记录。')
                          : Column(
                              children: sortedGroupSummaries.map((summary) {
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                summary.groupName,
                                                style: theme
                                                    .textTheme.titleMedium
                                                    ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            Text(
                                              '¥${_formatAmount(summary.amount)}',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: CounterCountField.values
                                              .map((field) {
                                            return _MetricChip(
                                              label: field.shortLabel,
                                              value:
                                                  '${summary.counts[field] ?? 0}',
                                            );
                                          }).toList(),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '门票场次',
                      child: sortedTicketSummaries.isEmpty
                          ? const Text('当前周期内还没有门票记录。')
                          : Column(
                              children: sortedTicketSummaries.map((summary) {
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(
                                    Icons.confirmation_num_outlined,
                                  ),
                                  title: Text(summary.eventName),
                                  subtitle: Text(
                                    [
                                      summary.date,
                                      if (summary.sessionLabel.isNotEmpty)
                                        summary.sessionLabel,
                                      if (summary.notes.isNotEmpty)
                                        summary.notes.last,
                                    ].join(' · '),
                                  ),
                                  trailing: Text(
                                    '${summary.quantity} 张\n¥${_formatAmount(summary.amount)}',
                                    textAlign: TextAlign.right,
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '成员贡献',
                      child: memberEntries.isEmpty
                          ? const Text('当前周期内还没有成员记录。')
                          : Column(
                              children: memberEntries.take(20).map((entry) {
                                final subtitle =
                                    memberSubtitle[entry.key] ?? '';
                                final percent = counterCountTotal == 0
                                    ? 0.0
                                    : entry.value / counterCountTotal;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  entry.key,
                                                  style: theme
                                                      .textTheme.titleMedium
                                                      ?.copyWith(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                if (subtitle.isNotEmpty)
                                                  Text(
                                                    subtitle,
                                                    style: theme
                                                        .textTheme.bodySmall,
                                                  ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            '${entry.value}',
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(999),
                                        child: LinearProgressIndicator(
                                          value: percent.clamp(0.0, 1.0),
                                          minHeight: 8,
                                          backgroundColor: theme.colorScheme
                                              .surfaceContainerHighest,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                    ),
                    const SizedBox(height: 16),
                    _SectionCard(
                      title: '流水明细',
                      child: filteredRecords.isEmpty
                          ? const Text('当前周期内还没有记录。')
                          : Column(
                              children: filteredRecords.take(50).map((record) {
                                final trailingAmount =
                                    '¥${_formatAmount(record.totalAmount)}';
                                final subtitle = record.isTicket
                                    ? [
                                        _formatOccurredAtLabel(
                                            record.occurredAt),
                                        if (record.sessionLabel.isNotEmpty)
                                          record.sessionLabel,
                                        '门票 ${record.ticketQuantity} 张',
                                        if (record.note.isNotEmpty) record.note,
                                      ].join(' · ')
                                    : [
                                        _formatOccurredAtLabel(
                                            record.occurredAt),
                                        if (record.groupName.isNotEmpty)
                                          record.groupName,
                                        record.pricingLabel,
                                        CounterCountField.values
                                            .where(
                                              (field) =>
                                                  record.countForField(field) !=
                                                  0,
                                            )
                                            .map(
                                              (field) =>
                                                  '${field.shortLabel} ${record.countForField(field)}',
                                            )
                                            .join(' / '),
                                        if (record.note.isNotEmpty) record.note,
                                      ].join(' · ');

                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    record.isTicket
                                        ? Icons.confirmation_num_outlined
                                        : Icons.photo_library_outlined,
                                  ),
                                  title: Text(record.subjectName),
                                  subtitle: Text(subtitle),
                                  trailing: Text(trailingAmount),
                                );
                              }).toList(),
                            ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  String _formatAmount(double value) {
    if (value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }
}

enum StatsScope {
  day('日统计'),
  week('周统计'),
  month('月统计'),
  year('年统计'),
  all('全部');

  final String label;

  const StatsScope(this.label);

  DateTimeRange? rangeFor(DateTime anchor) {
    final base = DateTime(anchor.year, anchor.month, anchor.day);
    switch (this) {
      case StatsScope.day:
        return DateTimeRange(
          start: base,
          end: base.add(const Duration(days: 1)),
        );
      case StatsScope.week:
        final start = base.subtract(Duration(days: base.weekday - 1));
        return DateTimeRange(
          start: start,
          end: start.add(const Duration(days: 7)),
        );
      case StatsScope.month:
        return DateTimeRange(
          start: DateTime(anchor.year, anchor.month),
          end: anchor.month == 12
              ? DateTime(anchor.year + 1, 1)
              : DateTime(anchor.year, anchor.month + 1),
        );
      case StatsScope.year:
        return DateTimeRange(
          start: DateTime(anchor.year),
          end: DateTime(anchor.year + 1),
        );
      case StatsScope.all:
        return null;
    }
  }

  DateTime shift(DateTime anchor, int offset) {
    switch (this) {
      case StatsScope.day:
        return anchor.add(Duration(days: offset));
      case StatsScope.week:
        return anchor.add(Duration(days: 7 * offset));
      case StatsScope.month:
        return DateTime(anchor.year, anchor.month + offset, anchor.day);
      case StatsScope.year:
        return DateTime(anchor.year + offset, anchor.month, anchor.day);
      case StatsScope.all:
        return anchor;
    }
  }
}

class _PieDatum {
  final String label;
  final double value;
  final Color color;

  const _PieDatum({
    required this.label,
    required this.value,
    required this.color,
  });
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String hint;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.hint,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(90),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(height: 12),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 6),
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _PieBreakdownCard extends StatelessWidget {
  final String title;
  final String emptyMessage;
  final String centerLabel;
  final List<_PieDatum> data;

  const _PieBreakdownCard({
    required this.title,
    required this.emptyMessage,
    required this.centerLabel,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return _SectionCard(
        title: title,
        child: Text(emptyMessage),
      );
    }

    final total = data.fold<double>(0, (sum, item) => sum + item.value);

    return _SectionCard(
      title: title,
      child: Column(
        children: [
          SizedBox(
            height: 220,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 42,
                    startDegreeOffset: -90,
                    sections: data.map((item) {
                      final percent = total == 0 ? 0.0 : item.value / total;
                      return PieChartSectionData(
                        color: item.color,
                        value: item.value,
                        radius: 54,
                        title: percent >= 0.08
                            ? '${(percent * 100).toStringAsFixed(0)}%'
                            : '',
                        titleStyle:
                            Theme.of(context).textTheme.labelMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                      );
                    }).toList(),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      centerLabel,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      total.toStringAsFixed(
                          total == total.roundToDouble() ? 0 : 1),
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                              ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: data.map((item) {
              final percent = total == 0 ? 0.0 : item.value / total;
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: item.color.withAlpha(26),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: item.color.withAlpha(80),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: item.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${item.label} ${item.value.toStringAsFixed(item.value == item.value.roundToDouble() ? 0 : 1)}'
                      ' · ${(percent * 100).toStringAsFixed(1)}%',
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;

  const _MetricChip({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withAlpha(80),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _GroupSummary {
  final String groupName;
  final Map<CounterCountField, int> counts = {};
  double amount = 0;
  int recordCount = 0;

  _GroupSummary({
    required this.groupName,
  });

  int get totalCount => counts.values.fold(0, (sum, value) => sum + value);
}

class _TicketSummary {
  final String eventName;
  final String sessionLabel;
  final String date;
  int quantity = 0;
  double amount = 0;
  final List<String> notes = [];

  _TicketSummary({
    required this.eventName,
    required this.sessionLabel,
    required this.date,
  });
}
