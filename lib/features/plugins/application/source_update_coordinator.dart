/// App-owned online source checks. Catalog reads share one flight; installation
/// remains an explicit user action through the existing Runtime import lock.
/// Timing is stored in app settings, never in plugin data or UI state.
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
  Future<UpdateCheckResult<List<SourceCollectionCandidate>>>? _checking;

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
      if (settings.supports(AppSettingKeys.sourceUpdateCheckState)) _timing.restore(settings.get(AppSettingKeys.sourceUpdateCheckState));
    }
    final now = _clock();
    if (!force && !_timing.isDue(now, const Duration(hours: 24))) return const UpdateCheckResult(UpdateCheckStatus.skipped);
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
      if (settings.supports(AppSettingKeys.sourceUpdateCheckState)) {
        try {
          await settings.set(AppSettingKeys.sourceUpdateCheckState, _timing.toJson());
        } on Object {
          /* Memory cadence survives IO failure. */
        }
      }
    }
  }
}
