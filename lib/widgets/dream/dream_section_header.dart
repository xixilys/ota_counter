import 'package:flutter/material.dart';

import 'sparkle_mark.dart';
import 'washi_tape.dart';

/// A scrapbook-style section heading: tiny drawn sparkle, title, optional
/// paper count and trailing hint, underlined by a short strip of coloured
/// washi tape.
///
/// Use this instead of bare Material section titles so all pages share the
/// same rhythm. Keep trailing text short (it is a hint, not a second title).
class DreamSectionHeader extends StatelessWidget {
  final String title;
  final String? countLabel;
  final String? eyebrow;
  final String? trailingText;
  final Widget? trailing;
  final Color? accent;
  final bool sparkle;
  final bool underline;
  final double titleSize;

  const DreamSectionHeader({
    super.key,
    required this.title,
    this.countLabel,
    this.eyebrow,
    this.trailingText,
    this.trailing,
    this.accent,
    this.sparkle = true,
    this.underline = true,
    this.titleSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paint = accent ?? scheme.primary;
    final trailingWidget = trailing ??
        (trailingText == null
            ? null
            : Text(
                trailingText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (sparkle) ...[
              SparkleMark(
                size: 14,
                color: paint,
                variant: SparkleVariant.star,
              ),
              const SizedBox(width: 7),
            ],
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (eyebrow != null)
                    Text(
                      eyebrow!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: paint,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: titleSize,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                      if (countLabel != null) ...[
                        const SizedBox(width: 7),
                        Text(
                          countLabel!,
                          maxLines: 1,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (trailingWidget != null) ...[
              const SizedBox(width: 8),
              trailingWidget,
            ],
          ],
        ),
        if (underline)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: WashiTape(
              color: paint.withValues(alpha: 0.55),
              width: 34,
              height: 5,
              angle: -0.03,
              tornEnds: false,
              folds: false,
            ),
          ),
      ],
    );
  }
}
