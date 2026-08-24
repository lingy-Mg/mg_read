import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/settings/settings.dart';

/// The narrow persistence boundary for the most recently selected discovery
/// source. A missing value means that discovery should use its first source.
abstract interface class DiscoverySourceSelectionStore {
  Future<String?> load();

  Future<void> save(String sourceId);
}

final discoverySourceSelectionStoreProvider =
    Provider<DiscoverySourceSelectionStore>((ref) {
      return AppSettingsDiscoverySourceSelectionStore(
        ref.watch(appSettingsProvider),
      );
    });

/// Adapts the app-owned, debounced settings manager to the discovery feature.
final class AppSettingsDiscoverySourceSelectionStore
    implements DiscoverySourceSelectionStore {
  const AppSettingsDiscoverySourceSelectionStore(this._settings);

  final AppSettingsManager _settings;

  @override
  Future<String?> load() async =>
      _settings.get(AppSettingKeys.discoverySourceId);

  @override
  Future<void> save(String sourceId) =>
      _settings.set(AppSettingKeys.discoverySourceId, sourceId);
}
