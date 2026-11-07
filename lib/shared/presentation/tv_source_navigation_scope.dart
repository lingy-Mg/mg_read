/// Immutable outer TV source navigation supplied by the application root.
/// Shared widgets only render these entries and invoke callbacks; discovery
/// loading, selected-source persistence and routing stay in the app layer.
library;

import 'package:flutter/material.dart';

class TvSourceNavigationEntry {
  const TvSourceNavigationEntry({required this.label, required this.target});
  final String label;
  final String? target;
}

class TvSourceNavigationScope extends InheritedWidget {
  const TvSourceNavigationScope({
    required this.entries,
    required this.sourceId,
    required this.target,
    required this.showContent,
    required this.onSelected,
    this.onRefresh,
    this.loading = false,
    this.onRetry,
    required super.child,
    super.key,
  });
  final List<TvSourceNavigationEntry> entries;
  final String? sourceId;
  final String? target;
  final bool showContent;
  final ValueChanged<String?> onSelected;
  final VoidCallback? onRefresh;
  final bool loading;
  final VoidCallback? onRetry;

  static TvSourceNavigationScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TvSourceNavigationScope>();

  @override
  bool updateShouldNotify(TvSourceNavigationScope oldWidget) =>
      sourceId != oldWidget.sourceId ||
      target != oldWidget.target ||
      entries != oldWidget.entries ||
      showContent != oldWidget.showContent ||
      loading != oldWidget.loading ||
      onRetry != oldWidget.onRetry ||
      onSelected != oldWidget.onSelected ||
      onRefresh != oldWidget.onRefresh;
}
