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

  /// One credential-free endpoint plus independently enabled traffic classes.
  static const networkProxyDocument = SettingsDocumentDefinition(id: 'app-settings:settings.networkProxy', kind: 'settings.networkProxy');

  static const networkProxyPreferences = SettingKey<Map<String, Object?>>(
    id: 'networkProxy.preferences',
    documentKind: 'settings.networkProxy',
    defaultValue: <String, Object?>{
      'protocol': 'http',
      'host': '127.0.0.1',
      'port': 9000,
      'enabled': <String, Object?>{'source': false, 'novel': false, 'manga': false, 'video': false, 'audio': false},
    },
    codec: SettingCodec<Map<String, Object?>>(_readerPreferencesEncode, _readerPreferencesDecode, freeze: freezeJsonSettingMap),
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

  static const comicReaderPreferences = SettingKey<Map<String, Object?>>(
    id: 'reader.comicPreferences',
    documentKind: 'settings.reader',
    defaultValue: <String, Object?>{},
    codec: SettingCodec<Map<String, Object?>>(_readerPreferencesEncode, _readerPreferencesDecode, freeze: freezeJsonSettingMap),
    validator: _validateReaderPreferences,
  );

  static const all = <SettingKey<dynamic>>[
    themeMode,
    homeLayoutMode,
    searchHistory,
    discoverySourceId,
    diagnosticsEnabled,
    diagnosticsRealtimeDetailsEnabled,
    networkProxyPreferences,
    readerPreferences,
    comicReaderPreferences,
  ];

  static final registry = SettingsRegistry(
    keys: all,
    documents: const [
      appearanceDocument,
      searchHistoryDocument,
      discoveryDocument,
      diagnosticsDocument,
      networkProxyDocument,
      readerPreferencesDocument,
    ],
  );
}

Object? _stringEncode(String value) => value;
String _stringDecode(Object? value) {
  if (value is! String) throw FormatException('Expected a string setting.');
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

void _validateSearchHistory(List<String> value) {
  if (value.length > 5 || value.any((item) => item.trim().isEmpty || item.length > 512)) {
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
  if (value.length != 4 || value['protocol'] is! String || value['host'] is! String || value['port'] is! int || value['enabled'] is! Map) {
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
  const expected = <String>{'source', 'novel', 'manga', 'video', 'audio'};
  if (enabled.length != expected.length || !enabled.keys.every(expected.contains) || enabled.values.any((item) => item is! bool)) {
    throw ArgumentError.value(value);
  }
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

void _validateDiscoverySourceId(String? value) {
  if (value != null && (value.trim().isEmpty || value.length > 512)) {
    throw ArgumentError.value(value);
  }
}
