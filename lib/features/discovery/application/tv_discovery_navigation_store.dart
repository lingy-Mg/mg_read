/// App-owned persistence port for the last selected source's TV navigation.
/// Settings own IO/debounce/retry; reads never start Runtime or perform disk IO.
/// Cache write failures remain non-fatal and identical snapshots avoid writes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'tv_discovery_navigation_snapshot.dart';

abstract interface class TvDiscoveryNavigationStore {
  TvDiscoveryNavigationSnapshot? load();
  Future<void> save(TvDiscoveryNavigationSnapshot snapshot);
  Future<void> clear();
}

final tvDiscoveryNavigationStoreProvider = Provider<TvDiscoveryNavigationStore>((ref) {
  return AppSettingsTvDiscoveryNavigationStore(ref.watch(appSettingsProvider));
});

class AppSettingsTvDiscoveryNavigationStore implements TvDiscoveryNavigationStore {
  const AppSettingsTvDiscoveryNavigationStore(this.settings);
  final AppSettingsManager settings;

  @override
  TvDiscoveryNavigationSnapshot? load() {
    if (!settings.supports(AppSettingKeys.tvDiscoveryNavigation)) return null;
    final snapshot = TvDiscoveryNavigationSnapshot.fromJson(settings.get(AppSettingKeys.tvDiscoveryNavigation));
    final selected = settings.get(AppSettingKeys.discoverySourceId);
    return selected == null || selected == snapshot?.sourceId ? snapshot : null;
  }

  @override
  Future<void> save(TvDiscoveryNavigationSnapshot snapshot) async {
    if (!settings.supports(AppSettingKeys.tvDiscoveryNavigation)) return;
    if (!snapshot.canPersist) return clear();
    final previous = TvDiscoveryNavigationSnapshot.fromJson(settings.get(AppSettingKeys.tvDiscoveryNavigation));
    if (previous != null && previous.pluginVersion == snapshot.pluginVersion && previous.sameNavigation(snapshot)) return;
    try {
      await settings.set(AppSettingKeys.tvDiscoveryNavigation, snapshot.toJson());
    } on Object {
      // Persistence owns reporting/retry; navigation remains usable in memory.
    }
  }

  @override
  Future<void> clear() async {
    if (!settings.supports(AppSettingKeys.tvDiscoveryNavigation) || settings.get(AppSettingKeys.tvDiscoveryNavigation).isEmpty) return;
    try {
      await settings.set(AppSettingKeys.tvDiscoveryNavigation, const <String, Object?>{});
    } on Object {
      // A stale cache is revalidated against the next authoritative catalog.
    }
  }
}
