import 'package:flutter/foundation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

enum DiscoveryPageStatus {
  loadingSources,
  loadingContent,
  loaded,
  empty,
  noSources,
  failure,
}

@immutable
final class DiscoveryPageState {
  DiscoveryPageState._({
    required this.status,
    required Iterable<PluginSourceDescriptor> sources,
    required this.selectedSourceId,
    required this.result,
    required this.error,
  }) : sources = List<PluginSourceDescriptor>.unmodifiable(sources);

  factory DiscoveryPageState.loadingSources() => DiscoveryPageState._(
    status: DiscoveryPageStatus.loadingSources,
    sources: const <PluginSourceDescriptor>[],
    selectedSourceId: null,
    result: null,
    error: null,
  );

  factory DiscoveryPageState.loadingContent({
    required Iterable<PluginSourceDescriptor> sources,
    required String selectedSourceId,
  }) => DiscoveryPageState._(
    status: DiscoveryPageStatus.loadingContent,
    sources: sources,
    selectedSourceId: selectedSourceId,
    result: null,
    error: null,
  );

  factory DiscoveryPageState.resolved({
    required Iterable<PluginSourceDescriptor> sources,
    required String selectedSourceId,
    required PluginDiscoverResult result,
    required bool isEmpty,
  }) => DiscoveryPageState._(
    status: isEmpty ? DiscoveryPageStatus.empty : DiscoveryPageStatus.loaded,
    sources: sources,
    selectedSourceId: selectedSourceId,
    result: result,
    error: null,
  );

  factory DiscoveryPageState.noSources() => DiscoveryPageState._(
    status: DiscoveryPageStatus.noSources,
    sources: const <PluginSourceDescriptor>[],
    selectedSourceId: null,
    result: null,
    error: null,
  );

  factory DiscoveryPageState.failure({
    required Iterable<PluginSourceDescriptor> sources,
    required String? selectedSourceId,
    required AppError error,
  }) => DiscoveryPageState._(
    status: DiscoveryPageStatus.failure,
    sources: sources,
    selectedSourceId: selectedSourceId,
    result: null,
    error: error,
  );

  final DiscoveryPageStatus status;
  final List<PluginSourceDescriptor> sources;
  final String? selectedSourceId;
  final PluginDiscoverResult? result;
  final AppError? error;
}
