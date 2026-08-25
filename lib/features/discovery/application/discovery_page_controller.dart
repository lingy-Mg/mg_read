import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

/// Keeps the first resolved discovery document for the lifetime of the app and
/// owns cancellation of in-flight category navigation.
///
/// Top-level destination navigation removes the discovery widget from the
/// tree. This controller must therefore outlive that widget so returning to
/// discovery restores its loaded document instead of issuing a new request.
/// Explicit refreshes and source changes still replace the cached document.
final discoveryPageControllerProvider =
    NotifierProvider<DiscoveryPageController, DiscoveryPageState>(
      DiscoveryPageController.new,
    );

class DiscoveryPageController extends Notifier<DiscoveryPageState> {
  late SourceContentGateway _gateway;
  late DiscoverySourceSelectionStore _sourceSelectionStore;
  final List<_DiscoveryNavigationEntry> _stack = <_DiscoveryNavigationEntry>[];
  int _latestGeneration = 0;
  int? _pendingCategoryGeneration;
  bool _disposed = false;

  @override
  DiscoveryPageState build() {
    _gateway = ref.watch(sourceContentGatewayProvider);
    _sourceSelectionStore = ref.watch(discoverySourceSelectionStoreProvider);
    ref.onDispose(() => _disposed = true);
    final generation = ++_latestGeneration;
    scheduleMicrotask(() => unawaited(_initialize(generation)));
    return DiscoveryPageState.loadingSources();
  }

  Future<void> retry() {
    if (state.sources.isEmpty) {
      ref.invalidate(availablePluginSourcesProvider);
      return _initialize(++_latestGeneration);
    }
    final selected = state.selectedSourceId ?? state.sources.first.id;
    return _loadDocument(pluginId: selected, target: _stack.lastOrNull?.target);
  }

  Future<void> refresh() {
    final entry = _stack.lastOrNull;
    final pluginId = state.selectedSourceId;
    if (entry == null || pluginId == null) return retry();
    return _loadDocument(
      pluginId: pluginId,
      target: entry.target,
      replaceCurrent: true,
    );
  }

  Future<void> selectSource(String pluginId) async {
    if (!state.sources.any((source) => source.id == pluginId)) return;
    await _saveSelectedSource(pluginId);
    _stack.clear();
    await _loadDocument(pluginId: pluginId, target: null, resetStack: true);
  }

  Future<void> selectTab(String target) {
    final pluginId = state.selectedSourceId;
    if (pluginId == null) return Future<void>.value();
    return _loadDocument(
      pluginId: pluginId,
      target: target,
      replaceCurrent: true,
    );
  }

  Future<void> openCategory(String target) {
    final pluginId = state.selectedSourceId;
    if (pluginId == null) return Future<void>.value();
    return _loadDocument(pluginId: pluginId, target: target, push: true);
  }

  void goBack() {
    if (_pendingCategoryGeneration != null && _stack.isNotEmpty) {
      // The pending category has not been committed to the stack yet. Return
      // to the retained parent snapshot and discard its eventual result.
      ++_latestGeneration;
      _pendingCategoryGeneration = null;
      _publish(_stack.last.document);
      return;
    }
    if (_stack.length < 2) return;
    // A pending category request must not repopulate a page after the user
    // has already returned to its parent document.
    ++_latestGeneration;
    _stack.removeLast();
    _publish(_stack.last.document);
  }

  Future<void> loadMore(
    PluginDiscoveryContentCollectionComponent collection,
  ) async {
    final continuation = collection.continuation;
    final pluginId = state.selectedSourceId;
    final entry = _stack.lastOrNull;
    if (continuation == null || pluginId == null || entry == null) return;
    final generation = ++_latestGeneration;
    _publish(entry.document, loadingCollectionId: collection.id);
    try {
      final result = await _gateway.discover(
        pluginId: pluginId,
        target: continuation.target,
        cursor: continuation.cursor,
        collectionId: collection.id,
      );
      if (!_isCurrent(generation) || result is! PluginDiscoveryAppendResult) {
        return;
      }
      if (result.collectionId != collection.id) {
        throw StateError('Source appended a different discovery collection.');
      }
      final updated = _appendCollection(entry.document, result);
      _stack[_stack.length - 1] = entry.copyWith(document: updated);
      _publish(updated);
    } on Object catch (_) {
      if (!_isCurrent(generation)) {
        return;
      }
      _publish(entry.document);
    }
  }

  Future<void> _initialize(int generation) async {
    state = DiscoveryPageState.loadingSources();
    try {
      final sources = await ref.read(availablePluginSourcesProvider.future);
      if (!_isCurrent(generation)) return;
      if (sources.isEmpty) {
        state = DiscoveryPageState.noSources();
        return;
      }
      final savedSourceId = await _loadSavedSourceId();
      if (!_isCurrent(generation)) return;
      final selectedSourceId =
          sources.any((source) => source.id == savedSourceId)
          ? savedSourceId!
          : sources.first.id;
      await _loadDocument(
        pluginId: selectedSourceId,
        target: null,
        sources: sources,
        generation: generation,
        resetStack: true,
      );
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      state = DiscoveryPageState.failure(
        sources: const <PluginSourceDescriptor>[],
        selectedSourceId: null,
        error: AppError.fromUnknown(error),
      );
    }
  }

  Future<String?> _loadSavedSourceId() async {
    try {
      return await _sourceSelectionStore.load();
    } on Object {
      // A settings read failure must not prevent discovery from using a valid
      // source for this session. The settings manager records its own state.
      return null;
    }
  }

