import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/settings/settings.dart';

/// The narrow persistence boundary used by the search page.
abstract interface class SearchHistoryStore {
  Future<List<String>> load();

  Future<void> save(List<String> history);
}

final searchHistoryStoreProvider = Provider<SearchHistoryStore>((ref) {
  return AppSettingsSearchHistoryStore(ref.watch(appSettingsProvider));
});

/// Adapts the app-owned, debounced settings manager to the discovery feature.
final class AppSettingsSearchHistoryStore implements SearchHistoryStore {
  const AppSettingsSearchHistoryStore(this._settings);

  final AppSettingsManager _settings;

  @override
  Future<List<String>> load() async =>
      List<String>.of(_settings.get(AppSettingKeys.searchHistory));

  @override
  Future<void> save(List<String> history) =>
      _settings.set(AppSettingKeys.searchHistory, List<String>.of(history));
}
