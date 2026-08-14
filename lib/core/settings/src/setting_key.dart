typedef SettingEncoder<T> = Object? Function(T value);
typedef SettingDecoder<T> = T Function(Object? value);
typedef SettingValidator<T> = void Function(T value);

final class SettingCodec<T> {
  const SettingCodec(this.encode, this.decode);
  final SettingEncoder<T> encode;
  final SettingDecoder<T> decode;
}

final class SettingKey<T> {
  const SettingKey({
    required this.id,
    required this.documentKind,
    required this.defaultValue,
    required this.codec,
    required this.validator,
  });
  final String id;
  final String documentKind;
  final T defaultValue;
  final SettingCodec<T> codec;
  final SettingValidator<T> validator;
  Object? encodeValue(Object? value) => codec.encode(value as T);
  T decodeValue(Object? value) => codec.decode(value);
  void validateValue(Object? value) => validator(value as T);
}

final class SettingsSnapshot {
  SettingsSnapshot(Map<String, Object?> values)
    : _values = Map.unmodifiable(values);
  final Map<String, Object?> _values;
  T get<T>(SettingKey<T> key) => (_values[key.id] as T?) ?? key.defaultValue;
}

enum SettingsState { loading, ready, degraded, failed, closing, closed }
