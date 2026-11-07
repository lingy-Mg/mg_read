/// TV home validation is independent from foreground navigation generations.
/// Owns only an in-memory snapshot, last selection and cancellable home request.
/// A validated home updates navigation first, then commits the user's last target;
/// unchanged navigation never replaces active content or resets its filters.
part of 'discovery_page_controller.dart';

class _TvDiscoveryStartup {
  TvDiscoveryNavigationSnapshot? snapshot;
  _TvDiscoverySelection? pending;
  PluginInvocationCancellation? cancellation;
  _ActiveDiscoveryLoad? diagnostic;
  int generation = 0;
  int notice = 0;
  bool loading = false;
}

class _TvDiscoverySelection {
  const _TvDiscoverySelection(this.sourceId, this.target);
  final String sourceId;
  final String? target;
}

extension _DiscoveryTvStartupOperations on DiscoveryPageController {
  void _stopTvHome({bool clearPending = true, bool clearSnapshot = false}) {
    ++_tvStartup.generation;
    _tvStartup.cancellation?.cancel();
    _tvStartup.cancellation = null;
    final diagnostic = _tvStartup.diagnostic;
    if (diagnostic != null) _endLoad(diagnostic, DiagnosticOutcome.cancelled);
    _tvStartup.diagnostic = null;
    _tvStartup.loading = false;
    if (clearPending) _tvStartup.pending = null;
    if (clearSnapshot) {
      _tvStartup.snapshot = null;
      _tvPrimaryTarget = null;
      _tvTabTargets.clear();
    }
  }

  Future<void> _loadSourceHome(String pluginId, List<PluginSourceDescriptor> sources, {int? generation}) => _tvMode
      ? _loadTvHome(pluginId, sources)
      : _loadDocument(pluginId: pluginId, target: null, sources: sources, generation: generation, resetStack: true);

  Future<void> _loadTvHome(String pluginId, List<PluginSourceDescriptor> sources) async {
    _stopTvHome(clearPending: false);
    final generation = _tvStartup.generation;
    final cancellation = PluginInvocationCancellation();
    _tvStartup.cancellation = cancellation;
    _tvStartup.loading = true;
    final load = _ActiveDiscoveryLoad(
      span: _diagnostics.startSpan(
        AppDiagnosticEvents.discoveryNavigation,
        attributes: () => DiagnosticObjectValue({
          'operation': DiagnosticValue.string('load'),
          'requestGeneration': DiagnosticValue.int64(generation),
          'navigationDepth': DiagnosticValue.int64(0),
          'resultState': DiagnosticValue.string('loading'),
        }),
      ),
      pluginId: pluginId,
      capability: 'source.discover.v1',
      requestGeneration: generation,
      navigationDepth: 0,
    );
    _tvStartup.diagnostic = load;
    bool current() => !_disposed && _tvMode && generation == _tvStartup.generation;
    final before = _startupState;
    if (before.selectedSourceId != pluginId || before.result == null) {
      _setStartupState(
        DiscoveryPageState.loadingContent(
          sources: sources,
          selectedSourceId: pluginId,
          canNavigateBack: false,
          navigationDepth: 0,
          target: _tvStartup.pending?.target ?? _tvPrimaryTarget,
        ),
      );
    }
    try {
      final result = await runCancellableSourceRequest(_gateway, cancellation, () => _gateway.discover(pluginId: pluginId, target: null));
      if (!current()) return;
      if (result is! PluginDiscoveryDocumentResult || result.pluginId != pluginId) throw StateError('Expected a source homepage.');
      _endLoad(load, DiagnosticOutcome.success, itemCount: _documentItemCount(result.document));
      final navigation = TvDiscoveryNavigation(result);
      final version = sources.firstWhere((source) => source.id == pluginId).pluginVersion;
      final next = TvDiscoveryNavigationSnapshot(sourceId: pluginId, pluginVersion: version, tabs: navigation.tabs);
      final previous = _tvStartup.snapshot;
      _tvStartup.snapshot = previous != null && previous.pluginVersion == version && previous.sameNavigation(next) ? previous : next;
      final pending = _tvStartup.pending;
      final requested = pending?.sourceId == pluginId ? pending!.target : _tvPrimaryTarget;
      final target = next.contains(requested) ? requested : null;
      if (target != requested) {
        ++_tvStartup.notice;
        _tvTabTargets.remove(requested);
      }
      _tvStartup.pending = null;
      _tvStartup.loading = false;
      _tvPrimaryTarget = target;
      _setStartupState(_startupState.withSources(sources));
      _prepareTvHome(result);
      _cacheDocument(pluginId, null, result);
      // A background home must not cancel an already selected category load.
      final active = _startupState;
      if (active.selectedSourceId == pluginId &&
          target == requested &&
          target != null &&
          active.target == (_tvTabTargets[target] ?? target) &&
          (active.result != null || _activeLoad != null)) {
        _setStartupState(active.withSources(sources));
        return;
      }
      if (target != null) {
        _setStartupState(active.withSources(sources));
        await _selectTvDocument(pluginId, _tvTabTargets[target] ?? target);
      } else {
        ++_latestGeneration;
        _cancelActiveRequest();
        _endActiveLoad(DiagnosticOutcome.cancelled);
        _commitDocument(target: null, document: result, push: false, replaceCurrent: false, resetStack: true);
        _publish(result, sources: sources, selectedSourceId: pluginId);
      }
    } on Object catch (error, stack) {
      if (!current()) return;
      final active = _startupState;
      final appError = AppError.fromUnknown(error);
      _endLoad(load, _outcomeFor(appError), error: appError, stackTrace: stack);
      if (active.result != null) {
        _setStartupState(active.withRefreshError(appError));
      } else {
        _setStartupState(
          DiscoveryPageState.failure(
            sources: sources,
            selectedSourceId: pluginId,
            error: appError,
            canNavigateBack: false,
            navigationDepth: 0,
            target: _tvStartup.pending?.target ?? _tvPrimaryTarget,
          ),
        );
      }
    } finally {
      if (current()) {
        _tvStartup.loading = false;
        _tvStartup.cancellation = null;
        _tvStartup.diagnostic = null;
      }
      _endLoad(load, DiagnosticOutcome.cancelled);
    }
  }
}
