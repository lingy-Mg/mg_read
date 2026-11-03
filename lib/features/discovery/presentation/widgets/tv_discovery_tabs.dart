/// Pinned source-home and category tabs. Focus previews a category; OK is
/// reserved for content/actions. Stable keys retain focus across async loads.
library;

import 'package:flutter/material.dart';
import '../../application/tv_discovery_session.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_traversal.dart';

class TvDiscoveryTabs extends StatefulWidget {
  const TvDiscoveryTabs({required this.navigation, required this.target, required this.onSelected, super.key});
  final TvDiscoveryNavigation navigation;
  final String? target;
  final ValueChanged<String?> onSelected;

  @override
  State<TvDiscoveryTabs> createState() => _TvDiscoveryTabsState();
}

class _TvDiscoveryTabsState extends State<TvDiscoveryTabs> {
  final _homeFocus = FocusNode();

  @override
  void didUpdateWidget(TvDiscoveryTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.target == null && oldWidget.target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent != false) requestTvFocus(_homeFocus);
      });
    }
  }

  @override
  void dispose() {
    _homeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    child: SingleChildScrollView(
      key: const Key('tv-discovery-tabs'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in widget.navigation.tabs)
            Padding(
              key: ValueKey(tab.target),
              padding: const EdgeInsets.only(right: 12),
              child: TvFocusable(
                key: ValueKey(tab.target == null ? 'tv-discovery-home' : 'tv-discovery-tab-${tab.target}'),
                focusNode: tab.target == null ? _homeFocus : null,
                selected: tab.target == widget.target,
                activateOnFocus: true,
                onPressed: () => widget.onSelected(tab.target),
                child: Text(tab.label, style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
        ],
      ),
    ),
  );
}
