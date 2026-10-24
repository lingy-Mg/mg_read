/// 发现页内部导航与内容加载控制器。
///
/// 职责：
/// - 维护不可变文档栈、请求世代和逐级返回。
/// - 为一次文档加载记录唯一诊断终态，并丢弃过期结果。
///
/// 注意：
/// - 返回或新请求必须先让旧请求失效，不能让旧结果重开子页。
/// - target 是数据源不透明标识；诊断记录插件 ID 与公开 capability。
///
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

/// Keeps the first resolved discovery document for the lifetime of the app and
/// owns cancellation of in-flight category navigation.
///
/// Top-level destination navigation removes the discovery widget from the
/// tree. This controller must therefore outlive that widget so returning to
/// discovery restores its loaded document instead of issuing a new request.
/// Explicit refreshes and source changes still replace the cached document.
final discoveryPageControllerProvider = NotifierProvider<DiscoveryPageController, DiscoveryPageState>(DiscoveryPageController.new);

class DiscoveryPageController extends Notifier<DiscoveryPageState> {
  late SourceContentGateway _gateway;
  late DiscoverySourceSelectionStore _sourceSelectionStore;
  late DiagnosticsManager _diagnostics;
  final List<_DiscoveryNavigationEntry> _stack = <_DiscoveryNavigationEntry>[];
  final LinkedHashMap<_DiscoveryDocumentCacheKey, PluginDiscoveryDocumentResult> _documentCache =
      LinkedHashMap<_DiscoveryDocumentCacheKey, PluginDiscoveryDocumentResult>();
  int _latestGeneration = 0;
  int? _pendingCategoryGeneration;
  bool _disposed = false;
  _ActiveDiscoveryLoad? _activeLoad;
  PluginInvocationCancellation? _requestCancellation;

  @override
  DiscoveryPageState build() {
    _gateway = ref.watch(sourceContentGatewayProvider);
    _sourceSelectionStore = ref.watch(discoverySourceSelectionStoreProvider);
    _diagnostics = ref.watch(diagnosticsManagerProvider);
    ref.listen(pluginRuntimeCatalogChangeProvider, (_, next) {
      unawaited(_applyCatalogChange(next));
    });
    ref.onDispose(() {
      _disposed = true;
      _cancelActiveRequest();
      _endActiveLoad(DiagnosticOutcome.cancelled);
    });
    final generation = ++_latestGeneration;
    scheduleMicrotask(() => unawaited(_initialize(generation)));
    return DiscoveryPageState.loadingSources();
  }

  Future<void> _applyCatalogChange(PluginRuntimeCatalogChange change) async {
    final selected = state.selectedSourceId;
    final affectsSelected = selected != null && change.affects(selected);
    final generation = affectsSelected ? ++_latestGeneration : null;
    if (affectsSelected) {
      _invalidateSourceCache(selected);
      _cancelActiveRequest();
      _endActiveLoad(DiagnosticOutcome.cancelled);
    }
    try {
      // Let providers that watch the same revision dispose their stale future
      // before reading the refreshed catalog. Riverpod does not define sibling
      // listener ordering for one state change.
      await Future<void>.value();
      final sources = await ref.read(availablePluginSourcesProvider.future);
      if (_disposed || (generation != null && !_isCurrent(generation))) return;
      if (sources.isEmpty) {
        ++_latestGeneration;
        _stack.clear();
        state = DiscoveryPageState.noSources();
        return;
      }
      if (selected == null || !sources.any((source) => source.id == selected)) {
        final saved = await _loadSavedSourceId();
        if (_disposed || (generation != null && !_isCurrent(generation))) return;
        final fallback = sources.any((source) => source.id == saved) ? saved! : sources.first.id;
        await _saveSelectedSource(fallback);
        _stack.clear();
        await _loadDocument(pluginId: fallback, target: null, sources: sources, resetStack: true);
        return;
      }
      if (affectsSelected) {
        _stack.clear();
        await _loadDocument(pluginId: selected, target: null, sources: sources, resetStack: true);
        return;
      }
      state = state.withSources(sources);
    } on Object {
      // The retained document remains usable. Runtime diagnostics and the
      // normal source provider surface a later explicit retry failure.
    }
  }

  Future<void> retry() {
    if (state.sources.isEmpty) {
      ref.invalidate(availablePluginSourcesProvider);
      return _initialize(++_latestGeneration);
    }
    final selected = state.selectedSourceId ?? state.sources.first.id;
    return _loadDocument(
      pluginId: selected,
      target: state.target ?? _stack.lastOrNull?.target,
      push: state.canNavigateBack && state.result == null,
    );
  }