  Future<void> _saveSelectedSource(String sourceId) async {
    try {
      await _sourceSelectionStore.save(sourceId);
    } on Object {
      // Keep the user's in-session selection usable if durable persistence is
      // temporarily unavailable. The settings manager retains/retries it.
    }
  }

  Future<void> _loadDocument({
    required String pluginId,
    required String? target,
    List<PluginSourceDescriptor>? sources,
    int? generation,
    bool push = false,
    bool replaceCurrent = false,
    bool resetStack = false,
  }) async {
    final requestGeneration = generation ?? ++_latestGeneration;
    final availableSources = sources ?? state.sources;
    _pendingCategoryGeneration = push ? requestGeneration : null;
    state = DiscoveryPageState.loadingContent(
      sources: availableSources,
      selectedSourceId: pluginId,
      canNavigateBack: _stack.length > 1 || push,
    );
    try {
      final result = await _gateway.discover(
        pluginId: pluginId,
        target: target,
      );
      if (!_isCurrent(requestGeneration) ||
          result is! PluginDiscoveryDocumentResult) {
        _clearPendingCategory(requestGeneration);
        return;
      }
      _clearPendingCategory(requestGeneration);
      final entry = _DiscoveryNavigationEntry(target: target, document: result);
      if (resetStack || _stack.isEmpty) {
        _stack
          ..clear()
          ..add(entry);
      } else if (push) {
        _stack.add(entry);
      } else if (replaceCurrent) {
        _stack[_stack.length - 1] = entry;
      } else {
        _stack
          ..clear()
          ..add(entry);
      }
      _publish(result, sources: availableSources, selectedSourceId: pluginId);
    } on Object catch (error) {
      if (!_isCurrent(requestGeneration)) {
        return;
      }
      _clearPendingCategory(requestGeneration);
      final current = _stack.lastOrNull;
      if (current != null && state.selectedSourceId == pluginId) {
        _publish(current.document);
        return;
      }
      state = DiscoveryPageState.failure(
        sources: availableSources,
        selectedSourceId: pluginId,
        error: AppError.fromUnknown(error),
      );
    }
  }

  void _publish(
    PluginDiscoveryDocumentResult result, {
    List<PluginSourceDescriptor>? sources,
    String? selectedSourceId,
    String? loadingCollectionId,
  }) {
    state = DiscoveryPageState.resolved(
      sources: sources ?? state.sources,
      selectedSourceId: selectedSourceId ?? state.selectedSourceId!,
      result: result,
      isEmpty: _documentItemCount(result.document) == 0,
      canNavigateBack: _stack.length > 1,
      loadingCollectionId: loadingCollectionId,
    );
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _latestGeneration;

  void _clearPendingCategory(int generation) {
    if (_pendingCategoryGeneration == generation) {
      _pendingCategoryGeneration = null;
    }
  }
}

final class _DiscoveryNavigationEntry {
  const _DiscoveryNavigationEntry({
    required this.target,
    required this.document,
  });

  final String? target;
  final PluginDiscoveryDocumentResult document;

  _DiscoveryNavigationEntry copyWith({
    required PluginDiscoveryDocumentResult document,
  }) => _DiscoveryNavigationEntry(target: target, document: document);
}

extension on List<_DiscoveryNavigationEntry> {
  _DiscoveryNavigationEntry? get lastOrNull => isEmpty ? null : last;
}

int _documentItemCount(PluginDiscoveryDocument document) => document.components
    .fold<int>(0, (count, component) => count + _componentItemCount(component));

int _componentItemCount(PluginDiscoveryComponent component) =>
    switch (component) {
      PluginDiscoveryContentCollectionComponent(:final items) => items.length,
      PluginDiscoveryCategoryCollectionComponent(:final categories) =>
        categories.length,
      PluginDiscoverySectionComponent(:final children) ||
      PluginDiscoveryGroupComponent(:final children) => children.fold<int>(
        0,
        (count, child) => count + _componentItemCount(child),
      ),
      _ => 0,
    };

PluginDiscoveryDocumentResult _appendCollection(
  PluginDiscoveryDocumentResult result,
  PluginDiscoveryAppendResult append,
) => PluginDiscoveryDocumentResult(
  pluginId: result.pluginId,
  sourceName: result.sourceName,
  document: PluginDiscoveryDocument(
    components: result.document.components
        .map((component) => _replaceComponent(component, append))
        .toList(growable: false),
  ),
);

PluginDiscoveryComponent _replaceComponent(
  PluginDiscoveryComponent component,
  PluginDiscoveryAppendResult append,
) => switch (component) {
  PluginDiscoveryContentCollectionComponent()
      when component.id == append.collectionId =>
    PluginDiscoveryContentCollectionComponent(
      id: component.id,
      layout: component.layout,
      items: <PluginDiscoveryContentItem>[...component.items, ...append.items],
      continuation: append.continuation,
    ),
  PluginDiscoverySectionComponent() => PluginDiscoverySectionComponent(
    id: component.id,
    title: component.title,
    subtitle: component.subtitle,
    children: component.children
        .map((child) => _replaceComponent(child, append))
        .toList(growable: false),
  ),
  PluginDiscoveryGroupComponent() => PluginDiscoveryGroupComponent(
    id: component.id,
    layout: component.layout,
    children: component.children
        .map((child) => _replaceComponent(child, append))
        .toList(growable: false),
  ),
  _ => component,
};
