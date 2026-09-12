import 'setting_key.dart';
import 'settings_registry.dart';

final class AppSettingKeys {
  static const appearanceDocument = SettingsDocumentDefinition(id: 'app-settings:settings.appearance', kind: 'settings.appearance');

  static const themeMode = SettingKey<String>(
    id: 'appearance.themeMode',
    documentKind: 'settings.appearance',
    defaultValue: 'system',
    codec: SettingCodec<String>(_stringEncode, _stringDecode),
    validator: _validateThemeMode,
  );

  static const homeLayoutMode = SettingKey<String>(
    id: 'appearance.homeLayoutMode',
    documentKind: 'settings.appearance',
    defaultValue: 'list',
    codec: SettingCodec<String>(_stringEncode, _stringDecode),
    validator: _validateHomeLayoutMode,
  );

  /// Stable local book IDs whose covers are hidden with a blur on the shelf.
  static const blurredCoverBookIds = SettingKey<List<String>>(
    id: 'appearance.blurredCoverBookIds',
    documentKind: 'settings.appearance',
    defaultValue: <String>[],
    codec: SettingCodec<List<String>>(_blurredCoverBookIdsEncode, _blurredCoverBookIdsDecode, freeze: freezeSettingList<String>),
    validator: _validateBlurredCoverBookIds,
  );
  static const searchHistoryDocument = SettingsDocumentDefinition(id: 'app-settings:settings.search', kind: 'settings.search');

  static const searchHistory = SettingKey<List<String>>(
    id: 'search.history',
    documentKind: 'settings.search',
    defaultValue: <String>[],
    codec: SettingCodec<List<String>>(_searchHistoryEncode, _searchHistoryDecode, freeze: freezeSettingList<String>),
    validator: _validateSearchHistory,
  );

  static const discoveryDocument = SettingsDocumentDefinition(id: 'app-settings:settings.discovery', kind: 'settings.discovery');

  static const discoverySourceId = SettingKey<String?>(
    id: 'discovery.sourceId',
    documentKind: 'settings.discovery',
    defaultValue: null,
    codec: SettingCodec<String?>(_nullableStringEncode, _nullableStringDecode),
    validator: _validateDiscoverySourceId,
  );

  static const discoveryPinnedSourceIds = SettingKey<List<String>>(
    id: 'discovery.pinnedSourceIds',
    documentKind: 'settings.discovery',
    defaultValue: <String>[],
    codec: SettingCodec<List<String>>(_discoveryPinnedSourceIdsEncode, _discoveryPinnedSourceIdsDecode, freeze: freezeSettingList<String>),
    validator: _validateDiscoveryPinnedSourceIds,
  );

  static const discoveryRecentSourceIds = SettingKey<List<String>>(
    id: 'discovery.recentSourceIds',
    documentKind: 'settings.discovery',
    defaultValue: <String>[],
    codec: SettingCodec<List<String>>(_discoveryRecentSourceIdsEncode, _discoveryRecentSourceIdsDecode, freeze: freezeSettingList<String>),
    validator: _validateDiscoveryRecentSourceIds,
  );

  static const profileDocument = SettingsDocumentDefinition(id: 'app-settings:settings.profile', kind: 'settings.profile');

  /// Local-only display identity for the profile summary card.
  static const profileIdentity = SettingKey<Map<String, Object?>>(
    id: 'profile.identity',
    documentKind: 'settings.profile',
    defaultValue: <String, Object?>{'displayName': '书海行者', 'motto': '书山有路勤为径，阅读点亮生活。'},
    codec: SettingCodec<Map<String, Object?>>(_profileIdentityEncode, _profileIdentityDecode, freeze: freezeJsonSettingMap),
    validator: _validateProfileIdentity,
  );

  static const diagnosticsDocument = SettingsDocumentDefinition(id: 'app-settings:settings.diagnostics', kind: 'settings.diagnostics');

  static const diagnosticsRealtimeDetailsEnabled = SettingKey<bool>(
    id: 'diagnostics.realtimeDetailsEnabled',
    documentKind: 'settings.diagnostics',
    defaultValue: false,
    codec: SettingCodec<bool>(_boolEncode, _boolDecode),
    validator: _validateBool,
  );

