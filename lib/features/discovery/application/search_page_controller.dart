import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/batch_search.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

final searchPageControllerProvider = NotifierProvider.autoDispose<SearchPageController, SearchPageState>(SearchPageController.new);

/// Owns source selection and search request generations for the search page.
class SearchPageController extends Notifier<SearchPageState> {
  late SourceContentGateway _gateway;
  int _latestGeneration = 0;
  int _latestSuggestionGeneration = 0;
  bool _disposed = false;
  PluginInvocationCancellation? _searchCancellation;
  PluginInvocationCancellation? _suggestionCancellation;

  @override
  SearchPageState build() {
    _gateway = ref.watch(sourceContentGatewayProvider);
    ref.listen(pluginRuntimeCatalogChangeProvider, (_, next) {
      unawaited(_applyCatalogChange(next));
    });
    ref.onDispose(() {
      _disposed = true;
      _cancelSearch();
      _cancelSuggestions();
    });
    final generation = ++_latestGeneration;
    scheduleMicrotask(() => unawaited(_loadSources(generation)));
    return SearchPageState.loadingSources();
  }

  Future<void> _applyCatalogChange(PluginRuntimeCatalogChange change) async {
    final selected = state.selectedSourceId;
    final affectsSelected = selected == null || change.affects(selected);
    if (affectsSelected) {
      ++_latestGeneration;
      _cancelSearch();
      _cancelSuggestions();
    }
    try {
      // Let providers that watch the same revision dispose their stale future
      // before reading the refreshed catalog. Riverpod does not define sibling
      // listener ordering for one state change.
      await Future<void>.value();
      final sources = await ref.read(availablePluginSourcesProvider.future);
      if (_disposed) return;
      if (sources.isEmpty) {
        state = SearchPageState.ready(sources: const <PluginSourceDescriptor>[], selectedSourceId: null);
        return;
      }
      final nextSelected = selected == null
          ? null
          : sources.any((source) => source.id == selected)
          ? selected
          : sources.isEmpty
          ? null
          : sources.first.id;
      if (affectsSelected || nextSelected != selected) {
        final query = nextSelected == selected ? state.query : '';
        state = SearchPageState.ready(sources: sources, selectedSourceId: nextSelected, query: query);
        unawaited(_loadSuggestions(nextSelected, ++_latestSuggestionGeneration));
        return;
      }
      state = state.withSources(sources);
    } on Object {
      // Keep the current search projection until an explicit retry.
    }
  }

  Future<void> retrySources() {
    _cancelSearch();
    ref.invalidate(availablePluginSourcesProvider);
    final generation = ++_latestGeneration;
    return _loadSources(generation);
  }

  Future<void> selectSource(String? pluginId) async {
    if (pluginId != null && !state.sources.any((source) => source.id == pluginId)) return;
    ++_latestGeneration;
    _cancelSearch();
    _cancelSuggestions();
    final query = state.query;
    state = SearchPageState.ready(
      sources: state.sources,
      selectedSourceId: pluginId,
      query: query,
      sortOrder: SearchResultSortOrder.defaultForSourceScope(pluginId),
    );
    state = state.withHotSearches(const <PluginSearchSuggestion>[]);
    unawaited(_loadSuggestions(pluginId, ++_latestSuggestionGeneration));
    if (query.isNotEmpty) await search(query);
  }

  Future<void> clear() async {
    _latestGeneration += 1;
    _cancelSearch();
    state = SearchPageState.ready(
      sources: state.sources,
      selectedSourceId: state.selectedSourceId,
      hotSearches: state.hotSearches,
      sortOrder: state.sortOrder,
    );
  }

