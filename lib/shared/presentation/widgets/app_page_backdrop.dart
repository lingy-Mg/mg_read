import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// Low-contrast, tab-specific atmosphere behind a primary navigation page.
///
/// It is deliberately a visual-only layer: it has no semantics, input, or
/// layout ownership, and keeps the feature body fully interactive above it.
enum AppPageBackdropStyle { home, search, discover, profile }

class AppPageBackdrop extends StatelessWidget {
  const AppPageBackdrop({required this.style, required this.child, super.key});

  final AppPageBackdropStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final bool isLight = Theme.of(context).brightness == Brightness.light;

    return ColoredBox(
      color: tokens.pageBackground,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ExcludeSemantics(
            child: IgnorePointer(
              child: Opacity(
                opacity: isLight ? 0.32 : 0.08,
                child: Image.asset(
                  _assetPathFor(style),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }

  static String _assetPathFor(AppPageBackdropStyle style) {
    return switch (style) {
      AppPageBackdropStyle.home =>
        'assets/illustrations/page_backdrops/home_paper.png',
      AppPageBackdropStyle.search =>
        'assets/illustrations/page_backdrops/search_index.png',
      AppPageBackdropStyle.discover =>
        'assets/illustrations/page_backdrops/discover_horizon.png',
      AppPageBackdropStyle.profile =>
        'assets/illustrations/page_backdrops/profile_bookmark.png',
    };
  }
}