  /// Persistent opt-in for App diagnostics.
  ///
  /// The setting is owned by the normal settings store so reading or changing
  /// it never requires the diagnostics service itself. `false` means startup
  /// must keep the diagnostic sink silent and must not open diagnostic files.
  static const diagnosticsEnabled = SettingKey<bool>(
    id: 'diagnostics.enabled',
    documentKind: 'settings.diagnostics',
    defaultValue: false,
    codec: SettingCodec<bool>(_boolEncode, _boolDecode),
    validator: _validateBool,
  );

  /// One endpoint plus independently enabled traffic classes.
  static const networkProxyDocument = SettingsDocumentDefinition(id: 'app-settings:settings.networkProxy', kind: 'settings.networkProxy');

  static const networkProxyPreferences = SettingKey<Map<String, Object?>>(
    id: 'networkProxy.preferences',
    documentKind: 'settings.networkProxy',
    defaultValue: <String, Object?>{
      'protocol': 'http',
      'host': '127.0.0.1',
      'port': 9000,
      'forcePlayerLocalProxy': false,
      'enabled': <String, Object?>{'sourceHttp': false, 'cover': false, 'manga': false, 'video': false, 'audio': false},
    },
    codec: SettingCodec<Map<String, Object?>>(_readerPreferencesEncode, _networkProxyPreferencesDecode, freeze: freezeJsonSettingMap),
    validator: _validateNetworkProxyPreferences,
  );

  /// JSON-shaped snapshot of all host-independent text reader preferences.
  static const readerPreferencesDocument = SettingsDocumentDefinition(id: 'app-settings:settings.reader', kind: 'settings.reader');

  static const readerPreferences = SettingKey<Map<String, Object?>>(
    id: 'reader.preferences',
    documentKind: 'settings.reader',
    defaultValue: <String, Object?>{},
    codec: SettingCodec<Map<String, Object?>>(_readerPreferencesEncode, _readerPreferencesDecode, freeze: freezeJsonSettingMap),
    validator: _validateReaderPreferences,
  );

  /// Number of following novel chapters the host may load speculatively.
  ///
  /// The current chapter is not included. Zero disables speculative chapter
  /// loading, while the default of one preserves the reader's existing
  /// adjacent-chapter behavior.
  static const novelPreloadChapterCount = SettingKey<int>(
    id: 'reader.novelPreloadChapterCount',
    documentKind: 'settings.reader',
    defaultValue: 1,
    codec: SettingCodec<int>(_intEncode, _intDecode),
    validator: _validateNovelPreloadChapterCount,
  );

  static const comicReaderPreferences = SettingKey<Map<String, Object?>>(
    id: 'reader.comicPreferences',
    documentKind: 'settings.reader',
    defaultValue: <String, Object?>{},
    codec: SettingCodec<Map<String, Object?>>(_readerPreferencesEncode, _readerPreferencesDecode, freeze: freezeJsonSettingMap),
    validator: _validateReaderPreferences,
  );

  /// Host-owned behavior when the user leaves an active audio player.
  ///
  /// `ask` keeps the choice explicit, while `continue` and `stop` are durable
  /// answers selected either from the exit dialog or the profile settings UI.
  static const mediaPlaybackDocument = SettingsDocumentDefinition(
    id: 'app-settings:settings.mediaPlayback',
    kind: 'settings.mediaPlayback',
  );

  static const audioExitBehavior = SettingKey<String>(
    id: 'mediaPlayback.audioExitBehavior',
    documentKind: 'settings.mediaPlayback',
    defaultValue: 'ask',
    codec: SettingCodec<String>(_stringEncode, _stringDecode),
    validator: _validateAudioExitBehavior,
  );

  static const audioKeepScreenOn = SettingKey<bool>(
    id: 'mediaPlayback.audioKeepScreenOn',
    documentKind: 'settings.mediaPlayback',
    defaultValue: true,
    codec: SettingCodec<bool>(_boolEncode, _boolDecode),
    validator: _validateBool,
  );

