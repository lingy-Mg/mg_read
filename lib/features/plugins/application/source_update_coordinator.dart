/// App-owned source checks and silent idle downloads. Runtime owns validated
/// deferred artifacts and activates them on the next application launch.
/// Manual checks retain their confirmation flow. Failures back off in settings;
/// foreground/idle admission is rechecked before each source download.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/app_update/application/update_check_result.dart';
import 'plugin_runtime_connection.dart';
import 'source_collection_import.dart';
import 'source_plugin_transfer_gateway.dart';

final sourceUpdateCoordinatorProvider = Provider<SourceUpdateCoordinator>(
  (ref) => SourceUpdateCoordinator(
    settings: ref.read(appSettingsProvider),
    mayStartAutomatic: () =>
        WidgetsBinding.instance.lifecycleState == null || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    catalog: ref.read(onlineSourceCatalogServiceProvider),
    gateway: ref.read(sourcePluginTransferGatewayProvider),
    installed: () async => (await ref.read(pluginRuntimeConnectionProvider.future)).plugins,
  ),
);

final class SourceUpdateCoordinator {
  SourceUpdateCoordinator({
    required this.settings,
    required this.catalog,
    required this.gateway,
    required this.installed,
    DateTime Function()? clock,
    this.mayStartAutomatic,
  }) : _clock = clock ?? DateTime.now;
  final bool Function()? mayStartAutomatic;
  final AppSettingsManager settings;
  final OnlineSourceCatalogReader catalog;
  final SourcePluginTransferGateway gateway;
  final Future<List<PluginRuntimePlugin>> Function() installed;
  final DateTime Function() _clock;
  final AutomaticCheckTiming _timing = AutomaticCheckTiming();
  bool _restored = false;
  bool _downloadPending = false;
  Future<UpdateCheckResult<List<SourceCollectionCandidate>>>? _checking;
  Future<void>? _preparing;
  List<SourceCollectionCandidate>? _pending;

  Future<void> prepareAutomaticUpdates({required bool Function() mayContinue}) =>
      _preparing ??= _prepareAutomaticUpdates(mayContinue).whenComplete(() => _preparing = null);

  bool get _automaticEnabled =>
      settings.supports(AppSettingKeys.sourceAutoUpdateCheckEnabled) && settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled);

  Future<void> _prepareAutomaticUpdates(bool Function() mayContinue) async {
    bool allowed() => _automaticEnabled && mayStartAutomatic?.call() != false && mayContinue();
    if (!allowed()) return;
    final updates = _pending ?? (await check()).value;
    if (updates == null) return;
    if (updates.isEmpty) {
      _downloadPending = false;
      await _saveTiming();
      return;
    }
    _pending = updates;
    _downloadPending = true;
    // A process exit during download must not suppress retries for 24 hours.
    await _saveTiming();
    try {
      if (!allowed()) return;
      await gateway.stageUpdates([
        for (final update in updates) (artifact: update.plugin.artifact, bytes: _openWhenIdle(update.plugin, allowed)),
      ]);
      _pending = null;
      _downloadPending = false;
      await _saveTiming();
    } on _SourceUpdateDeferred {
      // Navigation only defers work; it is not a network failure.
    } on Object {
      _pending = null;
      _downloadPending = false;
      _timing.complete(_clock(), success: false);
      await _saveTiming();
    }
  }

  Stream<List<int>> _openWhenIdle(SourceCollectionPlugin plugin, bool Function() allowed) async* {
    if (!allowed()) throw const _SourceUpdateDeferred();
    yield* plugin.openBytes();
  }

  Future<UpdateCheckResult<List<SourceCollectionCandidate>>> check({bool force = false}) async {
    if (const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')) return const UpdateCheckResult(UpdateCheckStatus.unsupported);
    if (!force &&
        (!settings.supports(AppSettingKeys.sourceAutoUpdateCheckEnabled) || !settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled))) {
      return const UpdateCheckResult(UpdateCheckStatus.skipped);
    }
    final active = _checking;
    if (active != null) {
      final result = await active;
      if (!force || result.status != UpdateCheckStatus.skipped) return result;
    }
    return _checking ??= _check(force).whenComplete(() => _checking = null);
  }

  Future<UpdateCheckResult<List<SourceCollectionCandidate>>> _check(bool force) async {
    if (!_restored) {
      _restored = true;
      if (settings.supports(AppSettingKeys.sourceUpdateCheckState)) {
        final state = settings.get(AppSettingKeys.sourceUpdateCheckState);
        _timing.restore(state);
        _downloadPending = state['downloadPending'] == true;
      }
    }
    final now = _clock();
    if (!force && (!_downloadPending || _timing.failures > 0) && !_timing.isDue(now, const Duration(hours: 24))) {
      return const UpdateCheckResult(UpdateCheckStatus.skipped);
    }
    try {
      final plugins = await installed();
      if (!force && mayStartAutomatic?.call() == false) return const UpdateCheckResult(UpdateCheckStatus.skipped);
      if (plugins.isEmpty) return const UpdateCheckResult(UpdateCheckStatus.upToDate);
      final collection = await catalog.loadCatalog();
      if (!force && mayStartAutomatic?.call() == false) return const UpdateCheckResult(UpdateCheckStatus.skipped);
      final plan = await gateway.plan([for (final item in collection.plugins) item.artifact]);
      final updates = sourceCollectionAvailableUpdates(planSourceCollection(collection: collection, plan: plan, installed: plugins));
      _timing.complete(now, success: true);
      return UpdateCheckResult(updates.isEmpty ? UpdateCheckStatus.upToDate : UpdateCheckStatus.available, value: updates);
    } on Object catch (error) {
      _timing.complete(now, success: false);
      return UpdateCheckResult(UpdateCheckStatus.failed, error: error);
    } finally {
      await _saveTiming();
    }
  }

  Future<void> _saveTiming() async {
    if (!settings.supports(AppSettingKeys.sourceUpdateCheckState)) return;
    try {
      await settings.set(AppSettingKeys.sourceUpdateCheckState, {..._timing.toJson(), 'downloadPending': _downloadPending});
    } on Object {
      /* Memory cadence survives IO failure. */
    }
  }
}

final class _SourceUpdateDeferred implements Exception {
  const _SourceUpdateDeferred();
}
