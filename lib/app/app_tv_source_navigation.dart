/// Root TV navigation bridge: restores a small local snapshot before Runtime.
/// Source loading still waits for the first usable library frame. Last-wins
/// selection is handed to discovery without publishing the default homepage.
/// Stable source/target identities retain focus and scrolling on revalidation.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'app_startup.dart';
import '../features/discovery/application/discovery_page_controller.dart';
import '../features/discovery/application/discovery_page_state.dart';
import '../features/discovery/application/tv_discovery_navigation_snapshot.dart';
import '../features/discovery/application/tv_discovery_navigation_store.dart';
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
  int _notice = 0;
  TvDiscoveryNavigationSnapshot? _snapshot;
  List<TvSourceNavigationEntry> _entries = const [];
  ProviderSubscription<DiscoveryPageState>? _subscription;
  ({String sourceId, String? target})? _pending;

  bool get _showContent {
    final uri = widget.router.routeInformationProvider.value.uri;
    return uri.path == '/discover' && uri.queryParameters['tv'] == 'content';
  }

  @override
  void initState() {
    super.initState();
    widget.router.routeInformationProvider.addListener(_routeChanged);
    if (widget.enabled) {
      _replaceSnapshot(ref.read(tvDiscoveryNavigationStoreProvider).load());
      unawaited(_start());
    }
  }

  void _replaceSnapshot(TvDiscoveryNavigationSnapshot? value) {
    if (value == null) {
      _entries = const [];
    } else if (_snapshot == null || !_snapshot!.sameNavigation(value)) {
      _entries = List.unmodifiable([for (final tab in value.tabs) TvSourceNavigationEntry(label: tab.label, target: tab.target)]);
    }
    _snapshot = value;
  }

  Future<void> _start() async {
    final generation = ++_generation;
    await ref.read(appStartupControllerProvider).waitForSuccessfulLibraryTerminalFrame();
    if (!mounted || !widget.enabled || generation != _generation) return;
    final controller = ref.read(discoveryPageControllerProvider.notifier);
    _subscription?.close();
    _subscription = ref.listenManual(discoveryPageControllerProvider, (_, next) => _observe(next));
    controller.restoreTvNavigation(_snapshot);
    controller.configureTvMode(true);
    final pending = _pending;
    _pending = null;
    if (pending != null && pending.sourceId == _snapshot?.sourceId && _showContent) unawaited(controller.selectTvTab(pending.target));
    _observe(ref.read(discoveryPageControllerProvider));
    setState(() => _ready = true);
  }

  void _routeChanged() {
    if (!mounted || _showContent) return;
    _pending = null;
    if (_ready) ref.read(discoveryPageControllerProvider.notifier).cancelPendingTvSelection();
  }

  void _selectTarget(String? target) {
    final controller = _ready ? ref.read(discoveryPageControllerProvider.notifier) : null;
    final state = _ready ? ref.read(discoveryPageControllerProvider) : null;
    final sourceId = state?.selectedSourceId ?? _snapshot?.sourceId;
    if (sourceId == null) return;
    TvNavigationHandoff.request(context, (sourceId, target));
    if (controller == null) {
      setState(() => _pending = (sourceId: sourceId, target: target));
    } else {
      unawaited(controller.selectTvTab(target));
      if (state?.status == DiscoveryPageStatus.failure && controller.tvNavigation == null) unawaited(controller.retry());
    }
    if (!_showContent) widget.router.go('/discover?tv=content');
  }

  void _refresh() => unawaited(ref.read(discoveryPageControllerProvider.notifier).refresh());
  void _retry() => unawaited(ref.read(discoveryPageControllerProvider.notifier).retry());

  void _observe(DiscoveryPageState next) {
    final controller = ref.read(discoveryPageControllerProvider.notifier);
    final cachedId = _snapshot?.sourceId;
    if (next.status == DiscoveryPageStatus.noSources ||
        cachedId != null && next.sources.isNotEmpty && !next.sources.any((source) => source.id == cachedId)) {
      _replaceSnapshot(null);
      unawaited(ref.read(tvDiscoveryNavigationStoreProvider).clear());
    }
    final live = controller.tvNavigationSnapshot;
    if (live != null && next.sources.any((source) => source.id == live.sourceId)) {
      _replaceSnapshot(live);
      unawaited(ref.read(tvDiscoveryNavigationStoreProvider).save(live));
    }
    if (controller.tvNavigationNotice == _notice) return;
    _notice = controller.tvNavigationNotice;
    if (!_showContent) return;
    TvNavigationHandoff.request(context, (live?.sourceId, null));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('分类已更新，已返回数据源首页。')));
    });
  }

  @override
  void didUpdateWidget(AppTvSourceNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routeInformationProvider.removeListener(_routeChanged);
      widget.router.routeInformationProvider.addListener(_routeChanged);
    }
    if (oldWidget.enabled == widget.enabled) return;
    if (widget.enabled) {
      _replaceSnapshot(ref.read(tvDiscoveryNavigationStoreProvider).load());
      unawaited(_start());
    } else {
      ++_generation;
      _subscription?.close();
      _subscription = null;
      _pending = null;
      if (_ready) {
        final controller = ref.read(discoveryPageControllerProvider.notifier);
        scheduleMicrotask(() => controller.configureTvMode(false));
      }
      _ready = false;
    }
  }

  @override
  void dispose() {
    _subscription?.close();
    widget.router.routeInformationProvider.removeListener(_routeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _ready;
    final state = active ? ref.watch(discoveryPageControllerProvider) : null;
    final controller = active ? ref.read(discoveryPageControllerProvider.notifier) : null;
    final sourceId = state?.selectedSourceId ?? _snapshot?.sourceId;
    final entries = widget.enabled && _snapshot?.sourceId == sourceId ? _entries : const <TvSourceNavigationEntry>[];
    return ListenableBuilder(
      listenable: widget.router.routeInformationProvider,
      builder: (context, _) => TvSourceNavigationScope(
        sourceId: sourceId,
        target: _pending?.target ?? controller?.tvPrimaryTarget,
        entries: entries,
        loading:
            widget.enabled &&
            (state == null || state.status == DiscoveryPageStatus.loadingSources || state.status == DiscoveryPageStatus.loadingContent),
        onRetry: state?.error == null ? null : _retry,
        showContent: _showContent,
        onRefresh: controller == null ? null : _refresh,
        onSelected: _selectTarget,
        child: widget.child,
      ),
    );
  }
}
