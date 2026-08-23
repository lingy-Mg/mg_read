import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

final searchPageControllerProvider =
    NotifierProvider.autoDispose<SearchPageController, SearchPageState>(
      SearchPageController.new,
    );

/// Owns source selection and search request generations for the search page.
class SearchPageController extends Notifier<SearchPageState> {
  late SourceContentGateway _gateway;
  int _latestGeneration = 0;
  int _latestSuggestionGeneration = 0;
  bool _disposed = false;

  @override
  SearchPageState build() {
    _gateway = ref.watch(sourceContentGatewayProvider);
    ref.onDispose(() => _disposed = true);
    final generation = ++_latestGeneration;
    scheduleMicrotask(() => unawaited(_loadSources(generation)));
    return SearchPageState.loadingSources();
  }

  Future<void> retrySources() {
    ref.invalidate(availablePluginSourcesProvider);
    final generation = ++_latestGeneration;
    return _loadSources(generation);
  }

  Future<void> selectSource(String pluginId) async {
    if (!state.sources.any((source) => source.id == pluginId)) return;
    final query = state.query;
    state = SearchPageState.ready(
      sources: state.sources,
      selectedSourceId: pluginId,
      query: query,
      hotSearches: state.hotSearches,
    );
    unawaited(_loadSuggestions(pluginId, ++_latestSuggestionGeneration));
    if (query.isNotEmpty) await search(query);
  }

  Future<void> clear() async {
    _latestGeneration += 1;
    state = SearchPageState.ready(
      sources: state.sources,
      selectedSourceId: state.selectedSourceId,
      hotSearches: state.hotSearches,
    );
  }

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) {
      await clear();
      return;
    }
    final pluginId = state.selectedSourceId;
    if (pluginId == null) return;

    final generation = ++_latestGeneration;
    final retainedResult = state.result;
    state = SearchPageState.searching(
      sources: state.sources,
      selectedSourceId: pluginId,
      query: query,
      retainedResult: retainedResult,
      hotSearches: state.hotSearches,
    );
    try {
      final result = await _gateway.search(pluginId: pluginId, query: query);
      if (!_isCurrent(generation)) return;
      state = SearchPageState.loaded(
        sources: state.sources,
        selectedSourceId: pluginId,
        query: query,
        result: result,
        hotSearches: state.hotSearches,
      );
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      state = SearchPageState.failure(
        sources: state.sources,
        selectedSourceId: pluginId,
        query: query,
        error: AppError.fromUnknown(error),
        retainedResult: retainedResult,
        hotSearches: state.hotSearches,
      );
    }
  }

  Future<void> _loadSources(int generation) async {
    state = SearchPageState.loadingSources();
    try {
      final sources = await ref.read(availablePluginSourcesProvider.future);
      if (!_isCurrent(generation)) return;
      state = SearchPageState.ready(
        sources: sources,
        selectedSourceId: sources.isEmpty ? null : sources.first.id,
      );
      if (sources.isNotEmpty) {
        unawaited(
          _loadSuggestions(sources.first.id, ++_latestSuggestionGeneration),
        );
      }
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
    if (pluginId == null) return;
    final generation = ++_latestSuggestionGeneration;
    await _loadSuggestions(pluginId, generation);
  }

  Future<void> _loadSuggestions(String pluginId, int generation) async {
    try {
      final suggestions = await _gateway.searchSuggestions(pluginId: pluginId);
      if (!_isCurrentSuggestion(generation) ||
          state.selectedSourceId != pluginId) {
        return;
      }
      state = state.withHotSearches(suggestions.items);
    } on Object {
      // Suggestions are optional source metadata. Their failure must not erase
      // a selectable source or turn the page into a false search failure.
    }
  }

  bool _isCurrentSuggestion(int generation) =>
      !_disposed && generation == _latestSuggestionGeneration;
}
