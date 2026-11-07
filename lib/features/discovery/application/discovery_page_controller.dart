/// 发现页内部导航与内容加载控制器。
///
/// 职责：
/// - 维护不可变文档栈、请求世代和逐级返回。
/// - 为一次文档加载记录唯一诊断终态，并丢弃过期结果。
/// - 目录刷新失败必须结束被更新取消的加载状态，允许用户重试。
/// - 分页串行并核对当前游标，重复或过期的列表请求不得取消在途请求。
///
/// 注意：
/// - 返回或新请求必须先让旧请求失效，不能让旧结果重开子页。
/// - target 是数据源不透明标识；诊断记录插件 ID 与公开 capability。
/// - TV 平铺根分类，session 提前准备分类与各组筛选的一跳结果，限并发并在来源变化时取消。
/// - TV 导航校验独立于前台内容请求；缓存选择优先，后台首页不得覆盖用户内容。
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
import 'tv_discovery_session.dart';
import 'tv_discovery_navigation_snapshot.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

part 'discovery_tv_startup.dart';

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
  String? _catalogReloadSourceId;
  int _catalogGeneration = 0;
  int? _pendingCategoryGeneration;
  bool _disposed = false;
  _ActiveDiscoveryLoad? _activeLoad;
  PluginInvocationCancellation? _requestCancellation;
  bool _readyForTv = false;
  bool _tvMode = false;
  TvDiscoverySession? _tvSession;
  List<_DiscoveryNavigationEntry>? _mobileStack;
  String? _tvPrimaryTarget;
  final _tvTabTargets = <String?, String?>{};
  final _tvStartup = _TvDiscoveryStartup();

  TvDiscoveryNavigation? get tvNavigation => _tvMode ? _tvSession?.navigation : null;
  String? get tvPrimaryTarget => _tvPrimaryTarget;
  TvDiscoveryNavigationSnapshot? get tvNavigationSnapshot => _tvMode ? _tvStartup.snapshot : null;
  int get tvNavigationNotice => _tvStartup.notice;
  DiscoveryPageState get _startupState => state;
  void _setStartupState(DiscoveryPageState value) => state = value;

  /// Supplied by the app bridge before initialization, without starting Runtime.
  void restoreTvNavigation(TvDiscoveryNavigationSnapshot? snapshot) => _tvStartup.snapshot = snapshot;

  /// Leaving source content cancels its pending intent without stopping warming.
  void cancelPendingTvSelection() {
    if (_tvStartup.pending != null && state.result == null) _tvPrimaryTarget = null;
    _tvStartup.pending = null;
    if (state.status != DiscoveryPageStatus.loadingContent || _activeLoad == null) return;
    ++_latestGeneration;
    _cancelActiveRequest();
    _endActiveLoad(DiagnosticOutcome.cancelled);
  }

  @override
  DiscoveryPageState build() {
    _readyForTv = true;
    _gateway = ref.read(sourceContentGatewayProvider);
    _sourceSelectionStore = ref.watch(discoverySourceSelectionStoreProvider);
    _diagnostics = ref.watch(diagnosticsManagerProvider);
    ref.listen(pluginRuntimeCatalogChangeProvider, (_, next) {
      unawaited(_applyCatalogChange(next));
    });
    ref.onDispose(() {
      _disposed = true;
      _stopTvHome();
      _tvSession?.dispose();
      _cancelActiveRequest();
      _endActiveLoad(DiagnosticOutcome.cancelled);
    });
    final generation = ++_latestGeneration;
    scheduleMicrotask(() => unawaited(_initialize(generation)));
    return DiscoveryPageState.loadingSources();
  }

  Future<void> _applyCatalogChange(PluginRuntimeCatalogChange change) async {
    final stateBeforeCatalog = state;
    final catalogGeneration = ++_catalogGeneration;
    final selected = state.selectedSourceId ?? (_tvMode ? _tvStartup.snapshot?.sourceId : null);
    final affectsSelected = selected != null && (change.affects(selected) || _catalogReloadSourceId == selected);
    final generation = affectsSelected ? ++_latestGeneration : _latestGeneration;
    if (affectsSelected) {
      _stopTvHome(clearPending: false);
      _tvSession?.dispose();
      _tvSession = null;
      _mobileStack = null;
      if (!_tvMode) {
        _tvTabTargets.clear();
        _tvPrimaryTarget = null;
      }
      _catalogReloadSourceId = selected;
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
      if (!_isCurrent(generation) || catalogGeneration != _catalogGeneration) return;
      _gateway = ref.read(sourceContentGatewayProvider);
      if (sources.isEmpty) {
        _stopTvHome(clearSnapshot: true);
        _catalogReloadSourceId = null;
        ++_latestGeneration;
        _stack.clear();
        state = DiscoveryPageState.noSources();
        return;
      }
      if (selected == null || !sources.any((source) => source.id == selected)) {
        final saved = await _loadSavedSourceId();
        if (!_isCurrent(generation) || catalogGeneration != _catalogGeneration) return;
        final fallback = sources.any((source) => source.id == saved) ? saved! : sources.first.id;
        await _saveSelectedSource(fallback);
        if (!_isCurrent(generation) || catalogGeneration != _catalogGeneration) return;
        _stack.clear();
        if (_tvMode) _stopTvHome(clearSnapshot: true);
        _catalogReloadSourceId = null;
        await _loadSourceHome(fallback, sources);
        return;
      }
      if (affectsSelected) {
        _catalogReloadSourceId = null;
        if (!_tvMode) _stack.clear();
        await _loadSourceHome(selected, sources);
        return;
      }
      state = state.withSources(sources);
    } on Object catch (error) {
      if (_disposed ||
          (!_tvMode && !identical(state, stateBeforeCatalog)) ||
          ref.read(pluginRuntimeCatalogChangeProvider).revision != change.revision) {
        return;
      }
      if (!affectsSelected && selected != null) return;
      _pendingCategoryGeneration = null;
      _catalogReloadSourceId = null;
      state = DiscoveryPageState.failure(
        sources: state.sources,
        selectedSourceId: selected,
        error: AppError.fromUnknown(error),
        canNavigateBack: state.canNavigateBack,
        navigationDepth: state.navigationDepth,
        target: state.target,
        previousResult: state.result ?? state.previousResult,
        retainedParents: state.retainedParents,
      );
    }
  }

  Future<void> retry() {
    if (state.error != null) ref.invalidate(pluginRuntimeConnectionProvider);
    if (state.sources.isEmpty) {
      ref.invalidate(pluginRuntimeConnectionProvider);
      ref.invalidate(availablePluginSourcesProvider);
      return _initialize(++_latestGeneration);
    }
    final selected = state.selectedSourceId ?? state.sources.first.id;
    if (_tvMode && _tvSession == null) return _loadTvHome(selected, state.sources);
    return _loadDocument(
      pluginId: selected,
      target: state.target ?? _stack.lastOrNull?.target,
      push: state.canNavigateBack && state.result == null,
    );
  }

  Future<void> refresh() {
    final entry = _stack.lastOrNull;
    final pluginId = state.selectedSourceId;
    if (_tvMode && pluginId != null && state.target == null) return _loadTvHome(pluginId, state.sources);
    if (_tvMode && state.status == DiscoveryPageStatus.failure && state.target != entry?.target) return retry();
    if (entry == null || pluginId == null) return retry();
    return _loadDocument(pluginId: pluginId, target: entry.target, replaceCurrent: true);
  }

  Future<void> selectSource(String pluginId) async {
    if (!state.sources.any((source) => source.id == pluginId)) return;
    _stopTvHome(clearSnapshot: true);
    _tvSession?.dispose();
    _tvSession = null;
    _mobileStack = null;
    _tvTabTargets.clear();
    _tvPrimaryTarget = null;
    final generation = ++_latestGeneration;
    _cancelActiveRequest();
    await _saveSelectedSource(pluginId);
    if (!_isCurrent(generation)) return;
    _stack.clear();
    await _loadSourceHome(pluginId, state.sources);
  }

  Future<void> selectTab(String target) {
    final pluginId = state.selectedSourceId;
    if (pluginId == null) return Future<void>.value();
    return _loadDocument(pluginId: pluginId, target: target, replaceCurrent: true);
  }

  /// Called by the destination lifecycle, never during widget build.
  void configureTvMode(bool enabled) {
    if (!_readyForTv || _disposed || _tvMode == enabled) return;
    _tvMode = enabled;
    if (!enabled) {
      _stopTvHome(clearSnapshot: true);
      final home = _tvSession?.navigation.home;
      if (_tvSession != null || _mobileStack?.isNotEmpty == true) {
        ++_latestGeneration;
        _cancelActiveRequest();
        _endActiveLoad(DiagnosticOutcome.cancelled);
        _pendingCategoryGeneration = null;
      }
      _tvSession?.dispose();
      _tvSession = null;
      _tvTabTargets.clear();
      _tvPrimaryTarget = null;
      final mobile = _mobileStack;
      _mobileStack = null;
      if (mobile != null && mobile.isNotEmpty && mobile.last.document.pluginId == state.selectedSourceId) {
        _stack
          ..clear()
          ..addAll(mobile);
        _publish(_stack.last.document);
        return;
      } else if (home != null) {
        _commitDocument(target: null, document: home, push: false, replaceCurrent: false, resetStack: true);
        _publish(home);
        return;
      } else if (state.selectedSourceId case final pluginId?) {
        unawaited(_loadDocument(pluginId: pluginId, target: null, resetStack: true));
        return;
      }
    } else {
      _mobileStack = List.of(_stack);
      final pluginId = state.selectedSourceId;
      final root = _stack.firstOrNull;
      final home = root != null && root.target == null && root.document.pluginId == pluginId
          ? root.document
          : pluginId == null
          ? null
          : _readCachedDocument(pluginId, null);
      if (home == null && pluginId != null) {
        ++_latestGeneration;
        _cancelActiveRequest();
        _endActiveLoad(DiagnosticOutcome.cancelled);
        unawaited(_loadTvHome(pluginId, state.sources));
        return;
      }
      if (home != null) _prepareTvHome(home);
      if (home != null && (state.navigationDepth > 0 || !_tvSession!.contains(state.target))) {
        unawaited(selectTvTab(null));
        return;
      }
    }
    state = state.withSources(state.sources);
  }

  Future<void> selectTvTab(String? primaryTarget) {
    final session = _tvSession;
    final pluginId = state.selectedSourceId;
    if (session == null || _tvStartup.loading) {
      final snapshot = _tvStartup.snapshot;
      if (!_tvMode || snapshot == null || !snapshot.contains(primaryTarget)) return Future.value();
      _tvStartup.pending = _TvDiscoverySelection(snapshot.sourceId, primaryTarget);
      _tvPrimaryTarget = primaryTarget;
      if (pluginId == snapshot.sourceId && (state.result == null || state.target != primaryTarget)) {
        if (_activeLoad != null) {
          ++_latestGeneration;
          _cancelActiveRequest();
          _endActiveLoad(DiagnosticOutcome.cancelled);
        }
        state = DiscoveryPageState.loadingContent(
          sources: state.sources,
          selectedSourceId: pluginId!,
          canNavigateBack: false,
          navigationDepth: 0,
          target: primaryTarget,
        );
      } else {
        state = state.withSources(state.sources);
      }
      return Future.value();
    }
    if (pluginId == null || !session.contains(primaryTarget)) return Future.value();
    _tvStartup.pending = null;
    _tvPrimaryTarget = primaryTarget;
    final target = _tvTabTargets[primaryTarget] ?? primaryTarget;
    return _selectTvDocument(pluginId, target);
  }

  Future<void> selectTvFilter(String target) {
    final pluginId = state.selectedSourceId;
    if (!_tvMode || _tvSession == null || pluginId == null) return Future.value();
    _tvTabTargets[_tvPrimaryTarget] = target;
    return _selectTvDocument(pluginId, target);
  }

  Future<void> resetTvFilters() {
    final target = _tvPrimaryTarget;
    if (target == null) return Future.value();
    _tvTabTargets.remove(target);
    return selectTvTab(target);
  }

  Future<void> _selectTvDocument(String pluginId, String? target) {
    if (state.target == target && state.navigationDepth == 0 && state.error == null && state.result != null) return Future.value();
    final cached = _tvSession!.read(target);
    if (cached == null) return _loadDocument(pluginId: pluginId, target: target, resetStack: true);
    ++_latestGeneration;
    _cancelActiveRequest();
    _endActiveLoad(DiagnosticOutcome.cancelled);
    _pendingCategoryGeneration = null;
    _commitDocument(target: target, document: cached, push: false, replaceCurrent: false, resetStack: true);
    _publish(cached);
    return Future.value();
  }

  void _prepareTvHome(PluginDiscoveryDocumentResult home) {
    final source = state.sources.where((source) => source.id == home.pluginId).firstOrNull;
    if (source != null) {
      final next = TvDiscoveryNavigationSnapshot(
        sourceId: home.pluginId,
        pluginVersion: source.pluginVersion,
        tabs: TvDiscoveryNavigation(home).tabs,
      );
      final previous = _tvStartup.snapshot;
      if (previous == null || previous.pluginVersion != next.pluginVersion || !previous.sameNavigation(next)) _tvStartup.snapshot = next;
    }
    if (identical(_tvSession?.navigation.home, home)) return;
    final existing = _tvSession;
    if (existing != null &&
        existing.navigation.home.pluginId == home.pluginId &&
        TvDiscoveryNavigationSnapshot.sameTabs(existing.navigation.tabs, TvDiscoveryNavigation(home).tabs)) {
      existing.updateHome(home);
      return;
    }
    _tvSession?.dispose();
    _tvSession = TvDiscoverySession(home: home, gateway: _gateway)..prefetch();
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
    if (state.loadingCollectionId != null || state.status == DiscoveryPageStatus.loadingContent) return;
    final refreshing = _activeLoad;
    if (refreshing != null) {
      final generation = _latestGeneration;
      await refreshing.finished.future;
      if (_isCurrent(generation)) await loadMore(collection);
      return;
    }
    final continuation = collection.continuation;
    final pluginId = state.selectedSourceId;
    final entry = _stack.lastOrNull;
    if (continuation == null || pluginId == null || entry == null) return;
    final current = _findCollection(entry.document.document.components, collection.id)?.continuation;
    if (current?.target != continuation.target || current?.cursor != continuation.cursor) return;
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
      if (!_isCurrent(generation)) return;
      if (result is! PluginDiscoveryAppendResult) throw StateError('Source returned a non-append discovery page.');
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
    if (_tvMode) _stopTvHome(clearPending: false);
    state = DiscoveryPageState.loadingSources();
    try {
      final sources = await ref.read(availablePluginSourcesProvider.future);
      if (!_isCurrent(generation)) return;
      if (sources.isEmpty) {
        _stopTvHome(clearSnapshot: true);
        state = DiscoveryPageState.noSources();
        return;
      }
      final savedSourceId = await _loadSavedSourceId() ?? (_tvMode ? _tvStartup.snapshot?.sourceId : null);
      if (!_isCurrent(generation)) return;
      final selectedSourceId = sources.any((source) => source.id == savedSourceId) ? savedSourceId! : sources.first.id;
      if (_tvMode && savedSourceId != selectedSourceId) {
        await _saveSelectedSource(selectedSourceId);
        if (!_isCurrent(generation)) return;
      }
      if (_tvMode && _tvStartup.snapshot?.sourceId != selectedSourceId) _stopTvHome(clearSnapshot: true);
      await _loadSourceHome(selectedSourceId, sources, generation: generation);
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
      final session = _tvMode ? _tvSession : null;
      final result = session != null && target != null && (session.contains(target) || !push)
          ? await session.load(target, refresh: true)
          : await runCancellableSourceRequest(_gateway, cancellation, () => _gateway.discover(pluginId: pluginId, target: target));
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
      final uncachedTvTab =
          _tvMode && (_tvSession?.contains(target) == true || resetStack) && !hasCachedDocument && current?.target != target;
      if (!uncachedTvTab && (hasCachedDocument || !push) && current != null && state.selectedSourceId == pluginId) {
        _publish(current.document);
        state = state.withRefreshError(appError);
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
    if (_tvSession?.navigation.home.pluginId == pluginId) _tvSession?.update(target, document);
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
    if (_tvMode && _stack.lastOrNull?.target == null) _prepareTvHome(result);
    if (_tvMode) _tvSession?.prefetchFilters(result);
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
    if (!load.finished.isCompleted) load.finished.complete();
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
  _ActiveDiscoveryLoad({
    required this.span,
    required this.pluginId,
    required this.capability,
    required this.requestGeneration,
    required this.navigationDepth,
  });

  final DiagnosticSpanHandle span;
  final finished = Completer<void>();
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

PluginDiscoveryContentCollectionComponent? _findCollection(Iterable<PluginDiscoveryComponent> components, String id) {
  for (final component in components) {
    if (component is PluginDiscoveryContentCollectionComponent && component.id == id) return component;
    final children = switch (component) {
      PluginDiscoverySectionComponent(:final children) || PluginDiscoveryGroupComponent(:final children) => children,
      _ => const <PluginDiscoveryComponent>[],
    };
    final found = children.isEmpty ? null : _findCollection(children, id);
    if (found != null) return found;
  }
  return null;
}

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
