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
  static const all = <SettingKey<dynamic>>[themeMode];

  static final registry = SettingsRegistry(
    keys: all,
    documents: const [appearanceDocument],
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
