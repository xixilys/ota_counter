import 'package:flutter/material.dart';

import '../../models/counter_model.dart';
import '../../models/idol_database_models.dart';
import '../../services/database_service.dart';
import '../../services/idol_database_service.dart';
import '../../services/person_card_service.dart';
import '../dream/dream_kit.dart';

/// Opens the "this real person's cards across groups" manager.
/// Returns true when cards / person links changed.
Future<bool> showPersonCardsSheet(
  BuildContext context, {
  required CounterModel anchor,
}) async {
  var changed = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: PersonCardsPanel(
        anchor: anchor,
        onChanged: () => changed = true,
      ),
    ),
  );
  return changed;
}

/// Body of the cross-group card manager. Public so the UI preview test can
/// render it without a modal route.
class PersonCardsPanel extends StatefulWidget {
  final CounterModel anchor;
  final VoidCallback? onChanged;

  const PersonCardsPanel({
    super.key,
    required this.anchor,
    this.onChanged,
  });

  @override
  State<PersonCardsPanel> createState() => _PersonCardsPanelState();
}

class _PersonCardsPanelState extends State<PersonCardsPanel> {
  late CounterModel _anchor;
  PersonCardOverview? _overview;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _anchor = widget.anchor;
    _reload();
  }

  Future<void> _reload() async {
    try {
      final counters = await DatabaseService.getCounters();
      var anchor = _anchor;
      for (final counter in counters) {
        if (counter.id == _anchor.id) {
          anchor = counter;
          break;
        }
      }
      final overview = await PersonCardService.loadOverview(
        anchor,
        counters: counters,
      );
      if (!mounted) return;
      setState(() {
        _anchor = anchor;
        _overview = overview;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    String failureLabel = '操作失败',
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reload();
      widget.onChanged?.call();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$failureLabel：$error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setCurrent(PersonCardInfo card) async {
    await _run(
      () => PersonCardService.setCurrentCard(_anchor, card.counter.id),
      failureLabel: '设置当前卡片失败',
    );
  }

  Future<void> _togglePast(PersonCardInfo card) async {
    await _run(
      () => PersonCardService.setPast(card.counter, !card.isPast),
      failureLabel: '标记过往失败',
    );
  }

  Future<void> _unlink(PersonCardInfo card) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除真人关联'),
        content: Text(
          '只会把「${card.counter.name} · ${card.groupLabel}」这张卡从真人主档拆开，'
          '卡上的数量和已有流水都不会变。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => PersonCardService.unlinkCounter(card.counter),
      failureLabel: '解除关联失败',
    );
  }

  Future<void> _createPersonForAnchor() async {
    final suggested = _anchor.personName.trim().isNotEmpty
        ? _anchor.personName.trim()
        : _anchor.name.trim();
    final controller = TextEditingController(text: suggested);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建真人主档'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '真人主档名',
            hintText: '同一真人跨团请一致，例如本名或常用名',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('新建并关联'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _run(
      () async {
        final person = await PersonCardService.ensurePerson(name);
        await PersonCardService.linkCounterToPerson(_anchor, person);
        _anchor = _withPerson(_anchor, person);
      },
      failureLabel: '新建真人失败',
    );
  }

  CounterModel _withPerson(CounterModel counter, IdolPerson person) =>
      CounterModel(
        id: counter.id,
        name: counter.name,
        groupName: counter.groupName,
        personId: person.id,
        personName: person.name,
        color: counter.color,
        isHidden: counter.isHidden,
        threeInchCount: counter.threeInchCount,
        fiveInchCount: counter.fiveInchCount,
        unsignedThreeInchCount: counter.unsignedThreeInchCount,
        unsignedFiveInchCount: counter.unsignedFiveInchCount,
        groupCutCount: counter.groupCutCount,
        threeInchShukudaiCount: counter.threeInchShukudaiCount,
        fiveInchShukudaiCount: counter.fiveInchShukudaiCount,
      );

  Future<void> _linkToExistingPerson(PersonCardInfo? card) async {
    final person = await _showPersonPicker();
    if (person == null) return;
    await _run(
      () async {
        if (card == null) {
          await PersonCardService.linkCounterToPerson(_anchor, person);
          _anchor = _withPerson(_anchor, person);
        } else {
          await PersonCardService.linkCounterToPerson(card.counter, person);
        }
      },
      failureLabel: '关联真人失败',
    );
  }

  Future<IdolPerson?> _showPersonPicker() async {
    List<IdolPerson> people;
    try {
      people = await IdolDatabaseService.getPeople();
    } catch (_) {
      people = const [];
    }
    if (!mounted) return null;
    return showModalBottomSheet<IdolPerson>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _PersonPickerSheet(people: people),
    );
  }

  Future<void> _mergeSameName() async {
    final overview = _overview;
    if (overview == null || overview.sameNameCards.isEmpty) return;
    final others = overview.sameNameCards;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('合并为同一真人'),
        content: Text(
          '把 ${others.map((card) => '「${card.name} · ${card.groupName.trim().isEmpty ? '未分组' : card.groupName.trim()}」').join('、')}'
          ' 也归到「${overview.displayName}」。只共享真人主档，各团计数与历史流水都不会合并。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('合并'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(
      () => PersonCardService.mergeCardsIntoPerson(_anchor, others),
      failureLabel: '合并真人失败',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overview = _overview;
    final accent = (_overview?.cards.isNotEmpty ?? false)
        ? _overview!.cards.first.counter.colorValue
        : _anchor.colorValue;

    return Material(
      color: scheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WashiHeader(accent: accent),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 14, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _loading
                            ? '加载跨团卡片'
                            : (overview?.displayName ?? _anchor.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _loading
                            ? ''
                            : '同一真人 · ${overview!.cards.length} 个团籍 · '
                                '共 ${overview.totalCount} 张切奇',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
                    children: [
                      _IdentityHint(
                        personId: overview!.personId,
                        hasPerson: _anchor.personId != null ||
                            _anchor.personName.trim().isNotEmpty,
                        onCreate: _busy ? null : _createPersonForAnchor,
                        onLink:
                            _busy ? null : () => _linkToExistingPerson(null),
                      ),
                      const SizedBox(height: 14),
                      for (final card in overview.cards) ...[
                        _PersonCardRow(
                          card: card,
                          busy: _busy,
                          onCurrent: () => _setCurrent(card),
                          onPast: () => _togglePast(card),
                          onUnlink: card.counter.id == null
                              ? null
                              : () => _unlink(card),
                          onLink: () => _linkToExistingPerson(card),
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (overview.sameNameCards.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _SameNameSection(
                          cards: overview.sameNameCards,
                          onMerge: _busy ? null : _mergeSameName,
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        '提示：转团时保留旧团卡片，再为新团添加一张卡，同一个真人就能同时看到两段历史；'
                        '“当前卡片”和“过往”只存在本机，不会改写流水。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
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

class _WashiHeader extends StatelessWidget {
  final Color accent;

  const _WashiHeader({required this.accent});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 34,
      child: Center(
        child: WashiTape(
          color: DreamPalette.tape(accent, theme.brightness),
          width: 150,
          height: 18,
          angle: -0.05,
        ),
      ),
    );
  }
}

class _IdentityHint extends StatelessWidget {
  final int? personId;
  final bool hasPerson;
  final VoidCallback? onCreate;
  final VoidCallback? onLink;

  const _IdentityHint({
    required this.personId,
    required this.hasPerson,
    required this.onCreate,
    required this.onLink,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            hasPerson ? Icons.link_rounded : Icons.link_off_rounded,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              personId == null
                  ? '这些卡还没有共享的真人主档；同名卡片不会被自动合并。'
                  : '真人主档 #$personId · 各团卡片独立计数、共享同一个真人。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
          if (!hasPerson && onCreate != null) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: onCreate,
              child: const Text('新建'),
            ),
          ],
          if (onLink != null) ...[
            const SizedBox(width: 0),
            TextButton(
              onPressed: onLink,
              child: Text(hasPerson ? '换主档' : '关联'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PersonCardRow extends StatelessWidget {
  final PersonCardInfo card;
  final bool busy;
  final VoidCallback onCurrent;
  final VoidCallback onPast;
  final VoidCallback? onUnlink;
  final VoidCallback onLink;

  const _PersonCardRow({
    required this.card,
    required this.busy,
    required this.onCurrent,
    required this.onPast,
    required this.onUnlink,
    required this.onLink,
  });

  String _dayLabel(DateTime? day) {
    if (day == null) return '还没有流水';
    final now = DateTime.now();
    final diff = now.difference(day).inDays;
    if (diff <= 0) return '最近：今天';
    if (diff == 1) return '最近：昨天';
    if (diff < 30) return '最近：$diff 天前';
    String two(int n) => n.toString().padLeft(2, '0');
    return '最近：${day.year}-${two(day.month)}-${two(day.day)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final accent = card.counter.colorValue;
    final group = card.groupLabel;
    final ink = scheme.onSurface;

    return Container(
      decoration: BoxDecoration(
        color: card.isCurrent
            ? Color.alphaBlend(
                accent.withValues(alpha: isDark ? 0.18 : 0.10),
                scheme.surface,
              )
            : scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: card.isCurrent
              ? accent.withValues(alpha: isDark ? 0.8 : 0.55)
              : scheme.outlineVariant,
          width: card.isCurrent ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 5, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            group,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (card.isCurrent)
                          _TinySticker(label: '当前', accent: accent),
                        if (card.isPast) ...[
                          const SizedBox(width: 4),
                          _TinySticker(label: '过往', accent: scheme.outline),
                        ],
                        if (card.formerMembership) ...[
                          const SizedBox(width: 4),
                          _TinySticker(
                            label: '已毕业',
                            accent: scheme.onSurfaceVariant,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${card.counter.name} · ${card.counter.count} 张切奇',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _dayLabel(card.lastActivity),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuButton<_CardAction>(
              enabled: !busy,
              tooltip: '管理这张卡',
              onSelected: (action) {
                switch (action) {
                  case _CardAction.current:
                    onCurrent();
                  case _CardAction.past:
                    onPast();
                  case _CardAction.unlink:
                    onUnlink?.call();
                  case _CardAction.link:
                    onLink();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _CardAction.current,
                  enabled: card.isCurrent == false,
                  child: const Text('设为当前卡片'),
                ),
                PopupMenuItem(
                  value: _CardAction.past,
                  child: Text(card.isPast ? '取消过往标记' : '标为过往 / 毕业'),
                ),
                PopupMenuItem(
                  value: _CardAction.link,
                  child: const Text('关联到其他真人主档'),
                ),
                PopupMenuItem(
                  value: _CardAction.unlink,
                  enabled: onUnlink != null,
                  child: const Text('解除这张卡的真人关联'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _CardAction { current, past, unlink, link }

class _TinySticker extends StatelessWidget {
  final String label;
  final Color accent;

  const _TinySticker({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    return StickerBadge(
      value: label,
      color: accent,
      shape: StickerShape.rounded,
      outlineWidth: 1.5,
      shadow: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      valueFontSize: 9.5,
    );
  }
}

class _SameNameSection extends StatelessWidget {
  final List<CounterModel> cards;
  final VoidCallback? onMerge;

  const _SameNameSection({required this.cards, required this.onMerge});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.copy_all_rounded,
                  size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '同名、还没关联的卡片',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final card in cards)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${card.name} · ${card.groupName.trim().isEmpty ? '未分组' : card.groupName.trim()}'
                '（${card.count} 张）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onMerge,
              icon: const Icon(Icons.link_rounded, size: 17),
              label: const Text('确认是同一人，合并主档'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonPickerSheet extends StatefulWidget {
  final List<IdolPerson> people;

  const _PersonPickerSheet({required this.people});

  @override
  State<_PersonPickerSheet> createState() => _PersonPickerSheetState();
}

class _PersonPickerSheetState extends State<_PersonPickerSheet> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final people = widget.people
        .where((person) =>
            query.isEmpty || person.name.trim().toLowerCase().contains(query))
        .take(80)
        .toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: SizedBox(
          height: 460,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
                child: Text('关联到已有真人主档', style: theme.textTheme.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索真人主档名',
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: people.isEmpty
                    ? Center(
                        child: Text(
                          widget.people.isEmpty ? '还没有真人主档，先新建一个' : '没有匹配的真人主档',
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.builder(
                        itemCount: people.length,
                        itemBuilder: (context, i) {
                          final person = people[i];
                          return ListTile(
                            leading: CircleAvatar(
                              radius: 16,
                              child: Text(person.name.trim().isEmpty
                                  ? '?'
                                  : person.name.trim().substring(0, 1)),
                            ),
                            title: Text(person.name),
                            subtitle: Text(person.id == null
                                ? '本机主档'
                                : '主档 #${person.id}'),
                            onTap: () => Navigator.of(context).pop(person),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
