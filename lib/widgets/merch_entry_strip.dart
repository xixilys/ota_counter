import 'package:flutter/material.dart';

import '../models/merch_purchase_model.dart';
import '../theme/app_theme.dart';

/// Compact home entry next to the ticket stub: a washi-tape tab that opens the
/// 周边手帐 page. Kept deliberately small so the home grid stays the hero.
class MerchEntryStrip extends StatelessWidget {
  final MerchStats stats;
  final VoidCallback onTap;

  const MerchEntryStrip({
    super.key,
    required this.stats,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final isEmpty = stats.isEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
          decoration: BoxDecoration(
            color: AppTheme.wash(
              AppTheme.sakura,
              scheme.surface,
              brightness,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppTheme.sakura.withValues(alpha: 0.26),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 28,
                decoration: BoxDecoration(
                  color: AppTheme.sakura.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                Icons.local_mall_outlined,
                size: 19,
                color: AppTheme.readableAccent(AppTheme.sakura, brightness),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '周边手帐',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      isEmpty
                          ? '生写真、吧唧、应援棒…都记在这里'
                          : '${stats.itemCount} 件 · ¥${_formatAmount(stats.amount)}',
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
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
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
