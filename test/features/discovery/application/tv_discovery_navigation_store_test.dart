/// Navigation cache survives real settings close/reopen and tolerates corruption.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/persistence/persistence.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_navigation_snapshot.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_navigation_store.dart';
import 'package:mg_read/features/discovery/application/tv_discovery_session.dart';

void main() {
  test('snapshot survives settings close/reopen with opaque targets unchanged and repeated saves are silent', () async {
    final root = await Directory.systemTemp.createTemp('mgread-tv-navigation-');
    addTearDown(() => root.delete(recursive: true));
    var settings = await _open(root);
    final snapshot = _snapshot();
    final store = AppSettingsTvDiscoveryNavigationStore(settings);
    await store.save(snapshot);
    await settings.close();
    settings = await _open(root);
    addTearDown(settings.close);
    final reopened = AppSettingsTvDiscoveryNavigationStore(settings);
    expect(reopened.load()!.sameNavigation(snapshot), isTrue);
    expect(reopened.load()!.tabs.last.target, 'opaque/?a=%2F&b=中文#v1');
    var changes = 0;
    final subscription = settings.changes.listen((_) => changes++);
    addTearDown(subscription.cancel);
    await reopened.save(_snapshot());
    expect(changes, 0);
    await settings.set(AppSettingKeys.discoverySourceId, 'other');
    expect(reopened.load(), isNull);
    await settings.set(AppSettingKeys.discoverySourceId, 'sakura');
    expect(reopened.load(), isNotNull);
    await reopened.clear();
    expect(reopened.load(), isNull);
  });

  test('first install, malformed and future snapshots are cache misses without losing source preferences', () async {
    final root = await Directory.systemTemp.createTemp('mgread-tv-cache-corrupt-');
    addTearDown(() => root.delete(recursive: true));
    var settings = await _open(root);
    expect(AppSettingsTvDiscoveryNavigationStore(settings).load(), isNull);
    await settings.set(AppSettingKeys.discoverySourceId, 'sakura');
    await settings.set(AppSettingKeys.tvDiscoveryNavigation, {
      'version': 1,
      'sourceId': 'sakura',
      'pluginVersion': '1',
      'tabs': [
        {'label': 42, 'target': null},
      ],
    });
    await settings.close();
    settings = await _open(root);
    addTearDown(settings.close);
    expect(settings.state, SettingsState.ready);
    expect(settings.get(AppSettingKeys.discoverySourceId), 'sakura');
    expect(AppSettingsTvDiscoveryNavigationStore(settings).load(), isNull);
    expect(TvDiscoveryNavigationSnapshot.fromJson({..._snapshot().toJson(), 'version': 99}), isNull);
    expect(
      TvDiscoveryNavigationSnapshot.fromJson({
        ..._snapshot().toJson(),
        'tabs': [
          {'label': '首页', 'target': null},
          {'label': '重复首页', 'target': null},
        ],
      }),
      isNull,
    );
  });

  test('oversized corrupt cache fields do not invalidate the discovery settings document', () async {
    final root = await Directory.systemTemp.createTemp('mgread-tv-cache-document-');
    addTearDown(() => root.delete(recursive: true));
    final records = await PersistenceRecordStore.open(
      dataRoot: root,
      registry: RecordDocumentRegistry(settingsRecordDocumentCodecs(AppSettingKeys.registry, scopeKind: 'app')),
    );
    await records.create(
      RecordDraft(
        id: AppSettingKeys.discoveryDocument.id,
        recordKind: AppSettingKeys.discoveryDocument.kind,
        scope: const ScopeKey(kind: 'app', id: 'tv-cache-test'),
        document: {
          AppSettingKeys.discoverySourceId.id: 'sakura',
          AppSettingKeys.tvDiscoveryNavigation.id: {for (var i = 0; i < 40; i++) 'bad-$i': i},
        },
      ),
    );
    await records.close();
    final settings = await _open(root);
    addTearDown(settings.close);
    expect(settings.state, SettingsState.ready);
    expect(settings.get(AppSettingKeys.discoverySourceId), 'sakura');
    expect(AppSettingsTvDiscoveryNavigationStore(settings).load(), isNull);
  });
}

TvDiscoveryNavigationSnapshot _snapshot() => TvDiscoveryNavigationSnapshot(
  sourceId: 'sakura',
  pluginVersion: '1',
  tabs: const [
    TvDiscoveryTab(label: '樱花动漫', target: null),
    TvDiscoveryTab(label: '热榜', target: 'opaque/?a=%2F&b=中文#v1'),
  ],
);

Future<AppSettingsManager> _open(Directory root) async {
  final store = await PersistentSettingsStore.open(
    dataRoot: root,
    scope: const ScopeKey(kind: 'app', id: 'tv-cache-test'),
    registry: AppSettingKeys.registry,
  );
  final manager = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
  await manager.initialize();
  return manager;
}
