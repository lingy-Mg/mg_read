import 'package:flutter/foundation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

enum SearchPageStatus { loadingSources, ready, searching, loaded, failure }

@immutable
final class SearchPageState {
  SearchPageState._({
    required this.status,
    required Iterable<PluginSourceDescriptor> sources,
    required this.selectedSourceId,
    required this.query,
    required this.result,
    required this.error,
    required Iterable<PluginSearchSuggestion> hotSearches,
  }) : sources = List<PluginSourceDescriptor>.unmodifiable(sources),
       hotSearches = List<PluginSearchSuggestion>.unmodifiable(hotSearches);

  factory SearchPageState.loadingSources() => SearchPageState._(
    status: SearchPageStatus.loadingSources,
    sources: const <PluginSourceDescriptor>[],
    selectedSourceId: null,
    query: '',
    result: null,
    error: null,
    hotSearches: const <PluginSearchSuggestion>[],
  );

  factory SearchPageState.ready({
    required Iterable<PluginSourceDescriptor> sources,
    required String? selectedSourceId,
    String query = '',
    Iterable<PluginSearchSuggestion> hotSearches =
        const <PluginSearchSuggestion>[],
  }) => SearchPageState._(
    status: SearchPageStatus.ready,
    sources: sources,
    selectedSourceId: selectedSourceId,
    query: query,
    result: null,
    error: null,
    hotSearches: hotSearches,
  );

  factory SearchPageState.searching({
    required Iterable<PluginSourceDescriptor> sources,
    required String selectedSourceId,
    required String query,
    PluginSearchResult? retainedResult,
    Iterable<PluginSearchSuggestion> hotSearches =
        const <PluginSearchSuggestion>[],
  }) => SearchPageState._(
    status: SearchPageStatus.searching,
    sources: sources,
    selectedSourceId: selectedSourceId,
    query: query,
    result: retainedResult,
    error: null,
    hotSearches: hotSearches,
  );

  factory SearchPageState.loaded({
    required Iterable<PluginSourceDescriptor> sources,
    required String selectedSourceId,
    required String query,
    required PluginSearchResult result,
    Iterable<PluginSearchSuggestion> hotSearches =
        const <PluginSearchSuggestion>[],
  }) => SearchPageState._(
    status: SearchPageStatus.loaded,
    sources: sources,
    selectedSourceId: selectedSourceId,
    query: query,
    result: result,
    error: null,
    hotSearches: hotSearches,
  );

  factory SearchPageState.failure({
    required Iterable<PluginSourceDescriptor> sources,
    required String? selectedSourceId,
    required String query,
    required AppError error,
    PluginSearchResult? retainedResult,
    Iterable<PluginSearchSuggestion> hotSearches =
        const <PluginSearchSuggestion>[],
  }) => SearchPageState._(
    status: SearchPageStatus.failure,
    sources: sources,
    selectedSourceId: selectedSourceId,
    query: query,
    result: retainedResult,
    error: error,
    hotSearches: hotSearches,
  );

  final SearchPageStatus status;
  final List<PluginSourceDescriptor> sources;
  final String? selectedSourceId;
  final String query;
  final PluginSearchResult? result;
  final AppError? error;
  final List<PluginSearchSuggestion> hotSearches;

  bool get hasSources => sources.isNotEmpty;

  SearchPageState withHotSearches(Iterable<PluginSearchSuggestion> value) =>
      SearchPageState._(
        status: status,
        sources: sources,
        selectedSourceId: selectedSourceId,
        query: query,
        result: result,
        error: error,
        hotSearches: value,
      );
}
