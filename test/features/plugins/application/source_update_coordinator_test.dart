import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/app_update/application/update_check_result.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/application/source_plugin_transfer_gateway.dart';
import 'package:mg_read/features/plugins/application/source_update_coordinator.dart';
import '../../../core/settings/settings_testkit.dart';

void main() {
  test('shares checks, persists failure backoff, and manual checks bypass disabled automation', () async {
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    var now = DateTime.utc(2026, 10, 28);
    final catalog = _Catalog();
    SourceUpdateCoordinator create() => SourceUpdateCoordinator(
      settings: settings,
      catalog: catalog,
      gateway: _Gateway(),
      clock: () => now,
      installed: () async => const [
        PluginRuntimePlugin(
          activeVersion: '1.0.0',
          contentKinds: ['novel'],
          displayName: 'source',
          enabled: true,
          id: 'source',
          name: 'source',
          pendingVersion: null,
          status: 'active',
        ),
      ],
    );
    var coordinator = create();
    final a = coordinator.check();
    final b = coordinator.check();
    await Future<void>.delayed(Duration.zero);
    expect(catalog.calls, 1);
    catalog.pending.completeError(StateError('offline'));
    expect((await a).status, UpdateCheckStatus.failed);
    expect((await b).status, UpdateCheckStatus.failed);
    coordinator = create();
    expect((await coordinator.check()).status, UpdateCheckStatus.skipped);
    now = now.add(const Duration(minutes: 1));
    catalog.pending = Completer<SourceCollection>()..complete(const SourceCollection([]));
    expect((await coordinator.check()).status, UpdateCheckStatus.upToDate);
    expect(catalog.calls, 2);
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    expect((await coordinator.check()).status, UpdateCheckStatus.skipped);
    expect((await coordinator.check(force: true)).status, UpdateCheckStatus.upToDate);
    expect(catalog.calls, 3);
  });
}

final class _Catalog implements OnlineSourceCatalogReader {
  int calls = 0;
  Completer<SourceCollection> pending = Completer();
  @override
  Future<SourceCollection> loadCatalog() {
    calls++;
    return pending.future;
  }
}

final class _Gateway implements SourcePluginTransferGateway {
  @override
  Future<List<PluginTransferPlanItem>> plan(List<PluginTransferArtifact> artifacts) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
