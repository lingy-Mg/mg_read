part of 'app_settings_manager.dart';

final class SettingsTransaction {
  SettingsTransaction._(this._registry);

  final SettingsRegistry _registry;
  final List<_SettingsMutation> _operations = [];

  void set<T>(SettingKey<T> key, T value) {
    final registered = _requireRegisteredKey(key);
    registered.validateValue(value);
    final encoded = registered.encodeValue(value);
    validateSettingsEncodedValue(encoded);
    final canonicalValue = registered.decodeValue(encoded);
    registered.validateValue(canonicalValue);
    _operations.add(_SetMutation(registered, registered.freezeValue(canonicalValue), encoded));
  }

  void reset<T>(SettingKey<T> key) {
    final registered = _requireRegisteredKey(key);
    _operations.add(_ResetMutation(registered));
  }

  void resetGroup(String kind) {
    _registry.requireDocument(kind);
    _operations.add(_ResetGroupMutation(kind));
  }

  SettingKey<T> _requireRegisteredKey<T>(SettingKey<T> key) {
    final registered = _registry.requireKey(key.id);
    if (!identical(registered, key)) {
      throw ArgumentError.value(key.id, 'key', 'Use the registered key.');
    }
    return registered as SettingKey<T>;
  }
}

final class _RuntimeDocument {
  _RuntimeDocument(this.definition);

  final SettingsDocumentDefinition definition;
  Map<String, Object?> persistedValues = {};
  Map<String, Object?> values = {};
  Map<String, Object?> decodedValues = {};
  Map<String, _PatchValue> patch = {};
  int? revision;
  int generation = 0;
  int persistedGeneration = 0;
  int retryCount = 0;
  bool inFlight = false;
  String? permanentErrorCode;
  String? transientErrorCode;
  Timer? timer;

  bool get dirty => patch.isNotEmpty;
  bool get persisted => !dirty && !inFlight;
  bool get readOnly => permanentErrorCode != null;
  bool get degraded => permanentErrorCode != null || transientErrorCode != null;
  String? get lastErrorCode => permanentErrorCode ?? transientErrorCode;
}

sealed class _SettingsMutation {
  _SettingsMutation(this.documentKind);
  final String documentKind;
}

final class _SetMutation extends _SettingsMutation {
  _SetMutation(this.key, this.value, this.encoded) : super(key.documentKind);
  final SettingKey<dynamic> key;
  final Object? value;
  final Object? encoded;
}

final class _ResetMutation extends _SettingsMutation {
  _ResetMutation(this.key) : super(key.documentKind);
  final SettingKey<dynamic> key;
}

final class _ResetGroupMutation extends _SettingsMutation {
  _ResetGroupMutation(super.documentKind);
}

final class _PatchValue {
  const _PatchValue.present(this.value) : isPresent = true;
  const _PatchValue.absent() : isPresent = false, value = null;
  final bool isPresent;
  final Object? value;
}

final class _WriteCapture {
  const _WriteCapture({required this.document, required this.generation, required this.revision, required this.values});
  final _RuntimeDocument document;
  final int generation;
  final int? revision;
  final Map<String, Object?> values;
}

Map<String, _PatchValue> _buildPatch(Map<String, Object?> base, Map<String, Object?> current, Iterable<SettingKey<dynamic>> keys) {
  final patch = <String, _PatchValue>{};
  for (final key in keys) {
    if (_presenceAndValueEqual(base, current, key.id)) {
      continue;
    }
    patch[key.id] = current.containsKey(key.id) ? _PatchValue.present(current[key.id]) : const _PatchValue.absent();
  }
  return patch;
}

Map<String, Object?> _applyPatch(Map<String, Object?> base, Map<String, _PatchValue> patch) {
  final merged = Map<String, Object?>.of(base);
  for (final entry in patch.entries) {
    if (entry.value.isPresent) {
      merged[entry.key] = entry.value.value;
    } else {
      merged.remove(entry.key);
    }
  }
  return merged;
}

bool _presenceAndValueEqual(Map<String, Object?> left, Map<String, Object?> right, String key) {
  final leftContains = left.containsKey(key);
  final rightContains = right.containsKey(key);
  return leftContains == rightContains && (!leftContains || _jsonEquals(left[key], right[key]));
}

bool _jsonEquals(Object? left, Object? right) {
  if (identical(left, right) || left == right) {
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (!_jsonEquals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) || !_jsonEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return false;
}

DateTime _utcNow() => DateTime.now().toUtc();