  static const all = <SettingKey<dynamic>>[
    themeMode,
    homeLayoutMode,
    blurredCoverBookIds,
    searchHistory,
    discoverySourceId,
    discoveryPinnedSourceIds,
    discoveryRecentSourceIds,
    profileIdentity,
    diagnosticsEnabled,
    diagnosticsRealtimeDetailsEnabled,
    networkProxyPreferences,
    readerPreferences,
    novelPreloadChapterCount,
    comicReaderPreferences,
    audioExitBehavior,
    audioKeepScreenOn,
  ];

  static final registry = SettingsRegistry(
    keys: all,
    documents: const [
      appearanceDocument,
      searchHistoryDocument,
      discoveryDocument,
      profileDocument,
      diagnosticsDocument,
      networkProxyDocument,
      readerPreferencesDocument,
      mediaPlaybackDocument,
    ],
  );
}

Object? _stringEncode(String value) => value;
String _stringDecode(Object? value) {
  if (value is! String) throw FormatException('Expected a string setting.');
  return value;
}

Object? _intEncode(int value) => value;
int _intDecode(Object? value) {
  if (value is! int) throw FormatException('Expected an integer setting.');
  return value;
}

void _validateThemeMode(String value) {
  if (value != 'system' && value != 'light' && value != 'dark') {
    throw ArgumentError.value(value);
  }
}

void _validateHomeLayoutMode(String value) {
  if (value != 'list' && value != 'card') {
    throw ArgumentError.value(value);
  }
}

Object? _searchHistoryEncode(List<String> value) => List<String>.of(value);

List<String> _searchHistoryDecode(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Expected a string list setting.');
  }
  return <String>[for (final item in value) item as String];
}

Object? _blurredCoverBookIdsEncode(List<String> value) => List<String>.of(value);

List<String> _blurredCoverBookIdsDecode(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Expected a string list setting.');
  }
  return <String>[for (final item in value) item as String];
}

void _validateBlurredCoverBookIds(List<String> value) {
  if (value.length > 100 || value.toSet().length != value.length || value.any((item) => item.trim().isEmpty || item.length > 512)) {
    throw ArgumentError.value(value);
  }
}

void _validateSearchHistory(List<String> value) {
  if (value.length > 5 || value.any((item) => item.trim().isEmpty || item.length > 512)) {
    throw ArgumentError.value(value);
  }
}

Object? _discoveryPinnedSourceIdsEncode(List<String> value) => List<String>.of(value);

List<String> _discoveryPinnedSourceIdsDecode(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Expected a string list setting.');
  }
  return <String>[for (final item in value) item as String];
}

void _validateDiscoveryPinnedSourceIds(List<String> value) {
  if (value.length > 100 || value.toSet().length != value.length || value.any((item) => item.trim().isEmpty || item.length > 512)) {
    throw ArgumentError.value(value);
  }
}

Object? _discoveryRecentSourceIdsEncode(List<String> value) => List<String>.of(value);

List<String> _discoveryRecentSourceIdsDecode(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Expected a string list setting.');
  }
  return <String>[for (final item in value) item as String];
}

void _validateDiscoveryRecentSourceIds(List<String> value) {
  if (value.length > 20 || value.toSet().length != value.length || value.any((item) => item.trim().isEmpty || item.length > 512)) {
    throw ArgumentError.value(value);
  }
}

Object? _nullableStringEncode(String? value) => value;

String? _nullableStringDecode(Object? value) {
  if (value != null && value is! String) {
    throw FormatException('Expected a nullable string setting.');
  }
  return value as String?;
}

Object? _boolEncode(bool value) => value;

bool _boolDecode(Object? value) {
  if (value is! bool) {
    throw const FormatException('Expected a boolean setting.');
  }
  return value;
}

void _validateBool(bool value) {}

