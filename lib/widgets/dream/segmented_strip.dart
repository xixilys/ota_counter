import 'package:flutter/material.dart';

/// A single-row segmented control for 2-6 short labels.
///
/// Unlike a [Wrap] of [ChoiceChip]s this never breaks a label onto a second
/// line: it divides the available width evenly and scales each label down
/// when the text is large, so 「全部」 cannot end up alone on its own row.
class DreamSegmentedStrip<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T value) labelOf;
  final Color? accent;
  final double minTouchHeight;

  const DreamSegmentedStrip({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
    this.accent,
    this.minTouchHeight = 38,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paint = accent ?? scheme.primary;
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.8),
        ),
      ),
      child: Row(
        children: [
          for (final value in values)
            Expanded(
              child: Semantics(
                selected: value == selected,
                button: true,
                label: labelOf(value),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: value == selected ? null : () => onSelected(value),
                    child: Ink(
                      decoration: BoxDecoration(
                        color: value == selected
                            ? Color.alphaBlend(
                                paint.withValues(alpha: 0.16),
                                scheme.surface,
                              )
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: minTouchHeight + (textScale > 1.2 ? 6 : 0),
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                labelOf(value),
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.1,
                                  fontWeight: value == selected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  color: value == selected
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
