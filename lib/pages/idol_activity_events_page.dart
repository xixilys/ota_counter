import 'package:flutter/material.dart';

import '../models/idol_activity_event_model.dart';
import '../services/idol_database_service.dart';
import '../widgets/app_page_background.dart';
import '../widgets/no_autofill_text_field.dart';
import 'ticket_pricing_page.dart';

class IdolActivityEventsPage extends StatefulWidget {
  const IdolActivityEventsPage({super.key});

  @override
  State<IdolActivityEventsPage> createState() => _IdolActivityEventsPageState();
}

class _IdolActivityEventsPageState extends State<IdolActivityEventsPage> {
  final TextEditingController _searchController = TextEditingController();
  List<IdolActivityEvent> _events = [];
  Map<String, String> _meta = {};
  String _query = '';
  bool _loading = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool syncRemote = false}) async {
    if (syncRemote) {
      setState(() => _syncing = true);
      try {
        await IdolDatabaseService.syncActivityEventsFromRemote();
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('同步演出名单失败：$error')),
          );
        }
      } finally {
        if (mounted) setState(() => _syncing = false);
      }
    }

    final now = DateTime.now();
    final events = await IdolDatabaseService.getActivityEvents(
      from: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 30)),
      to: DateTime(now.year, now.month, now.day).add(const Duration(days: 240)),
      limit: 1000,
    );
    final meta = await IdolDatabaseService.getMeta();
    if (!mounted) return;
    setState(() {
      _events = events;
      _meta = meta;
      _loading = false;
    });
  }

  List<IdolActivityEvent> get _filteredEvents {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _events;
    return _events.where((event) {
      return event.eventName.toLowerCase().contains(query) ||
          event.city.toLowerCase().contains(query) ||
          event.venue.toLowerCase().contains(query) ||
          event.groupLabel.toLowerCase().contains(query) ||
          event.description.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final events = _filteredEvents;
    final sourceLabel = _meta['activity_events_source_label'] ?? '';
    final generatedAt = _meta['activity_events_generated_at'] ?? '';
    final syncedAt = _meta['activity_events_synced_at'] ?? '';
    final pricedCount =
        _events.where((event) => event.ticketSummary.isNotEmpty).length;
    final freeCount = _events.where((event) => event.isFree).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('演出名单'),
        actions: [
          IconButton(
            tooltip: '门票价格',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const TicketPricingPage(),
                ),
              );
            },
            icon: const Icon(Icons.local_activity_outlined),
          ),
          IconButton(
            tooltip: '同步最新演出名单',
            onPressed: _syncing ? null : () => _load(syncRemote: true),
            icon: _syncing
                ? const SizedBox(
                    width: 19,
                    height: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_download_rounded),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _syncing ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AppPageBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            scheme.primaryContainer,
                            scheme.secondaryContainer,
                          ],
                        ),
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: 0.14),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LIVE SCHEDULE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                              fontSize: 8.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_events.length} 个近期场次',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sourceLabel.isEmpty
                                ? '来自 MineCool 的本地缓存'
                                : '来源：$sourceLabel',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (_events.isNotEmpty)
                            Text(
                              '票价识别 $pricedCount/${_events.length}'
                              '${freeCount == 0 ? '' : ' · 免费 $freeCount'}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          if (syncedAt.isNotEmpty)
                            Text(
                              '本地同步：${_formatDateTime(syncedAt)}'
                              '${generatedAt.isEmpty ? '' : ' · 上游：${_formatDateTime(generatedAt)}'}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: _syncing
                                    ? null
                                    : () => _load(syncRemote: true),
                                icon: const Icon(
                                  Icons.sync_rounded,
                                  size: 17,
                                ),
                                label: const Text('同步最新场次'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    NoAutofillTextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search_rounded),
                        labelText: '搜索活动 / 城市 / 场地 / 团体',
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                                icon: const Icon(Icons.clear_rounded),
                              ),
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 14),
                    if (events.isEmpty)
                      _EmptyEventsCard(
                        hasQuery: _query.trim().isNotEmpty,
                        onSync: _syncing ? null : () => _load(syncRemote: true),
                      )
                    else
                      for (final event in events) ...[
                        _EventCard(event: event),
                        const SizedBox(height: 10),
                      ],
                  ],
                ),
              ),
      ),
    );
  }

  static String _formatDateTime(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)} '
        '${two(parsed.hour)}:${two(parsed.minute)}';
  }
}

class _EventCard extends StatelessWidget {
  final IdolActivityEvent event;

  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final month = event.eventDate.month.toString().padLeft(2, '0');
    final day = event.eventDate.day.toString().padLeft(2, '0');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: scheme.primaryContainer,
              ),
              child: Column(
                children: [
                  Text(
                    month,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    day,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                    ),
                  ),
                  Text(
                    _weekday(event.eventDate),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    event.eventName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (event.city.isNotEmpty) event.city,
                      if (event.venue.isNotEmpty) event.venue,
                      if (event.sessionLabel.isNotEmpty) event.sessionLabel,
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (event.ticketSummary.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: event.isFree
                            ? scheme.tertiaryContainer
                            : scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            event.isFree
                                ? Icons.card_giftcard_rounded
                                : Icons.local_activity_outlined,
                            size: 13,
                            color: event.isFree
                                ? scheme.onTertiaryContainer
                                : scheme.onPrimaryContainer,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              event.ticketSummary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: event.isFree
                                    ? scheme.onTertiaryContainer
                                    : scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (event.groups.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final group in event.groups.take(4))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              group.name,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSecondaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _weekday(DateTime value) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${labels[value.weekday - 1]}';
  }
}

class _EmptyEventsCard extends StatelessWidget {
  final bool hasQuery;
  final VoidCallback? onSync;

  const _EmptyEventsCard({required this.hasQuery, required this.onSync});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: [
          Icon(
            hasQuery ? Icons.search_off_rounded : Icons.event_busy_rounded,
            size: 34,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 10),
          Text(
            hasQuery ? '没有匹配的场次' : '还没有缓存演出名单',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasQuery ? '换个关键词试试。' : '同步 MineCool 的最新场次后，这里会显示。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (!hasQuery) ...[
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: onSync,
              icon: const Icon(Icons.cloud_download_rounded, size: 17),
              label: const Text('同步最新场次'),
            ),
          ],
        ],
      ),
    );
  }
}
