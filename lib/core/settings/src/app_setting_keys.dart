import 'setting_key.dart';
import 'settings_registry.dart';

final class AppSettingKeys {
  static const appearanceDocument = SettingsDocumentDefinition(
    id: 'app-settings:settings.appearance',
    kind: 'settings.appearance',
  );

  static const themeMode = SettingKey<String>(
    id: 'appearance.themeMode',
    documentKind: 'settings.appearance',
    defaultValue: 'system',
    codec: SettingCodec<String>(_stringEncode, _stringDecode),
    validator: _validateThemeMode,
  );
  static const searchHistoryDocument = SettingsDocumentDefinition(
    id: 'app-settings:settings.search',
    kind: 'settings.search',
  );

  static const searchHistory = SettingKey<List<String>>(
    id: 'search.history',
    documentKind: 'settings.search',
    defaultValue: <String>[],
    codec: SettingCodec<List<String>>(
      _searchHistoryEncode,
      _searchHistoryDecode,
      freeze: freezeSettingList<String>,
    ),
    validator: _validateSearchHistory,
  );

  static const discoveryDocument = SettingsDocumentDefinition(
    id: 'app-settings:settings.discovery',
    kind: 'settings.discovery',
  );

  static const discoverySourceId = SettingKey<String?>(
    id: 'discovery.sourceId',
    documentKind: 'settings.discovery',
    defaultValue: null,
    codec: SettingCodec<String?>(_nullableStringEncode, _nullableStringDecode),
    validator: _validateDiscoverySourceId,
  );

  static const all = <SettingKey<dynamic>>[
    themeMode,
    searchHistory,
    discoverySourceId,
  ];

  static final registry = SettingsRegistry(
    keys: all,
    documents: const [
      appearanceDocument,
      searchHistoryDocument,
      discoveryDocument,
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

Object? _searchHistoryEncode(List<String> value) => List<String>.of(value);

List<String> _searchHistoryDecode(Object? value) {
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('Expected a string list setting.');
  }
  return <String>[for (final item in value) item as String];
}

void _validateSearchHistory(List<String> value) {
  if (value.length > 5 ||
      value.any((item) => item.trim().isEmpty || item.length > 512)) {
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

void _validateDiscoverySourceId(String? value) {
  if (value != null && (value.trim().isEmpty || value.length > 512)) {
    throw ArgumentError.value(value);
  }
}
