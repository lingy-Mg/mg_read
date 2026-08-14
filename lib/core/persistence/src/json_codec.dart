import 'dart:convert';

import 'persistence_error.dart';
import 'record.dart';

typedef JsonValidator = void Function(JsonObject document);
typedef JsonUpgrader = JsonObject Function(JsonObject document);

final class RecordDocumentCodec {
  RecordDocumentCodec({
    required this.recordKind,
    required this.scopeKind,
    required this.currentVersion,
    required Map<int, JsonValidator> validators,
    Map<int, JsonUpgrader> upgraders = const {},
  }) : _validators = Map.unmodifiable(validators),
       _upgraders = Map.unmodifiable(upgraders) {
    if (currentVersion < 1 || !_validators.containsKey(currentVersion)) {
      throw ArgumentError.value(
        currentVersion,
        'currentVersion',
        'must have a validator',
      );
    }
  }

  final String recordKind;
  final String scopeKind;
  final int currentVersion;
  final Map<int, JsonValidator> _validators;
  final Map<int, JsonUpgrader> _upgraders;

  JsonObject decodeAndUpgrade({
    required int version,
    required String payloadJson,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(payloadJson);
    } on FormatException {
      throw const PersistenceCorruptionError();
    }
    if (decoded is! Map) throw const PersistenceCorruptionError();
    final document = _copyObject(decoded);
    return upgrade(version: version, document: document);
  }

  JsonObject validateCurrent(JsonObject document) {
    _validateJsonShape(document);
    final copy = _copyObject(document);
    _validators[currentVersion]!(copy);
    return freezeJsonObject(copy);
  }

  JsonObject upgrade({required int version, required JsonObject document}) {
    if (version > currentVersion) throw const PersistenceFutureVersionError();
    var working = _copyObject(document);
    var cursor = version;
    while (cursor < currentVersion) {
      _validators[cursor]?.call(working);
      final JsonUpgrader? upgrader = _upgraders[cursor];
      if (upgrader == null) throw const PersistenceCorruptionError();
      working = _copyObject(upgrader(working));
      cursor++;
    }
    return validateCurrent(working);
  }
}

final class RecordDocumentRegistry {
  RecordDocumentRegistry(Iterable<RecordDocumentCodec> codecs)
    : _codecs = {
        for (final codec in codecs) (codec.recordKind, codec.scopeKind): codec,
      } {
    if (_codecs.length != codecs.length) {
      throw ArgumentError('Duplicate record document codec.');
    }
  }

  final Map<(String, String), RecordDocumentCodec> _codecs;

  RecordDocumentCodec require(String recordKind, String scopeKind) {
    final codec = _codecs[(recordKind, scopeKind)];
    if (codec == null) {
      throw PersistenceValidationError(
        'No document codec is registered for $recordKind/$scopeKind.',
      );
    }
    return codec;
  }
}

JsonObject _copyObject(Object? value) {
  if (value is! Map) {
    throw const PersistenceCorruptionError();
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const PersistenceCorruptionError();
    }
    result[entry.key as String] = _copyJson(entry.value);
  }
  return result;
}

Object? _copyJson(Object? value) {
  if (value is Map) {
    return _copyObject(value);
  }
  if (value is List) {
    return value.map(_copyJson).toList(growable: false);
  }
  if (value is String ||
      value is bool ||
      value == null ||
      value is num && value.isFinite) {
    return value;
  }
  throw const PersistenceValidationError(
    'The document contains a non-JSON value.',
  );
}

void _validateJsonShape(JsonObject document) => _copyObject(document);