  /// Stops the active all-source or selected-source search while preserving
  /// results that have already arrived.
  void cancelSearch() {
    if (state.status != SearchPageStatus.searching && _searchCancellation == null) return;
    _latestGeneration += 1;
    _cancelSearch();
    final result = state.result;
    if (result == null) {
      state = SearchPageState.ready(
        sources: state.sources,
        selectedSourceId: state.selectedSourceId,
        query: state.query,
        hotSearches: state.hotSearches,
        sortOrder: state.sortOrder,
      );
    } else {
      state = state.withResult(nextStatus: SearchPageStatus.loaded, nextResult: result);
    }
  }

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      await clear();
      return;
    }
    final generation = ++_latestGeneration;
    final cancellation = _replaceSearchCancellation();
    final retainedResult = state.result;
    state = SearchPageState.searching(
      sources: state.sources,
      selectedSourceId: state.selectedSourceId,
      query: query,
      retainedResult: retainedResult,
      hotSearches: state.hotSearches,
      sortOrder: state.sortOrder,
    );
    try {
      final sources = state.selectedSourceId == null
          ? state.sources
          : state.sources.where((source) => source.id == state.selectedSourceId).toList(growable: false);
      final result = await BatchSearchCoordinator(_gateway).run(
        query: query,
        sources: sources,
        cancellation: cancellation,
        onUpdate: (next) {
          if (!_isCurrent(generation)) return;
          state = state.withResult(nextStatus: SearchPageStatus.searching, nextResult: next);
        },
      );
      if (!_isCurrent(generation)) return;
      if (result.allFailed) {
        final error = result.failedSources.first.error ?? AppError.fromCode(AppErrorCode.internal);
        state = SearchPageState.failure(
          sources: state.sources,
          selectedSourceId: state.selectedSourceId,
          query: query,
          error: error,
          retainedResult: result,
          hotSearches: state.hotSearches,
          sortOrder: state.sortOrder,
        );
      } else {
        state = SearchPageState.loaded(
          sources: state.sources,
          selectedSourceId: state.selectedSourceId,
          query: query,
          result: result,
          hotSearches: state.hotSearches,
          sortOrder: state.sortOrder,
        );
      }
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      state = SearchPageState.failure(
        sources: state.sources,
        selectedSourceId: state.selectedSourceId,
        query: query,
        error: AppError.fromUnknown(error),
        retainedResult: retainedResult,
        hotSearches: state.hotSearches,
        sortOrder: state.sortOrder,
      );
    } finally {
      if (identical(_searchCancellation, cancellation)) _searchCancellation = null;
    }
  }

  Future<void> _loadSources(int generation) async {
    state = SearchPageState.loadingSources();
    try {
      final sources = await ref.read(availablePluginSourcesProvider.future);
      if (!_isCurrent(generation)) return;
      state = SearchPageState.ready(sources: sources, selectedSourceId: null);
      if (sources.isNotEmpty) unawaited(_loadSuggestions(null, ++_latestSuggestionGeneration));
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      state = SearchPageState.failure(
        sources: const <PluginSourceDescriptor>[],
        selectedSourceId: null,
        query: '',
        error: AppError.fromUnknown(error),
        hotSearches: state.hotSearches,
      );
    }
  }

  bool _isCurrent(int generation) {
    return !_disposed && generation == _latestGeneration;
  }

  Future<void> refreshSuggestions() async {
    final pluginId = state.selectedSourceId;
    final generation = ++_latestSuggestionGeneration;
    await _loadSuggestions(pluginId, generation);
  }

  void setSortOrder(SearchResultSortOrder value) {
    if (state.sortOrder == value) return;
    state = state.withSortOrder(value);
  }

  Future<void> loadMore() async {
    final previous = state.result;
    if (previous == null || !previous.hasMore || state.query.isEmpty) return;
    final generation = ++_latestGeneration;
    final cancellation = _replaceSearchCancellation();
    state = state.withResult(nextStatus: SearchPageStatus.searching, nextResult: previous);
    try {
      final sources = state.selectedSourceId == null
          ? state.sources
          : state.sources.where((source) => source.id == state.selectedSourceId).toList(growable: false);
      final result = await BatchSearchCoordinator(_gateway).run(
        query: state.query,
        sources: sources,
        cancellation: cancellation,
        previous: previous,
        onUpdate: (next) {
          if (_isCurrent(generation)) state = state.withResult(nextStatus: SearchPageStatus.searching, nextResult: next);
        },
      );
      if (_isCurrent(generation)) state = state.withResult(nextStatus: SearchPageStatus.loaded, nextResult: result);
    } finally {
      if (identical(_searchCancellation, cancellation)) _searchCancellation = null;
    }
  }

  Future<void> retryFailedSources() async {
    final previous = state.result;
    if (previous == null || previous.failedSources.isEmpty || state.query.isEmpty) {
      await search(state.query);
      return;
    }
    final generation = ++_latestGeneration;
    final cancellation = _replaceSearchCancellation();
    state = state.withResult(nextStatus: SearchPageStatus.searching, nextResult: previous);
    try {
      final sources = state.selectedSourceId == null
          ? state.sources
          : state.sources.where((source) => source.id == state.selectedSourceId).toList(growable: false);
      final failedIds = previous.failedSources.map((source) => source.source.id).toSet();
      final result = await BatchSearchCoordinator(_gateway).run(
        query: state.query,
        sources: sources,
        cancellation: cancellation,
        previous: previous,
        sourceIds: failedIds,
        onUpdate: (next) {
          if (_isCurrent(generation)) state = state.withResult(nextStatus: SearchPageStatus.searching, nextResult: next);
        },
      );
      if (_isCurrent(generation)) {
        state = result.allFailed
            ? SearchPageState.failure(
                sources: state.sources,
                selectedSourceId: state.selectedSourceId,
                query: state.query,
                error: result.failedSources.first.error ?? AppError.fromCode(AppErrorCode.internal),
                retainedResult: result,
                hotSearches: state.hotSearches,
                sortOrder: state.sortOrder,
              )
            : state.withResult(nextStatus: SearchPageStatus.loaded, nextResult: result);
      }
    } finally {
      if (identical(_searchCancellation, cancellation)) _searchCancellation = null;
    }
  }

  Future<void> _loadSuggestions(String? pluginId, int generation) async {
    final cancellation = _replaceSuggestionCancellation();
    try {
      final sources = pluginId == null ? state.sources : state.sources.where((source) => source.id == pluginId).toList(growable: false);
      final suggestions = await Future.wait<PluginSearchSuggestionsResult>([
        for (final source in sources)
          runCancellableSourceRequest(_gateway, cancellation, () => _gateway.searchSuggestions(pluginId: source.id)).catchError(
            (_) => PluginSearchSuggestionsResult(
              pluginId: source.id,
              sourceName: source.displayName,
              items: const <PluginSearchSuggestion>[],
              nextCursor: null,
            ),
          ),
      ]);
      if (!_isCurrentSuggestion(generation) || state.selectedSourceId != pluginId) {
        return;
      }
      final merged = <String, PluginSearchSuggestion>{};
      for (final result in suggestions) {
        for (final item in result.items) {
          final existing = merged[item.query];
          if (existing == null || (existing.metric == null && item.metric != null)) merged[item.query] = item;
        }
      }
      state = state.withHotSearches(merged.values.take(20));
    } on Object {
      // Suggestions are optional source metadata. Their failure must not erase
      // a selectable source or turn the page into a false search failure.
    } finally {
      if (identical(_suggestionCancellation, cancellation)) _suggestionCancellation = null;
    }
  }

  PluginInvocationCancellation _replaceSearchCancellation() {
    _cancelSearch();
    return _searchCancellation = PluginInvocationCancellation();
  }

  PluginInvocationCancellation _replaceSuggestionCancellation() {
    _cancelSuggestions();
    return _suggestionCancellation = PluginInvocationCancellation();
  }

  void _cancelSearch() {
    _searchCancellation?.cancel();
    _searchCancellation = null;
  }

  void _cancelSuggestions() {
    _suggestionCancellation?.cancel();
    _suggestionCancellation = null;
  }

  bool _isCurrentSuggestion(int generation) => !_disposed && generation == _latestSuggestionGeneration;
}
