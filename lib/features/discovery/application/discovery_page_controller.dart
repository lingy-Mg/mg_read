import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

final discoveryPageControllerProvider =
    NotifierProvider.autoDispose<DiscoveryPageController, DiscoveryPageState>(
      DiscoveryPageController.new,
    );

/// Loads plugin-defined discovery sections without exposing Runtime transport.
class DiscoveryPageController extends Notifier<DiscoveryPageState> {
  late SourceContentGateway _gateway;
  int _latestGeneration = 0;
  bool _disposed = false;

  @override
  DiscoveryPageState build() {
    _gateway = ref.watch(sourceContentGatewayProvider);
    ref.onDispose(() => _disposed = true);
    final generation = ++_latestGeneration;
    scheduleMicrotask(() => unawaited(_initialize(generation)));
    return DiscoveryPageState.loadingSources();
  }

  Future<void> retry() {
    if (state.sources.isEmpty) {
      final generation = ++_latestGeneration;
      return _initialize(generation);
    }
    final pluginId = state.selectedSourceId ?? state.sources.first.id;
    return _load(pluginId: pluginId);
  }

  Future<void> refresh() {
    final pluginId = state.selectedSourceId;
    if (pluginId == null) return retry();
    final selectedTabId = state.result?.selectedTabId;
    String? target;
    if (selectedTabId != null) {
      for (final tab in state.result!.tabs) {
        if (tab.id == selectedTabId) {
          target = tab.target;
          break;
        }
      }
    }
    return _load(pluginId: pluginId, target: target);
  }

  Future<void> selectSource(String pluginId) {
    if (!state.sources.any((source) => source.id == pluginId)) {
      return Future<void>.value();
    }
    return _load(pluginId: pluginId);
  }

  Future<void> selectTarget(String target) {
    final pluginId = state.selectedSourceId;
    if (pluginId == null) return Future<void>.value();
    return _load(pluginId: pluginId, target: target);
  }

  Future<void> _initialize(int generation) async {
    state = DiscoveryPageState.loadingSources();
    try {
      final sources = await _gateway.listSources();
      if (!_isCurrent(generation)) return;
      if (sources.isEmpty) {
        state = DiscoveryPageState.noSources();
        return;
      }
      await _load(
        pluginId: sources.first.id,
        sources: sources,
        generation: generation,
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

  Future<void> _load({
    required String pluginId,
    String? target,
    List<PluginSourceDescriptor>? sources,
    int? generation,
  }) async {
    final requestGeneration = generation ?? ++_latestGeneration;
    final availableSources = sources ?? state.sources;
    state = DiscoveryPageState.loadingContent(
      sources: availableSources,
      selectedSourceId: pluginId,
    );
    try {
      final result = await _gateway.discover(
        pluginId: pluginId,
        target: target,
      );
      if (!_isCurrent(requestGeneration)) return;
      final itemCount = result.sections.fold<int>(
        0,
        (count, section) =>
            count + section.items.length + section.categories.length,
      );
      state = DiscoveryPageState.resolved(
        sources: availableSources,
        selectedSourceId: pluginId,
        result: result,
        isEmpty: itemCount == 0,
      );
    } on Object catch (error) {
      if (!_isCurrent(requestGeneration)) return;
      state = DiscoveryPageState.failure(
        sources: availableSources,
        selectedSourceId: pluginId,
        error: AppError.fromUnknown(error),
      );
    }
  }

  bool _isCurrent(int generation) {
    return !_disposed && generation == _latestGeneration;
  }
}
