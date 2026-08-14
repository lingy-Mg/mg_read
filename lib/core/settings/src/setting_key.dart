import 'dart:collection';

typedef SettingEncoder<T> = Object? Function(T value);
typedef SettingDecoder<T> = T Function(Object? value);
typedef SettingValidator<T> = void Function(T value);
typedef SettingFreezer<T> = T Function(T value);

final class SettingCodec<T> {
  const SettingCodec(this.encode, this.decode, {this.freeze});

  final SettingEncoder<T> encode;
  final SettingDecoder<T> decode;
  final SettingFreezer<T>? freeze;
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

  Object? encodeValue(Object? value) =>
      freezeSettingsJsonValue(codec.encode(value as T));
  T decodeValue(Object? value) => codec.decode(freezeSettingsJsonValue(value));
  void validateValue(Object? value) => validator(value as T);

  T freezeValue(Object? value) {
    final typed = value as T;
    final freezer = codec.freeze;
    if (freezer == null) {
      if (typed != null &&
          typed is! String &&
          typed is! num &&
          typed is! bool &&
          typed is! Enum) {
        throw ArgumentError(
          'Non-scalar setting $id must register a typed freezer.',
        );
      }
      return typed;
    }
    return freezer(typed);
  }
}

final class SettingsSnapshot {
  SettingsSnapshot._(this._groups, this._defaults);

  factory SettingsSnapshot.empty() => SettingsSnapshot._(
    const <String, Map<String, Object?>>{},
    const <String, Object?>{},
  );

  factory SettingsSnapshot.withDefaults(Map<String, Object?> defaults) =>
      SettingsSnapshot._(
        const <String, Map<String, Object?>>{},
        UnmodifiableMapView(Map<String, Object?>.of(defaults)),
      );

  final Map<String, Map<String, Object?>> _groups;
  final Map<String, Object?> _defaults;

  T get<T>(SettingKey<T> key) {
    final group = _groups[key.documentKind];
    if (group == null || !group.containsKey(key.id)) {
      if (_defaults.containsKey(key.id)) {
        return _defaults[key.id] as T;
      }
      return key.freezeValue(key.defaultValue);
    }
    return group[key.id] as T;
  }

  bool contains(SettingKey<dynamic> key) =>
      _groups[key.documentKind]?.containsKey(key.id) ?? false;

  SettingsSnapshot replaceGroups(
    Map<String, Map<String, Object?>> replacements,
  ) {
    if (replacements.isEmpty) {
      return this;
    }
    return SettingsSnapshot._(
      UnmodifiableMapView({
        ..._groups,
        for (final replacement in replacements.entries)
          replacement.key: _freezeSettingsGroup(replacement.value),
      }),
      _defaults,
    );
  }
}

Map<String, Object?> _freezeSettingsGroup(Map<String, Object?> values) =>
    UnmodifiableMapView(Map<String, Object?>.of(values));

/// Makes JSON-shaped setting values safe to retain in a memory snapshot.
///
/// Maps and lists are copied recursively before becoming unmodifiable, so a
/// caller cannot mutate a setting without going through [AppSettingsManager].
Object? freezeSettingsJsonValue(Object? value) {
  if (value is Map) {
    final frozen = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError('Setting object keys must be strings.');
      }
      frozen[entry.key as String] = freezeSettingsJsonValue(entry.value);
    }
    return UnmodifiableMapView<String, dynamic>(frozen);
  }
  if (value is List) {
    return UnmodifiableListView<dynamic>([
      for (final child in value) freezeSettingsJsonValue(child),
    ]);
  }
  return value;
}

/// Copies a JSON-shaped value into plain sendable maps and lists.
Object? copySettingsJsonValue(Object? value) {
  if (value is Map) {
    final copy = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError('Setting object keys must be strings.');
      }
      copy[entry.key as String] = copySettingsJsonValue(entry.value);
    }
    return copy;
  }
  if (value is List) {
    return <Object?>[for (final child in value) copySettingsJsonValue(child)];
  }
  return value;
}

/// A type-preserving immutable copy for list-valued setting codecs.
List<T> freezeSettingList<T>(List<T> value) =>
    UnmodifiableListView<T>(List<T>.of(value, growable: false));

/// A type-preserving immutable copy for map-valued setting codecs.
Map<String, T> freezeSettingMap<T>(Map<String, T> value) =>
    UnmodifiableMapView<String, T>(Map<String, T>.of(value));

/// A recursively immutable copy for JSON object-valued setting codecs.
Map<String, Object?> freezeJsonSettingMap(Map<String, Object?> value) =>
    freezeSettingsJsonValue(value) as Map<String, Object?>;
