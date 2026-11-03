/// One outer TV bar for library, source content, discovery, settings and search.
/// Source tabs come from the root scope, never from hard-coded movie/series
/// categories. The bar scrolls horizontally as remote focus reveals each item.
library;

import 'package:flutter/material.dart';
import '../app_navigation_destination.dart';
import '../tv_source_navigation_scope.dart';
import 'tv_destination_action.dart';

class TvTopNavigation extends StatelessWidget {
  const TvTopNavigation({
    required this.selected,
    required this.onSelected,
    this.homeFocusNode,
    this.onHomeSelected,
    this.homeSelected,
    this.autofocus = true,
    super.key,
  });
  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final FocusNode? homeFocusNode;
  final bool autofocus;
  final VoidCallback? onHomeSelected;
  final bool? homeSelected;

  @override
  Widget build(BuildContext context) {
    final source = TvSourceNavigationScope.maybeOf(context);
    Widget destination(AppNavigationDestination value, String label) {
      final active = value == AppNavigationDestination.home && homeSelected != null
          ? homeSelected!
          : value == selected && (value != AppNavigationDestination.discover || source?.showContent != true);
      return TvDestinationAction(
        key: Key('app-nav-${value.name}'),
        destination: value,
        current: selected,
        selected: active,
        autofocus: autofocus && active,
        focusNode: value == AppNavigationDestination.home ? homeFocusNode : null,
        onPressed: () {
          if (value == AppNavigationDestination.home && onHomeSelected != null) {
            onHomeSelected!();
          } else if (!active) {
            onSelected(value);
          }
        },
        child: Text(label, style: Theme.of(context).textTheme.titleLarge),
      );
    }

    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            if (MediaQuery.sizeOf(context).width >= 900) ...[
              Text('MgRead TV', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(width: 24),
            ],
            Expanded(
              child: SingleChildScrollView(
                key: const Key('tv-outer-navigation'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    destination(AppNavigationDestination.home, '首页'),
                    for (final entry in source?.entries ?? const <TvSourceNavigationEntry>[]) ...[
                      const SizedBox(width: 12),
                      TvDestinationAction(
                        key: ValueKey<Object>(('tv-source-tab', source!.sourceId, entry.target)),
                        navigationId: (source.sourceId, entry.target),
                        destination: AppNavigationDestination.discover,
                        current: selected,
                        selected: selected == AppNavigationDestination.discover && source.showContent && source.target == entry.target,
                        autofocus:
                            autofocus &&
                            selected == AppNavigationDestination.discover &&
                            source.showContent &&
                            source.target == entry.target,
                        onPressed: () => source.onSelected(entry.target),
                        child: Text(entry.label, style: Theme.of(context).textTheme.titleLarge),
                      ),
                    ],
                    const SizedBox(width: 12),
                    destination(AppNavigationDestination.discover, '发现'),
                    const SizedBox(width: 12),
                    destination(AppNavigationDestination.profile, '设置'),
                    const SizedBox(width: 12),
                    destination(AppNavigationDestination.search, '搜索'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
