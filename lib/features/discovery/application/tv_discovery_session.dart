/// One selected source's TV tabs and first-page cache, with no persistent IO.
/// Root navigation is promoted from validated source tabs/categories; opaque
/// targets are never parsed. Four speculative loads run, with a fifth slot
/// reserved for selection so slow background requests cannot block navigation.
/// Filter warming covers one hop across groups fairly, including nested filters;
/// it never recursively expands speculative combinations or exceeds the budget.
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
  TvDiscoveryNavigation(this.home, {List<TvDiscoveryTab>? retainedTabs}) {
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
    tabs = retainedTabs ?? List.unmodifiable(entries);
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
  TvDiscoveryNavigation navigation;
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

  /// Revalidating unchanged tabs must retain category caches and in-flight loads.
  void updateHome(PluginDiscoveryDocumentResult home) {
    if (_disposed) return;
    navigation = TvDiscoveryNavigation(home, retainedTabs: navigation.tabs);
  }

  void prefetch() {
    prefetchTargets(navigation.tabs.map((tab) => tab.target).whereType<String>());
  }

  void prefetchTargets(Iterable<String> targets) {
    for (final target in targets) {
      if (_cache.containsKey(target) || _requests.containsKey(target)) continue;
      if (_requests.length >= 64) break;
      unawaited(load(target, foreground: false).then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    }
  }

  void prefetchFilters(PluginDiscoveryDocumentResult document) {
    final groups = <PluginDiscoveryFilterGroup>[];
    void collect(List<PluginDiscoveryComponent> components) {
      for (final component in components) {
        switch (component) {
          case PluginDiscoveryFiltersComponent():
            groups.addAll(component.groups);
          case PluginDiscoverySectionComponent(:final children) || PluginDiscoveryGroupComponent(:final children):
            collect(children);
          default:
            break;
        }
      }
    }

    collect(document.document.components);
    // Interleave groups so a long genre row cannot delay region/year/order.
    final targets = <String>{};
    for (var index = 0; targets.length < 32; index++) {
      var found = false;
      for (final group in groups) {
        if (index >= group.options.length) continue;
        found = true;
        targets.add(group.options[index].target);
        if (targets.length == 32) break;
      }
      if (!found) break;
    }
    prefetchTargets(targets);
  }

  Future<PluginDiscoveryDocumentResult> load(String target, {bool foreground = true, bool refresh = false}) {
    if (_disposed) return Future.error(StateError('TV discovery session closed.'));
    final cached = _cache[target];
    if (!refresh && cached != null) return Future.value(cached);
    final existing = _requests[target];
    if (existing != null) {
      if (foreground) {
        existing.foreground = true;
        if (_queue.remove(existing)) _queue.insert(0, existing);
        _pump();
      }
      return existing.completer.future;
    }
    final request = _TabRequest(target, foreground: foreground);
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
    while (!_disposed && _queue.isNotEmpty && _running < (_queue.first.foreground ? 5 : 4)) {
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
      if (contains(request.target)) prefetchFilters(result);
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
  _TabRequest(this.target, {required this.foreground});
  final String target;
  bool foreground;
  final completer = Completer<PluginDiscoveryDocumentResult>();
  final cancellation = PluginInvocationCancellation();
}
