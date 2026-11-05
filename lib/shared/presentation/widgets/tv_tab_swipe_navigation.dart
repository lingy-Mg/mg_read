/// Route-local touch navigation for the four top-level TV destinations.
/// Owns only a pending horizontal drag; selection, source loading and routing
/// remain caller-owned. Uses the same order as TvTopNavigation, without wrapping.
/// Nested horizontal controls and vertical scrollables win their gesture arenas.
/// Covered routes, cancelled drags and dependency changes discard pending input.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../app_navigation_destination.dart';
import '../tv_mode_scope.dart';
import '../tv_source_navigation_scope.dart';
import 'tv_destination_action.dart';

class TvTabSwipeNavigation extends StatefulWidget {
  const TvTabSwipeNavigation({required this.selected, required this.onSelected, required this.child, super.key});

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final Widget child;

  @override
  State<TvTabSwipeNavigation> createState() => _TvTabSwipeNavigationState();
}

class _TvTabSwipeNavigationState extends State<TvTabSwipeNavigation> {
  double _distance = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _distance = 0;
  }

  @override
  void didUpdateWidget(TvTabSwipeNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    _distance = 0;
  }

  void _finish(DragEndDetails details, TvSourceNavigationScope? source) {
    final distance = _distance;
    _distance = 0;
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final velocity = details.primaryVelocity ?? 0;
    final isFling = distance.abs() >= 24 && velocity.abs() >= 600 && distance.sign == velocity.sign;
    if (distance.abs() < 64 && !isFling) return;

    final entries = source?.entries ?? const <TvSourceNavigationEntry>[];
    final destinations = [
      AppNavigationDestination.home,
      for (final _ in entries) AppNavigationDestination.discover,
      AppNavigationDestination.discover,
      AppNavigationDestination.profile,
      AppNavigationDestination.search,
    ];
    final int current;
    if (widget.selected == AppNavigationDestination.discover && source?.showContent == true) {
      final entry = entries.indexWhere((entry) => entry.target == source!.target);
      if (entry < 0) return;
      current = entry + 1;
    } else {
      current = destinations.lastIndexOf(widget.selected);
    }
    final next = current + (distance < 0 ? 1 : -1);
    if (next < 0 || next >= destinations.length) return;
    if (next > 0 && next <= entries.length) {
      source!.onSelected(entries[next - 1].target);
    } else {
      final destination = destinations[next];
      TvNavigationHandoff.request(context, destination);
      widget.onSelected(destination);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = TvModeScope.isEnabled(context);
    final source = TvSourceNavigationScope.maybeOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus},
      onHorizontalDragStart: enabled ? (_) => _distance = 0 : null,
      onHorizontalDragUpdate: enabled ? (details) => _distance += details.delta.dx : null,
      onHorizontalDragCancel: enabled ? () => _distance = 0 : null,
      onHorizontalDragEnd: enabled ? (details) => _finish(details, source) : null,
      // An accepted Flutter drag may end when its pointer is cancelled. Clear
      // intent in the child listener before the ancestor recognizer sees it.
      child: Listener(onPointerCancel: (_) => _distance = 0, child: widget.child),
    );
  }
}
