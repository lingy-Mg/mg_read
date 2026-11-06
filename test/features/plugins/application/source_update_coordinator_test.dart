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
  test('interrupted downloads still honor catalog network failure backoff', () async {
    final settings = await _settings();
    var now = DateTime.utc(2026, 11, 6);
    await settings.set(AppSettingKeys.sourceUpdateCheckState, {
      'attemptedAt': now.toIso8601String(),
      'succeededAt': now.toIso8601String(),
      'failures': 2,
      'downloadPending': true,
    });
    final catalog = _Catalog()..pending.complete(const SourceCollection([]));
    final coordinator = SourceUpdateCoordinator(
      settings: settings,
      catalog: catalog,
      gateway: _Gateway(),
      clock: () => now,
      installed: () async => [_installed],
    );
    await coordinator.prepareAutomaticUpdates(mayContinue: () => true);
    expect(catalog.calls, 0);
    now = now.add(const Duration(minutes: 5));
    await coordinator.prepareAutomaticUpdates(mayContinue: () => true);
    expect(catalog.calls, 1);
    expect(settings.get(AppSettingKeys.sourceUpdateCheckState)['downloadPending'], false);
  });
  test('an interrupted process download retries on the next launch despite the successful catalog cadence', () async {
    final settings = await _settings();
    final catalog = _Catalog()
      ..pending.complete(
        SourceCollection([
          _update(() => Stream.value([1])),
        ]),
      );
    final firstGateway = _Gateway()..blocked = Completer<void>();
    final first = SourceUpdateCoordinator(settings: settings, catalog: catalog, gateway: firstGateway, installed: () async => [_installed]);
    final interrupted = first.prepareAutomaticUpdates(mayContinue: () => true);
    await Future<void>.delayed(Duration.zero);
    expect(firstGateway.stages, 1);
    expect(settings.get(AppSettingKeys.sourceUpdateCheckState)['downloadPending'], true);
    final nextGateway = _Gateway();
    final relaunched = SourceUpdateCoordinator(
      settings: settings,
      catalog: catalog,
      gateway: nextGateway,
      installed: () async => [_installed],
    );
    await relaunched.prepareAutomaticUpdates(mayContinue: () => true);
    expect(catalog.calls, 2);
    expect(nextGateway.stages, 1);
    expect(settings.get(AppSettingKeys.sourceUpdateCheckState)['downloadPending'], false);
    firstGateway.blocked!.complete();
    await interrupted;
  });
  test('idle downloads share one flight, wait across navigation and never use immediate imports', () async {
    final settings = await _settings();
    final catalog = _Catalog();
    final gateway = _Gateway();
    var idle = false;
    var downloads = 0;
    final update = _update(() async* {
      downloads++;
      yield [1];
    });
    final coordinator = SourceUpdateCoordinator(
      settings: settings,
      catalog: catalog,
      gateway: gateway,
      installed: () async => [_installed],
    );
    await coordinator.prepareAutomaticUpdates(mayContinue: () => idle);
    expect(catalog.calls, 0);
    idle = true;
    final a = coordinator.prepareAutomaticUpdates(mayContinue: () => idle);
    final b = coordinator.prepareAutomaticUpdates(mayContinue: () => idle);
    await Future<void>.delayed(Duration.zero);
    idle = false;
    catalog.pending.complete(SourceCollection([update]));
    await Future.wait([a, b]);
    expect(downloads, 0);
    expect(gateway.stages, 0);
    idle = true;
    await coordinator.prepareAutomaticUpdates(mayContinue: () => idle);
    expect(downloads, 1);
    expect(gateway.stages, 1);
    await coordinator.prepareAutomaticUpdates(mayContinue: () => idle);
    expect(downloads, 1);
    expect(catalog.calls, 1);
  });

  test('download failures persist backoff and retry without marking the update as complete', () async {
    final settings = await _settings();
    final catalog = _Catalog()
      ..pending.complete(
        SourceCollection([
          _update(() => Stream.value([1])),
        ]),
      );
    final gateway = _Gateway()..failDownload = true;
    var now = DateTime.utc(2026, 11, 6);
    SourceUpdateCoordinator create() => SourceUpdateCoordinator(
      settings: settings,
      catalog: catalog,
      gateway: gateway,
      clock: () => now,
      installed: () async => [_installed],
    );
    await create().prepareAutomaticUpdates(mayContinue: () => true);
    expect(gateway.stages, 1);
    expect(settings.get(AppSettingKeys.sourceUpdateCheckState)['failures'], 1);
    await create().prepareAutomaticUpdates(mayContinue: () => true);
    expect(gateway.stages, 1);
    now = now.add(const Duration(minutes: 1));
    gateway.failDownload = false;
    await create().prepareAutomaticUpdates(mayContinue: () => true);
    expect(gateway.stages, 2);
    expect(settings.get(AppSettingKeys.sourceUpdateCheckState)['failures'], 0);
  });
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
  int stages = 0;
  bool failDownload = false;
  Completer<void>? blocked;
  @override
  Future<void> stageUpdates(List<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> artifacts) async {
    stages++;
    if (blocked != null) await blocked!.future;
    if (failDownload) throw StateError('download interrupted');
    for (final input in artifacts) {
      await input.bytes.drain<void>();
    }
  }

  @override
  Future<List<PluginTransferPlanItem>> plan(List<PluginTransferArtifact> artifacts) async => [
    for (final artifact in artifacts)
      PluginTransferPlanItem(
        action: PluginTransferPlanAction.upgrade,
        pluginId: artifact.pluginId,
        receiverVersion: '1.0.0',
        version: artifact.version,
      ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<AppSettingsManager> _settings() async {
  final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
  await settings.initialize();
  addTearDown(settings.close);
  return settings;
}

const _installed = PluginRuntimePlugin(
  activeVersion: '1.0.0',
  contentKinds: ['novel'],
  displayName: 'source',
  enabled: true,
  id: 'source',
  name: 'source',
  pendingVersion: null,
  status: 'active',
);

SourceCollectionPlugin _update(Stream<List<int>> Function() openBytes) => SourceCollectionPlugin(
  id: 'source',
  name: 'source',
  version: '1.1.0',
  format: 'singleFile',
  byteLength: 1,
  checksum: '00000000',
  openBytes: openBytes,
);
