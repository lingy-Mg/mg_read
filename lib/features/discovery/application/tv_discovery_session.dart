/// One selected source's TV tabs and first-page cache, with no persistent IO.
/// Root navigation is promoted from validated source tabs/categories; opaque
/// targets are never parsed. At most two loads run, with foreground priority.
/// Selection does not cancel a shared preload. Source changes/disposal cancel
/// every request and prevent late results from repopulating the old session.
library;

import 'dart:async';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'source_content_gateway.dart';

class TvDiscoveryTab {
  const TvDiscoveryTab({required this.label, required this.target});
  final String label;
  final String? target;
}

class TvDiscoveryNavigation {
  TvDiscoveryNavigation(this.home) {
    final targets = <String>{};
    final entries = <TvDiscoveryTab>[TvDiscoveryTab(label: home.sourceName, target: null)];
    void collect(List<PluginDiscoveryComponent> components) {
      for (final component in components) {
        switch (component) {
          case PluginDiscoveryTabsComponent():
            for (final tab in component.tabs) {
              if (targets.add(tab.target)) entries.add(TvDiscoveryTab(label: tab.label, target: tab.target));
            }
          case PluginDiscoveryCategoryCollectionComponent():
            for (final category in component.categories) {
              if (targets.add(category.target)) entries.add(TvDiscoveryTab(label: category.title, target: category.target));
            }
          case PluginDiscoverySectionComponent():
            collect(component.children);
          case PluginDiscoveryGroupComponent():
            collect(component.children);
          default:
            break;
        }
      }
    }

    collect(home.document.components);
    tabs = List.unmodifiable(entries);
  }

  final PluginDiscoveryDocumentResult home;
  late final List<TvDiscoveryTab> tabs;

  /// Retains every homepage content section while removing promoted controls.
  List<PluginDiscoveryComponent> get homeContent => _content(home.document.components);
  List<PluginDiscoveryComponent> contentFor(PluginDiscoveryDocumentResult result) => _content(result.document.components);

  List<PluginDiscoveryComponent> _content(List<PluginDiscoveryComponent> components) => [
    for (final component in components)
      ...switch (component) {
        PluginDiscoveryTabsComponent() =>
          component.tabs.every((tab) => tabs.any((entry) => entry.target == tab.target)) ? <PluginDiscoveryComponent>[] : [component],
        PluginDiscoveryCategoryCollectionComponent() =>
          component.categories.every((category) => tabs.any((entry) => entry.target == category.target))
              ? <PluginDiscoveryComponent>[]
              : [component],
        PluginDiscoverySectionComponent() => [
          if (_content(component.children) case final children when children.isNotEmpty)
            PluginDiscoverySectionComponent(
              id: component.id,
              title: component.title,
              subtitle: component.subtitle,
              icon: component.icon,
              children: children,
            ),
        ],
        PluginDiscoveryGroupComponent() => [
          if (_content(component.children) case final children when children.isNotEmpty)
            PluginDiscoveryGroupComponent(id: component.id, layout: component.layout, children: children),
        ],
        _ => [component],
      },
  ];
}

class TvDiscoverySession {
  TvDiscoverySession({required PluginDiscoveryDocumentResult home, required this.gateway}) : navigation = TvDiscoveryNavigation(home);
  final SourceContentGateway gateway;
  final TvDiscoveryNavigation navigation;
  final _cache = <String, PluginDiscoveryDocumentResult>{};
  final _requests = <String, _TabRequest>{};
  final _queue = <_TabRequest>[];
  int _running = 0;
  bool _disposed = false;

  PluginDiscoveryDocumentResult? read(String? target) {
    if (target == null) return navigation.home;
    final value = _cache.remove(target);
    if (value != null) _cache[target] = value;
    return value;
  }

  bool contains(String? target) => navigation.tabs.any((tab) => tab.target == target);

  void prefetch() {
    prefetchTargets(navigation.tabs.map((tab) => tab.target).whereType<String>());
  }

  void prefetchTargets(Iterable<String> targets) {
    for (final target in targets) {
      unawaited(load(target, foreground: false).then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    }
  }

  Future<PluginDiscoveryDocumentResult> load(String target, {bool foreground = true, bool refresh = false}) {
    if (_disposed) return Future.error(StateError('TV discovery session closed.'));
    final cached = _cache[target];
    if (!refresh && cached != null) return Future.value(cached);
    final existing = _requests[target];
    if (existing != null) {
      if (foreground && _queue.remove(existing)) _queue.insert(0, existing);
      return existing.completer.future;
    }
    final request = _TabRequest(target);
    _requests[target] = request;
    if (foreground) {
      _queue.insert(0, request);
    } else {
      _queue.add(request);
    }
    _pump();
    return request.completer.future;
  }

  void update(String? target, PluginDiscoveryDocumentResult result) {
    if (!_disposed && target != null) _remember(target, result);
  }

  void _remember(String target, PluginDiscoveryDocumentResult result) {
    _cache.remove(target);
    _cache[target] = result;
    while (_cache.length > 64) {
      _cache.remove(_cache.keys.first);
    }
  }

  void _pump() {
    while (!_disposed && _running < 2 && _queue.isNotEmpty) {
      _running++;
      unawaited(_run(_queue.removeAt(0)));
    }
  }

  Future<void> _run(_TabRequest request) async {
    try {
      final result = await runCancellableSourceRequest(
        gateway,
        request.cancellation,
        () => gateway.discover(pluginId: navigation.home.pluginId, target: request.target),
      );
      if (_disposed) throw StateError('TV discovery session closed.');
      if (result is! PluginDiscoveryDocumentResult) throw StateError('Expected a TV discovery document.');
      _remember(request.target, result);
      if (contains(request.target)) {
        for (final filters in result.document.components.whereType<PluginDiscoveryFiltersComponent>()) {
          prefetchTargets(filters.groups.firstOrNull?.options.map((option) => option.target) ?? const []);
        }
      }
      request.completer.complete(result);
    } on Object catch (error, stack) {
      request.completer.completeError(error, stack);
    } finally {
      _requests.remove(request.target);
      _running--;
      _pump();
    }
  }

  void dispose() {
    _disposed = true;
    for (final request in _requests.values) {
      request.cancellation.cancel();
    }
    for (final request in _queue) {
      request.completer.completeError(StateError('TV discovery session closed.'));
    }
    _queue.clear();
    _cache.clear();
  }
}

class _TabRequest {
  _TabRequest(this.target);
  final String target;
  final completer = Completer<PluginDiscoveryDocumentResult>();
  final cancellation = PluginInvocationCancellation();
}