  Future<void> refresh() {
    final entry = _stack.lastOrNull;
    final pluginId = state.selectedSourceId;
    if (entry == null || pluginId == null) return retry();
    return _loadDocument(pluginId: pluginId, target: entry.target, replaceCurrent: true);
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
    return _loadDocument(pluginId: pluginId, target: target, replaceCurrent: true);
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
      _cancelActiveRequest();
      _endActiveLoad(DiagnosticOutcome.cancelled);
      _pendingCategoryGeneration = null;
      _publish(_stack.last.document);
      return;
    }
    if (_stack.length < 2) {
      if (_stack.isNotEmpty && state.canNavigateBack) {
        // A failed pushed request is not committed to _stack. Its local route
        // still needs to reveal the retained parent when the user goes back.
        _publish(_stack.last.document);
      }
      return;
    }
    // A pending category request must not repopulate a page after the user
    // has already returned to its parent document.
    ++_latestGeneration;
    _cancelActiveRequest();
    _endActiveLoad(DiagnosticOutcome.cancelled);
    _stack.removeLast();
    _publish(_stack.last.document);
  }

  Future<void> loadMore(PluginDiscoveryContentCollectionComponent collection) async {
    final continuation = collection.continuation;
    final pluginId = state.selectedSourceId;
    final entry = _stack.lastOrNull;
    if (continuation == null || pluginId == null || entry == null) return;
    final generation = ++_latestGeneration;
    final cancellation = _replaceRequestCancellation();
    _endActiveLoad(DiagnosticOutcome.cancelled);
    _publish(entry.document, loadingCollectionId: collection.id);
    try {
      final result = await runCancellableSourceRequest(
        _gateway,
        cancellation,
        () => _gateway.discover(pluginId: pluginId, target: continuation.target, cursor: continuation.cursor, collectionId: collection.id),
      );
      if (!_isCurrent(generation) || result is! PluginDiscoveryAppendResult) {
        return;
      }
      if (result.collectionId != collection.id) {
        throw StateError('Source appended a different discovery collection.');
      }
      final updated = _appendCollection(entry.document, result);
      _stack[_stack.length - 1] = entry.copyWith(document: updated);
      _cacheDocument(pluginId, entry.target, updated);
      _publish(updated);
    } on Object catch (_) {
      if (!_isCurrent(generation)) {
        return;
      }
      _publish(entry.document);
    } finally {
      _clearRequestCancellation(cancellation);
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
      final selectedSourceId = sources.any((source) => source.id == savedSourceId) ? savedSourceId! : sources.first.id;
      await _loadDocument(pluginId: selectedSourceId, target: null, sources: sources, generation: generation, resetStack: true);
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      state = DiscoveryPageState.failure(
        sources: const <PluginSourceDescriptor>[],
        selectedSourceId: null,
        error: AppError.fromUnknown(error),
        canNavigateBack: false,
        navigationDepth: 0,
        target: null,
        previousResult: null,
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
    final cancellation = _replaceRequestCancellation();
    _endActiveLoad(DiagnosticOutcome.cancelled);
    final availableSources = sources ?? state.sources;
    final parent = _stack.lastOrNull;
    final cachedDocument = _readCachedDocument(pluginId, target);
    final hasCachedDocument = cachedDocument != null;
    final navigationDepth = resetStack || _stack.isEmpty
        ? 0
        : push
        ? _stack.length
        : _stack.length - 1;
    final definition = _diagnostics.registry.requireDefinition(AppDiagnosticEvents.discoveryNavigation);
    final span = _diagnostics.startSpan(
      definition,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'operation': DiagnosticValue.string(
          push
              ? 'push'
              : replaceCurrent
              ? 'replace'
              : 'load',
        ),
        if (definition.fields.containsKey('capability')) 'capability': DiagnosticValue.string('source.discover.v1'),
        if (definition.fields.containsKey('pluginId')) 'pluginId': DiagnosticValue.string(pluginId),
        'requestGeneration': DiagnosticValue.int64(requestGeneration),
        'navigationDepth': DiagnosticValue.int64(navigationDepth),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    final load = _ActiveDiscoveryLoad(
      span: span,
      pluginId: pluginId,
      capability: 'source.discover.v1',
      requestGeneration: requestGeneration,
      navigationDepth: navigationDepth,
    );
    _activeLoad = load;
    _pendingCategoryGeneration = push && !hasCachedDocument ? requestGeneration : null;
    if (cachedDocument != null) {
      _commitDocument(target: target, document: cachedDocument, push: push, replaceCurrent: replaceCurrent, resetStack: resetStack);
      _publish(cachedDocument, sources: availableSources, selectedSourceId: pluginId);
    } else {
      state = DiscoveryPageState.loadingContent(
        sources: availableSources,
        selectedSourceId: pluginId,
        canNavigateBack: _stack.length > 1 || push,
        navigationDepth: navigationDepth,
        target: target,
        previousResult: push ? parent?.document : null,
        retainedParents: _stack.map((entry) => entry.document),
      );
    }
    try {
      final result = await runCancellableSourceRequest(_gateway, cancellation, () => _gateway.discover(pluginId: pluginId, target: target));
      if (!_isCurrent(requestGeneration) || result is! PluginDiscoveryDocumentResult) {
        _clearPendingCategory(requestGeneration);
        _endLoad(load, DiagnosticOutcome.cancelled);
        return;
      }
      _clearPendingCategory(requestGeneration);
      _commitDocument(
        target: target,
        document: result,
        push: push && !hasCachedDocument,
        replaceCurrent: replaceCurrent || hasCachedDocument,
        resetStack: resetStack && !hasCachedDocument,
      );
      _cacheDocument(pluginId, target, result);
      _publish(result, sources: availableSources, selectedSourceId: pluginId);
      _endLoad(load, DiagnosticOutcome.success, itemCount: _documentItemCount(result.document));
    } on Object catch (error, stackTrace) {
      if (!_isCurrent(requestGeneration)) {
        _endLoad(load, DiagnosticOutcome.cancelled);
        return;
      }
      _clearPendingCategory(requestGeneration);
      final appError = AppError.fromUnknown(error);
      final current = _stack.lastOrNull;
      if ((hasCachedDocument || !push) && current != null && state.selectedSourceId == pluginId) {
        _publish(current.document);
        _endLoad(load, _outcomeFor(appError), error: appError, stackTrace: stackTrace);
        return;
      }
      state = DiscoveryPageState.failure(
        sources: availableSources,
        selectedSourceId: pluginId,
        error: appError,
        canNavigateBack: _stack.length > 1 || push,
        navigationDepth: navigationDepth,
        target: target,
        previousResult: push ? parent?.document : null,
        retainedParents: _stack.map((entry) => entry.document),
      );
      _endLoad(load, _outcomeFor(appError), error: appError, stackTrace: stackTrace);
    } finally {
      _clearRequestCancellation(cancellation);
    }
  }

  void _commitDocument({
    required String? target,
    required PluginDiscoveryDocumentResult document,
    required bool push,
    required bool replaceCurrent,
    required bool resetStack,
  }) {
    final entry = _DiscoveryNavigationEntry(target: target, document: document);
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
  }

  PluginDiscoveryDocumentResult? _readCachedDocument(String pluginId, String? target) {
    final key = _DiscoveryDocumentCacheKey(pluginId, target);
    final cached = _documentCache.remove(key);
    if (cached != null) _documentCache[key] = cached;
    return cached;
  }

  void _cacheDocument(String pluginId, String? target, PluginDiscoveryDocumentResult document) {
    final key = _DiscoveryDocumentCacheKey(pluginId, target);
    _documentCache.remove(key);
    _documentCache[key] = document;
    while (_documentCache.length > 8) {
      _documentCache.remove(_documentCache.keys.first);
    }
  }

  void _invalidateSourceCache(String pluginId) {
    _documentCache.removeWhere((key, _) => key.pluginId == pluginId);
  }

  PluginInvocationCancellation _replaceRequestCancellation() {
    _cancelActiveRequest();
    return _requestCancellation = PluginInvocationCancellation();
  }

  void _cancelActiveRequest() {
    _requestCancellation?.cancel();
    _requestCancellation = null;
  }

  void _clearRequestCancellation(PluginInvocationCancellation cancellation) {
    if (identical(_requestCancellation, cancellation)) _requestCancellation = null;
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
      navigationDepth: _stack.length - 1,
      target: _stack.lastOrNull?.target,
      retainedParents: _stack.take(_stack.length - 1).map((entry) => entry.document),
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _latestGeneration;

  void _clearPendingCategory(int generation) {
    if (_pendingCategoryGeneration == generation) {
      _pendingCategoryGeneration = null;
    }
  }

  void _endActiveLoad(DiagnosticOutcome outcome) {
    final load = _activeLoad;
    _activeLoad = null;
    if (load != null && !load.span.isEnded) _endLoad(load, outcome);
  }

  void _endLoad(_ActiveDiscoveryLoad load, DiagnosticOutcome outcome, {int? itemCount, AppError? error, StackTrace? stackTrace}) {
    if (identical(_activeLoad, load)) _activeLoad = null;
    if (load.span.isEnded) return;
    final fields = load.span.definition.fields;
    final attributes = DiagnosticObjectValue(<String, DiagnosticValue>{
      'operation': DiagnosticValue.string('document'),
      if (fields.containsKey('capability')) 'capability': DiagnosticValue.string(load.capability),
      if (fields.containsKey('pluginId')) 'pluginId': DiagnosticValue.string(load.pluginId),
      'requestGeneration': DiagnosticValue.int64(load.requestGeneration),
      'navigationDepth': DiagnosticValue.int64(load.navigationDepth),
      'resultState': DiagnosticValue.string(_diagnosticResultState(outcome)),
      if (itemCount != null) 'itemCount': DiagnosticValue.int64(itemCount),
      if (error != null) 'errorCode': DiagnosticValue.string(error.code.wireValue),
      if (error?.location != null && fields.containsKey('errorLocation')) 'errorLocation': DiagnosticValue.string(error!.location!),
      if (error?.detail != null && fields.containsKey('errorText')) 'errorText': DiagnosticValue.string(error!.detail!),
      if (stackTrace != null && fields.containsKey('stackTrace')) 'stackTrace': DiagnosticValue.string(stackTrace.toString()),
    });
    try {
      load.span.end(outcome, attributes: attributes);
    } on Object {
      // Diagnostics are best effort. A stale hot-reload schema must not escape
      // this controller and replace the source error already stored in state.
    }
  }
}

String _diagnosticResultState(DiagnosticOutcome outcome) => switch (outcome) {
  DiagnosticOutcome.success => 'content',
  DiagnosticOutcome.error => 'failure',
  DiagnosticOutcome.cancelled => 'cancelled',
  DiagnosticOutcome.timeout => 'timeout',
  DiagnosticOutcome.overloaded => 'overloaded',
  DiagnosticOutcome.incomplete => 'incomplete',
};

DiagnosticOutcome _outcomeFor(AppError error) => switch (error.code) {
  AppErrorCode.cancelled => DiagnosticOutcome.cancelled,
  AppErrorCode.timeout => DiagnosticOutcome.timeout,
  AppErrorCode.overloaded => DiagnosticOutcome.overloaded,
  _ => DiagnosticOutcome.error,
};

final class _ActiveDiscoveryLoad {
  const _ActiveDiscoveryLoad({
    required this.span,
    required this.pluginId,
    required this.capability,
    required this.requestGeneration,
    required this.navigationDepth,
  });

  final DiagnosticSpanHandle span;
  final String pluginId;
  final String capability;
  final int requestGeneration;
  final int navigationDepth;
}

final class _DiscoveryNavigationEntry {
  const _DiscoveryNavigationEntry({required this.target, required this.document});

  final String? target;
  final PluginDiscoveryDocumentResult document;

  _DiscoveryNavigationEntry copyWith({required PluginDiscoveryDocumentResult document}) =>
      _DiscoveryNavigationEntry(target: target, document: document);
}

final class _DiscoveryDocumentCacheKey {
  const _DiscoveryDocumentCacheKey(this.pluginId, this.target);

  final String pluginId;
  final String? target;

  @override
  bool operator ==(Object other) => other is _DiscoveryDocumentCacheKey && other.pluginId == pluginId && other.target == target;

  @override
  int get hashCode => Object.hash(pluginId, target);
}

extension on List<_DiscoveryNavigationEntry> {
  _DiscoveryNavigationEntry? get lastOrNull => isEmpty ? null : last;
}

int _documentItemCount(PluginDiscoveryDocument document) =>
    document.components.fold<int>(0, (count, component) => count + _componentItemCount(component));

int _componentItemCount(PluginDiscoveryComponent component) => switch (component) {
  PluginDiscoveryContentCollectionComponent(:final items) => items.length,
  PluginDiscoveryCategoryCollectionComponent(:final categories) => categories.length,
  PluginDiscoverySectionComponent(:final children) ||
  PluginDiscoveryGroupComponent(:final children) => children.fold<int>(0, (count, child) => count + _componentItemCount(child)),
  _ => 0,
};

PluginDiscoveryDocumentResult _appendCollection(PluginDiscoveryDocumentResult result, PluginDiscoveryAppendResult append) =>
    PluginDiscoveryDocumentResult(
      pluginId: result.pluginId,
      sourceName: result.sourceName,
      document: PluginDiscoveryDocument(
        components: result.document.components.map((component) => _replaceComponent(component, append)).toList(growable: false),
      ),
    );

PluginDiscoveryComponent _replaceComponent(PluginDiscoveryComponent component, PluginDiscoveryAppendResult append) => switch (component) {
  PluginDiscoveryContentCollectionComponent() when component.id == append.collectionId => PluginDiscoveryContentCollectionComponent(
    id: component.id,
    layout: component.layout,
    items: <PluginDiscoveryContentItem>[...component.items, ...append.items],
    continuation: append.continuation,
  ),
  PluginDiscoverySectionComponent() => PluginDiscoverySectionComponent(
    id: component.id,
    title: component.title,
    subtitle: component.subtitle,
    children: component.children.map((child) => _replaceComponent(child, append)).toList(growable: false),
  ),
  PluginDiscoveryGroupComponent() => PluginDiscoveryGroupComponent(
    id: component.id,
    layout: component.layout,
    children: component.children.map((child) => _replaceComponent(child, append)).toList(growable: false),
  ),
  _ => component,
};
