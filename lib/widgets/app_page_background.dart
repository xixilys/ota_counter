import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Flat page background shared by the home, statistics and settings pages.
///
/// Kept as a plain neutral on purpose: the color on these pages belongs to
/// the content (member colors, the cheki print, the ticket), not to the page.
class AppPageBackground extends StatelessWidget {
  final Widget child;

  const AppPageBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.paper(Theme.of(context).brightness),
      child: child,
    );
  }
}
