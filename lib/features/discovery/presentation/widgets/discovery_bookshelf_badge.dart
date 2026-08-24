import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

class DiscoveryBookshelfBadge extends StatelessWidget {
  const DiscoveryBookshelfBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.accentSoft,
        borderRadius: AppRadii.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          '已在书架',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: tokens.accent),
        ),
      ),
    );
  }
}
