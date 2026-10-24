import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/settings/settings.dart';

/// The narrow persistence boundary for discovery source selection and pinning.
/// A missing selected value means that discovery should use its first source.
abstract interface class DiscoverySourceSelectionStore {
  Future<String?> load();

  Future<void> save(String sourceId);

  Future<List<String>> loadPinned();

  Future<void> setPinned(String sourceId, {required bool pinned});
}

final discoverySourceSelectionStoreProvider = Provider<DiscoverySourceSelectionStore>((ref) {
  return AppSettingsDiscoverySourceSelectionStore(ref.watch(appSettingsProvider));
});

/// Adapts the app-owned, debounced settings manager to the discovery feature.
final class AppSettingsDiscoverySourceSelectionStore implements DiscoverySourceSelectionStore {
  const AppSettingsDiscoverySourceSelectionStore(this._settings);

  final AppSettingsManager _settings;

  @override
  Future<String?> load() async => _settings.get(AppSettingKeys.discoverySourceId);

  @override
  Future<void> save(String sourceId) => _settings.set(AppSettingKeys.discoverySourceId, sourceId);

  @override
  Future<List<String>> loadPinned() async => List<String>.of(_settings.get(AppSettingKeys.discoveryPinnedSourceIds));

  @override
  Future<void> setPinned(String sourceId, {required bool pinned}) async {
    final next = List<String>.of(_settings.get(AppSettingKeys.discoveryPinnedSourceIds))..remove(sourceId);
    if (pinned) next.insert(0, sourceId);
    await _settings.set(AppSettingKeys.discoveryPinnedSourceIds, next);
  }
}