void _validateNetworkProxyPreferences(Map<String, Object?> value) {
  if (value.length != 5 ||
      value['protocol'] is! String ||
      value['host'] is! String ||
      value['port'] is! int ||
      value['forcePlayerLocalProxy'] is! bool ||
      value['enabled'] is! Map) {
    throw ArgumentError.value(value);
  }
  final protocol = value['protocol'] as String;
  final host = value['host'] as String;
  final port = value['port'] as int;
  if (protocol != 'http' && protocol != 'https' && protocol != 'socks5') {
    throw ArgumentError.value(value);
  }
  if (host.trim().isEmpty || host.length > 255 || host.contains(RegExp(r'[\\s/@]'))) {
    throw ArgumentError.value(value);
  }
  if (port < 1 || port > 65535) throw ArgumentError.value(value);
  final enabled = value['enabled'] as Map<Object?, Object?>;
  const expected = <String>{'sourceHttp', 'cover', 'manga', 'video', 'audio'};
  if (enabled.length != expected.length || !enabled.keys.every(expected.contains) || enabled.values.any((item) => item is! bool)) {
    throw ArgumentError.value(value);
  }
}

Map<String, Object?> _networkProxyPreferencesDecode(Object? value) {
  final decoded = _readerPreferencesDecode(value);
  final normalized = <String, Object?>{...decoded, if (!decoded.containsKey('forcePlayerLocalProxy')) 'forcePlayerLocalProxy': false}
    ..remove('useEnvironmentProxy');
  final enabled = normalized['enabled'];
  if (enabled is! Map) return normalized;
  const currentKeys = <String>{'sourceHttp', 'cover', 'manga', 'video', 'audio'};
  if (enabled.length == currentKeys.length && enabled.keys.every(currentKeys.contains)) return normalized;
  const historicalKeySets = <Set<String>>[
    <String>{'sourceHttp', 'cover', 'manga'},
    <String>{'runtime', 'sourceHttp', 'cover', 'manga', 'video', 'audio'},
    <String>{'runtime', 'cover', 'manga', 'video', 'audio'},
    <String>{'runtime', 'manga', 'video', 'audio'},
    <String>{'source', 'novel', 'manga', 'video', 'audio'},
  ];
  final recognized = historicalKeySets.any((keys) => enabled.length == keys.length && enabled.keys.every(keys.contains));
  if (!recognized || enabled.values.any((item) => item is! bool)) {
    return normalized;
  }
  return <String, Object?>{
    ...normalized,
    'enabled': <String, Object?>{
      'sourceHttp': enabled['sourceHttp'] as bool? ?? false,
      'cover': enabled['cover'] as bool? ?? false,
      'manga': enabled['manga'] as bool,
      'video': enabled['video'] as bool? ?? false,
      'audio': enabled['audio'] as bool? ?? false,
    },
  };
}

Object? _readerPreferencesEncode(Map<String, Object?> value) => value;

Map<String, Object?> _readerPreferencesDecode(Object? value) {
  if (value is! Map) {
    throw const FormatException('Expected a reader preferences object.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('Reader preference keys must be strings.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

void _validateReaderPreferences(Map<String, Object?> value) {
  if (value.length > 32) throw ArgumentError.value(value);
}

void _validateNovelPreloadChapterCount(int value) {
  if (value < 0 || value > 5) throw ArgumentError.value(value);
}

void _validateAudioExitBehavior(String value) {
  if (value != 'ask' && value != 'continue' && value != 'stop') {
    throw ArgumentError.value(value);
  }
}

void _validateDiscoverySourceId(String? value) {
  if (value != null && (value.trim().isEmpty || value.length > 512)) {
    throw ArgumentError.value(value);
  }
}

Object? _profileIdentityEncode(Map<String, Object?> value) => value;

Map<String, Object?> _profileIdentityDecode(Object? value) {
  if (value is! Map) {
    throw const FormatException('Expected a profile identity map.');
  }
  if (value.length != 2 || value['displayName'] is! String || value['motto'] is! String) {
    throw const FormatException('Invalid profile identity fields.');
  }
  return <String, Object?>{'displayName': value['displayName'] as String, 'motto': value['motto'] as String};
}

void _validateProfileIdentity(Map<String, Object?> value) {
  if (value.length != 2) throw ArgumentError.value(value);
  final displayName = value['displayName'];
  final motto = value['motto'];
  if (displayName is! String ||
      displayName.trim().isEmpty ||
      displayName.length > 20 ||
      motto is! String ||
      motto.trim().isEmpty ||
      motto.length > 50) {
    throw ArgumentError.value(value);
  }
}
