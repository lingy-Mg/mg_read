/// Root bridge from discovery snapshots to the shared outer TV navigation.
/// Starts source loading only after the first usable library frame. Source
/// selection lives in discovery; the query flag selects content versus the
/// source chooser without exposing opaque source targets in route URLs.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'app_startup.dart';
import '../features/discovery/application/discovery_page_controller.dart';
import '../shared/presentation/tv_source_navigation_scope.dart';
import '../shared/presentation/widgets/tv_destination_action.dart';

class AppTvSourceNavigation extends ConsumerStatefulWidget {
  const AppTvSourceNavigation({required this.enabled, required this.router, required this.child, super.key});
  final bool enabled;
  final GoRouter router;
  final Widget child;

  @override
  ConsumerState<AppTvSourceNavigation> createState() => _AppTvSourceNavigationState();
}

class _AppTvSourceNavigationState extends ConsumerState<AppTvSourceNavigation> {
  bool _ready = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) unawaited(_start());
  }

  Future<void> _start() async {
    final generation = ++_generation;
    await ref.read(appStartupControllerProvider).waitForSuccessfulLibraryTerminalFrame();
    if (!mounted || !widget.enabled || generation != _generation) return;
    ref.read(discoveryPageControllerProvider.notifier).configureTvMode(true);
    setState(() => _ready = true);
  }

  @override
  void didUpdateWidget(AppTvSourceNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled == widget.enabled) return;
    if (widget.enabled) {
      unawaited(_start());
    } else {
      ++_generation;
      if (_ready) {
        final controller = ref.read(discoveryPageControllerProvider.notifier);
        scheduleMicrotask(() => controller.configureTvMode(false));
      }
      _ready = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _ready;
    final snapshot = active ? ref.watch(discoveryPageControllerProvider) : null;
    final controller = active ? ref.read(discoveryPageControllerProvider.notifier) : null;
    final navigation = controller?.tvNavigation;
    return ListenableBuilder(
      listenable: widget.router.routeInformationProvider,
      builder: (context, _) {
        final uri = widget.router.routeInformationProvider.value.uri;
        return TvSourceNavigationScope(
          sourceId: snapshot?.selectedSourceId,
          target: controller?.tvPrimaryTarget,
          entries: [for (final entry in navigation?.tabs ?? []) TvSourceNavigationEntry(label: entry.label, target: entry.target)],
          showContent: uri.path == '/discover' && uri.queryParameters['tv'] == 'content',
          onRefresh: controller == null ? null : () => unawaited(controller.refresh()),
          onSelected: (target) {
            if (controller == null) return;
            if (controller.tvPrimaryTarget != target || uri.path != '/discover' || uri.queryParameters['tv'] != 'content') {
              TvNavigationHandoff.request(context, (snapshot?.selectedSourceId, target));
            }
            unawaited(controller.selectTvTab(target));
            if (uri.path != '/discover' || uri.queryParameters['tv'] != 'content') widget.router.go('/discover?tv=content');
          },
          child: widget.child,
        );
      },
    );
  }
}
