import 'package:flutter/material.dart';

import '../../models/counter_model.dart';
import '../../services/person_card_service.dart';

/// Compact "also in: A / B" affiliation switcher for a real person with
/// several group cards. It only changes the card being viewed / counted; the
/// person's records from every group stay on the detail page.
class PersonGroupSwitcher extends StatelessWidget {
  final List<CounterModel> cards;
  final CounterModel selected;
  final ValueChanged<CounterModel> onSelected;
  final VoidCallback? onManage;

  const PersonGroupSwitcher({
    super.key,
    required this.cards,
    required this.selected,
    required this.onSelected,
    this.onManage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = <String, CounterModel>{};
    for (final card in cards) {
      final group = card.groupName.trim().isEmpty ? '未分组' : card.groupName.trim();
      groups.putIfAbsent(group.toLowerCase(), () => card);
    }
    if (groups.length <= 1) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '也在',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              for (final card in groups.values)
                _AffiliationPill(
                  card: card,
                  selected: _sameGroup(card, selected),
                  past: PersonCardService.isPast(card),
                  onTap: () => onSelected(card),
                ),
              if (onManage != null)
                Semantics(
                  button: true,
                  label: '跨团管理',
                  child: InkWell(
                    onTap: onManage,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.tune_rounded,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  bool _sameGroup(CounterModel a, CounterModel b) =>
      a.groupName.trim().toLowerCase() == b.groupName.trim().toLowerCase();
}

class _AffiliationPill extends StatelessWidget {
  final CounterModel card;
  final bool selected;
  final bool past;
  final VoidCallback onTap;

  const _AffiliationPill({
    required this.card,
    required this.selected,
    required this.past,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = card.colorValue;
    final group = card.groupName.trim().isEmpty ? '未分组' : card.groupName.trim();
    final isDark = theme.brightness == Brightness.dark;
    final fill = selected
        ? Color.alphaBlend(accent.withValues(alpha: isDark ? 0.30 : 0.18),
            scheme.surface)
        : scheme.surfaceContainerLowest;
    final ink = selected ? scheme.onSurface : scheme.onSurfaceVariant;

    return Material(
      color: fill,
      shape: StadiumBorder(
        side: BorderSide(
          color: selected
              ? accent.withValues(alpha: isDark ? 0.95 : 0.75)
              : scheme.outlineVariant,
          width: selected ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 5, 11, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.surface.withValues(alpha: 0.9),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                group,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: ink,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
              if (past) ...[
                const SizedBox(width: 4),
                Text(
                  '过往',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
