import 'dart:convert';
import 'dart:isolate';

import 'persistence_error.dart';
import 'record.dart';

typedef JsonValidator = void Function(JsonObject document);
typedef JsonUpgrader = JsonObject Function(JsonObject document);

final class JsonDocumentLimits {
  const JsonDocumentLimits({
    this.maxEncodedBytes = 256 * 1024,
    this.maxDepth = 24,
    this.maxKeys = 2048,
    this.maxNodes = 8192,
    this.maxArrayLength = 2048,
    this.maxStringLength = 32768,
    this.forbiddenKeyTokens = const <String>{},
  });

  final int maxEncodedBytes;
  final int maxDepth;
  final int maxKeys;
  final int maxNodes;
  final int maxArrayLength;
  final int maxStringLength;
  final Set<String> forbiddenKeyTokens;
}

final class PreparedJsonDocument {
  const PreparedJsonDocument({
    required this.document,
    required this.payloadJson,
    required this.workerIsolateId,
  });

  final JsonObject document;
  final String payloadJson;
  final int workerIsolateId;
}

final class RecordDocumentCodec {
  RecordDocumentCodec({
    required this.recordKind,
    required this.scopeKind,
    required this.currentVersion,
    required Map<int, JsonValidator> validators,
    Map<int, JsonUpgrader> upgraders = const {},
    this.limits = const JsonDocumentLimits(),
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
  final JsonDocumentLimits limits;
  final Map<int, JsonValidator> _validators;
  final Map<int, JsonUpgrader> _upgraders;

  Future<PreparedJsonDocument> prepareCurrent(JsonObject document) async {
    final prepared = await Isolate.run(
      () => _normalizeAndEncode(document, limits),
      debugName: 'mg-read-json-encode',
    );
    final frozen = freezeJsonObject(prepared.document);
    _validators[currentVersion]!(frozen);
    return PreparedJsonDocument(
      document: frozen,
      payloadJson: prepared.payloadJson,
      workerIsolateId: prepared.workerIsolateId,
    );
  }

  Future<PreparedJsonDocument> decodeAndUpgrade({
    required int version,
    required String payloadJson,
  }) async => (await decodeAndUpgradeMany(
    documents: <({int version, String payloadJson})>[
      (version: version, payloadJson: payloadJson),
    ],
  )).single;

  /// Decodes records with this codec in one background isolate invocation.
  ///
  /// List and catalog queries commonly return many small metadata documents.
  /// Starting one isolate per row makes their latency cumulative even though
  /// no document is individually expensive. Version upgrades and validation
  /// retain the same per-document behavior as [decodeAndUpgrade].
  Future<List<PreparedJsonDocument>> decodeAndUpgradeMany({
    required Iterable<({int version, String payloadJson})> documents,
  }) async {
    final requested = List<({int version, String payloadJson})>.of(documents);
    for (final document in requested) {
      if (document.version > currentVersion) {
        throw const PersistenceFutureVersionError();
      }
    }
    if (requested.isEmpty) return const <PreparedJsonDocument>[];
    final normalizedDocuments = await Isolate.run(
      () => _decodeAndNormalizeMany(
        requested
            .map((document) => document.payloadJson)
            .toList(growable: false),
        limits,
      ),
      debugName: 'mg-read-json-decode-batch',
    );
    final prepared = <PreparedJsonDocument>[];
    for (var index = 0; index < requested.length; index++) {
      prepared.add(
        await _upgradeNormalized(
          version: requested[index].version,
          normalized: normalizedDocuments[index],
        ),
      );
    }
    return List<PreparedJsonDocument>.unmodifiable(prepared);
  }

  Future<PreparedJsonDocument> _upgradeNormalized({
    required int version,
    required _NormalizedJson normalized,
  }) async {
    var working = normalized.document;
    var cursor = version;
    while (cursor < currentVersion) {
      _validators[cursor]?.call(freezeJsonObject(working));
      final JsonUpgrader? upgrader = _upgraders[cursor];
      if (upgrader == null) {
        throw const PersistenceCorruptionError();
      }
      final upgraded = upgrader(freezeJsonObject(working));
      normalized = await Isolate.run(
        () => _normalizeAndEncode(upgraded, limits),
        debugName: 'mg-read-json-upgrade',
      );
      working = normalized.document;
      cursor++;
    }
    final frozen = freezeJsonObject(working);
    _validators[currentVersion]!(frozen);
    return PreparedJsonDocument(
      document: frozen,
      payloadJson: normalized.payloadJson,
      workerIsolateId: normalized.workerIsolateId,
    );
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

final class _NormalizedJson {
  const _NormalizedJson({
    required this.document,
    required this.payloadJson,
    required this.workerIsolateId,
  });

  final JsonObject document;
  final String payloadJson;
  final int workerIsolateId;
}

_NormalizedJson _decodeAndNormalize(
  String payloadJson,
  JsonDocumentLimits limits,
) {
  if (utf8.encode(payloadJson).length > limits.maxEncodedBytes) {
    throw const PersistenceCorruptionError();
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(payloadJson);
  } on FormatException {
    throw const PersistenceCorruptionError();
  }
  if (decoded is! Map) {
    throw const PersistenceCorruptionError();
  }
  final document = _copyObject(decoded);
  _validateJsonShape(document, limits, corruption: true);
  return _NormalizedJson(
    document: document,
    payloadJson: payloadJson,
    workerIsolateId: Isolate.current.hashCode,
  );
}

List<_NormalizedJson> _decodeAndNormalizeMany(
  List<String> payloads,
  JsonDocumentLimits limits,
) => payloads
    .map((payloadJson) => _decodeAndNormalize(payloadJson, limits))
    .toList(growable: false);

_NormalizedJson _normalizeAndEncode(
  JsonObject document,
  JsonDocumentLimits limits,
) {
  final copy = _copyObject(document);
  _validateJsonShape(copy, limits, corruption: false);
  final payload = jsonEncode(copy);
  if (utf8.encode(payload).length > limits.maxEncodedBytes) {
    throw PersistenceValidationError(
      'JSON document exceeds ${limits.maxEncodedBytes} encoded bytes.',
    );
  }
  return _NormalizedJson(
    document: copy,
    payloadJson: payload,
    workerIsolateId: Isolate.current.hashCode,
  );
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

void _validateJsonShape(
  JsonObject document,
  JsonDocumentLimits limits, {
  required bool corruption,
}) {
  var keys = 0;
  var nodes = 0;

  Never reject(String message) {
    if (corruption) {
      throw const PersistenceCorruptionError();
    }
    throw PersistenceValidationError(message);
  }

  void visit(Object? value, int depth) {
    nodes++;
    if (nodes > limits.maxNodes) {
      reject('JSON node count exceeds ${limits.maxNodes}.');
    }
    if (depth > limits.maxDepth) {
      reject('JSON nesting exceeds ${limits.maxDepth} levels.');
    }
    if (value is String && value.length > limits.maxStringLength) {
      reject('JSON string exceeds ${limits.maxStringLength} characters.');
    }
    if (value is Map) {
      keys += value.length;
      if (keys > limits.maxKeys) {
        reject('JSON key count exceeds ${limits.maxKeys}.');
      }
      for (final entry in value.entries) {
        if (_containsForbiddenToken(
          entry.key as String,
          limits.forbiddenKeyTokens,
        )) {
          reject('JSON contains a forbidden key category.');
        }
        visit(entry.value, depth + 1);
      }
    } else if (value is List) {
      if (value.length > limits.maxArrayLength) {
        reject('JSON array exceeds ${limits.maxArrayLength} entries.');
      }
      for (final child in value) {
        visit(child, depth + 1);
      }
    }
  }

  visit(document, 0);
}

bool _containsForbiddenToken(String key, Set<String> forbidden) {
  if (forbidden.isEmpty) {
    return false;
  }
  final separated = key.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match[1]}.${match[2]}',
  );
  final tokens = separated
      .toLowerCase()
      .split(RegExp('[^a-z0-9]+'))
      .where((token) => token.isNotEmpty);
  return tokens.any(forbidden.contains);
}
