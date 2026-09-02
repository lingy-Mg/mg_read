/// Versioned JSON preparation for app-owned metadata records.
///
/// Responsibilities:
/// - Normalize, bound, encode, freeze, validate, and upgrade JSON documents.
/// - Keep large or structurally complex work off the calling isolate.
/// - Allow explicitly opted-in business codecs to prepare proven-small writes
///   inline without weakening persistence validation or error semantics.
///
/// Callers must not bypass this boundary with pre-encoded JSON strings.
library;

import 'dart:convert';
import 'dart:isolate';

import 'persistence_error.dart';
import 'record.dart';

typedef JsonValidator = void Function(JsonObject document);
typedef JsonUpgrader = JsonObject Function(JsonObject document);

// Metadata documents are deliberately small. Sending a tiny document through
// a freshly spawned isolate can cost orders of magnitude more than parsing it,
// especially on Windows debug builds. These limits bound inline work to at
// most 48 KiB of UTF-8 source text (Chinese text uses at most three bytes per
// Dart code unit). Larger documents retain the background-isolate path.
const _maximumInlineDocumentCodeUnits = 4 * 1024;
const _maximumInlineBatchCodeUnits = 16 * 1024;

/// A business-owned opt-in for bounded write preparation on the caller.
///
/// This is deliberately structural rather than a single encoded-byte cutoff.
/// The preflight stops as soon as any bound is crossed, so deciding to fall
/// back to a worker cannot itself traverse an unbounded document on the UI
/// isolate. Full normalization and [JsonDocumentLimits] validation still run
/// on the execution path selected after preflight.
final class JsonInlinePreparationPolicy {
  const JsonInlinePreparationPolicy({
    this.maxDocuments = 4,
    this.maxTotalNodes = 256,
    this.maxDepth = 8,
    this.maxCollectionLength = 64,
    this.maxTotalTextCodeUnits = 8 * 1024,
  }) : assert(maxDocuments > 0),
       assert(maxTotalNodes > 0),
       assert(maxDepth > 0),
       assert(maxCollectionLength > 0),
       assert(maxTotalTextCodeUnits > 0);

  final int maxDocuments;
  final int maxTotalNodes;
  final int maxDepth;
  final int maxCollectionLength;
  final int maxTotalTextCodeUnits;
}

final class JsonDocumentLimits {
  const JsonDocumentLimits({
    this.maxEncodedBytes = 256 * 1024,
    this.maxDepth = 24,
    this.maxKeys = 2048,
    this.maxNodes = 8192,
    this.maxArrayLength = 2048,
    this.maxStringLength = 32768,
  });

  final int maxEncodedBytes;
  final int maxDepth;
  final int maxKeys;
  final int maxNodes;
  final int maxArrayLength;
  final int maxStringLength;
}

final class PreparedJsonDocument {
  const PreparedJsonDocument({required this.document, required this.payloadJson, required this.workerIsolateId});

  final JsonObject document;
  final String payloadJson;

  /// The isolate that normalized and encoded this document.
  ///
  /// It equals the caller isolate for bounded inline preparation and differs
  /// for background preparation.
  int get executionIsolateId => workerIsolateId;

  /// Historical compatibility name. This value is not necessarily a worker.
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
    this.inlinePreparationPolicy,
  }) : _validators = Map.unmodifiable(validators),
       _upgraders = Map.unmodifiable(upgraders) {
    if (currentVersion < 1 || !_validators.containsKey(currentVersion)) {
      throw ArgumentError.value(currentVersion, 'currentVersion', 'must have a validator');
    }
  }

  final String recordKind;
  final String scopeKind;
  final int currentVersion;
  final JsonDocumentLimits limits;
  final JsonInlinePreparationPolicy? inlinePreparationPolicy;
  final Map<int, JsonValidator> _validators;
  final Map<int, JsonUpgrader> _upgraders;

  Future<PreparedJsonDocument> prepareCurrent(JsonObject document) async {
    final prepared = _canPrepareInline(<JsonObject>[document], <RecordDocumentCodec>[this])
        ? _normalizeAndEncode(document, limits)
        : await Isolate.run(() => _normalizeAndEncode(document, limits), debugName: 'mg-read-json-encode');
    final frozen = freezeJsonObject(prepared.document);
    _validators[currentVersion]!(frozen);
    return PreparedJsonDocument(document: frozen, payloadJson: prepared.payloadJson, workerIsolateId: prepared.workerIsolateId);
  }

  /// Prepares a write batch with one encode pass.
  ///
  /// Catalog snapshots contain many small documents. Preparing each document
  /// through [prepareCurrent] starts one isolate for every row, which makes a
  /// large catalog pay the isolate startup cost repeatedly. Keep the batch
  /// boundary owned by the record store, but encode all documents in that
  /// boundary together.
  Future<List<PreparedJsonDocument>> prepareCurrentMany({required Iterable<JsonObject> documents}) async {
    final requested = List<JsonObject>.of(documents);
    if (requested.isEmpty) return const <PreparedJsonDocument>[];
    final normalizedDocuments = _canPrepareInline(requested, <RecordDocumentCodec>[this])
        ? _normalizeAndEncodeMany(requested, limits)
        : await Isolate.run(() => _normalizeAndEncodeMany(requested, limits), debugName: 'mg-read-json-encode-batch');
    return List<PreparedJsonDocument>.unmodifiable(
      List<PreparedJsonDocument>.generate(normalizedDocuments.length, (index) {
        final prepared = normalizedDocuments[index];
        final frozen = freezeJsonObject(prepared.document);
        _validators[currentVersion]!(frozen);
        return PreparedJsonDocument(document: frozen, payloadJson: prepared.payloadJson, workerIsolateId: prepared.workerIsolateId);
      }),
    );
  }

  Future<PreparedJsonDocument> decodeAndUpgrade({required int version, required String payloadJson}) async =>
      (await decodeAndUpgradeMany(documents: <({int version, String payloadJson})>[(version: version, payloadJson: payloadJson)])).single;

  /// Decodes records with this codec in one background isolate invocation.
  ///
  /// List and catalog queries commonly return many small metadata documents.
  /// Starting one isolate per row makes their latency cumulative even though
  /// no document is individually expensive. Version upgrades and validation
  /// retain the same per-document behavior as [decodeAndUpgrade].
  Future<List<PreparedJsonDocument>> decodeAndUpgradeMany({required Iterable<({int version, String payloadJson})> documents}) async {
    final requested = List<({int version, String payloadJson})>.of(documents);
    for (final document in requested) {
      if (document.version > currentVersion) {
        throw const PersistenceFutureVersionError();
      }
    }
    if (requested.isEmpty) return const <PreparedJsonDocument>[];
    final payloads = requested.map((document) => document.payloadJson).toList(growable: false);
    final versions = requested.map((document) => document.version).toList(growable: false);
    final normalizedDocuments = _canDecodeInline(payloads)
        ? _decodeAndUpgradeManyInWorker(payloads, versions, currentVersion, limits, _validators, _upgraders)
        : await Isolate.run(
            () => _decodeAndUpgradeManyInWorker(payloads, versions, currentVersion, limits, _validators, _upgraders),
            debugName: 'mg-read-json-decode-batch',
          );
    final prepared = <PreparedJsonDocument>[];
    for (var index = 0; index < normalizedDocuments.length; index++) {
      final normalized = normalizedDocuments[index];
      final frozen = freezeJsonObject(normalized.document);
      _validators[currentVersion]!(frozen);
      prepared.add(
        PreparedJsonDocument(document: frozen, payloadJson: normalized.payloadJson, workerIsolateId: normalized.workerIsolateId),
      );
    }
    return List<PreparedJsonDocument>.unmodifiable(prepared);
  }
}

final class RecordDocumentRegistry {
  RecordDocumentRegistry(Iterable<RecordDocumentCodec> codecs)
    : _codecs = {for (final codec in codecs) (codec.recordKind, codec.scopeKind): codec} {
    if (_codecs.length != codecs.length) {
      throw ArgumentError('Duplicate record document codec.');
    }
  }

  final Map<(String, String), RecordDocumentCodec> _codecs;

  RecordDocumentCodec require(String recordKind, String scopeKind) {
    final codec = _codecs[(recordKind, scopeKind)];
    if (codec == null) {
      throw PersistenceValidationError('No document codec is registered for $recordKind/$scopeKind.');
    }
    return codec;
  }

  Future<List<PreparedJsonDocument>> prepareCurrentMany({
    required Iterable<({String recordKind, String scopeKind, JsonObject document})> documents,
  }) async {
    final requested = List<({String recordKind, String scopeKind, JsonObject document})>.of(documents);
    if (requested.isEmpty) return const <PreparedJsonDocument>[];
    final codecs = requested.map((document) => require(document.recordKind, document.scopeKind)).toList(growable: false);
    List<_NormalizedJson> normalize() => List<_NormalizedJson>.generate(
      requested.length,
      (index) => _normalizeAndEncode(requested[index].document, codecs[index].limits),
      growable: false,
    );
    final documentsToPrepare = requested.map((document) => document.document).toList(growable: false);
    final normalized = _canPrepareInline(documentsToPrepare, codecs)
        ? normalize()
        : await Isolate.run(normalize, debugName: 'mg-read-json-encode-registry-batch');
    return List<PreparedJsonDocument>.unmodifiable(
      List<PreparedJsonDocument>.generate(normalized.length, (index) {
        final frozen = freezeJsonObject(normalized[index].document);
        codecs[index]._validators[codecs[index].currentVersion]!(frozen);
        return PreparedJsonDocument(
          document: frozen,
          payloadJson: normalized[index].payloadJson,
          workerIsolateId: normalized[index].workerIsolateId,
        );
      }),
    );
  }

  Future<List<PreparedJsonDocument>> decodeAndUpgradeMany({
    required Iterable<({String recordKind, String scopeKind, int version, String payloadJson})> documents,
  }) async {
    final requested = List<({String recordKind, String scopeKind, int version, String payloadJson})>.of(documents);
    if (requested.isEmpty) return const <PreparedJsonDocument>[];
    final codecs = requested.map((document) => require(document.recordKind, document.scopeKind)).toList(growable: false);
    for (var index = 0; index < requested.length; index++) {
      if (requested[index].version > codecs[index].currentVersion) {
        throw const PersistenceFutureVersionError();
      }
    }
    final payloads = requested.map((document) => document.payloadJson).toList(growable: false);
    final versions = requested.map((document) => document.version).toList(growable: false);
    final normalized = _canDecodeInline(payloads)
        ? _decodeAndUpgradeRegistryManyInWorker(payloads, versions, codecs)
        : await Isolate.run(
            () => _decodeAndUpgradeRegistryManyInWorker(payloads, versions, codecs),
            debugName: 'mg-read-json-decode-registry-batch',
          );
    return List<PreparedJsonDocument>.unmodifiable(
      List<PreparedJsonDocument>.generate(normalized.length, (index) {
        final frozen = freezeJsonObject(normalized[index].document);
        codecs[index]._validators[codecs[index].currentVersion]!(frozen);
        return PreparedJsonDocument(
          document: frozen,
          payloadJson: normalized[index].payloadJson,
          workerIsolateId: normalized[index].workerIsolateId,
        );
      }),
    );
  }
}

bool _canPrepareInline(List<JsonObject> documents, List<RecordDocumentCodec> codecs) {
  if (documents.isEmpty || codecs.isEmpty) return false;
  final policies = codecs.map((codec) => codec.inlinePreparationPolicy).toList(growable: false);
  if (policies.any((policy) => policy == null)) return false;
  final resolved = policies.cast<JsonInlinePreparationPolicy>();
  final policy = JsonInlinePreparationPolicy(
    maxDocuments: resolved.map((value) => value.maxDocuments).reduce(_minimum),
    maxTotalNodes: resolved.map((value) => value.maxTotalNodes).reduce(_minimum),
    maxDepth: resolved.map((value) => value.maxDepth).reduce(_minimum),
    maxCollectionLength: resolved.map((value) => value.maxCollectionLength).reduce(_minimum),
    maxTotalTextCodeUnits: resolved.map((value) => value.maxTotalTextCodeUnits).reduce(_minimum),
  );
  if (documents.length > policy.maxDocuments) return false;
  final budget = _InlinePreparationBudget(policy);
  for (final document in documents) {
    if (!budget.accept(document, depth: 1)) return false;
  }
  return true;
}

int _minimum(int left, int right) => left < right ? left : right;

final class _InlinePreparationBudget {
  _InlinePreparationBudget(this.policy);

  final JsonInlinePreparationPolicy policy;
  var _nodes = 0;
  var _textCodeUnits = 0;

  bool accept(Object? value, {required int depth}) {
    _nodes++;
    if (_nodes > policy.maxTotalNodes || depth > policy.maxDepth) return false;
    if (value is Map) {
      if (value.length > policy.maxCollectionLength) return false;
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || !_acceptText(key)) return false;
        if (!accept(entry.value, depth: depth + 1)) return false;
      }
      return true;
    }
    if (value is List) {
      if (value.length > policy.maxCollectionLength) return false;
      for (final child in value) {
        if (!accept(child, depth: depth + 1)) return false;
      }
      return true;
    }
    if (value is String) return _acceptText(value);
    return value is bool || value == null || value is num && value.isFinite;
  }

  bool _acceptText(String value) {
    _textCodeUnits += value.length;
    return _textCodeUnits <= policy.maxTotalTextCodeUnits;
  }
}

final class _NormalizedJson {
  const _NormalizedJson({required this.document, required this.payloadJson, required this.workerIsolateId});

  final JsonObject document;
  final String payloadJson;
  final int workerIsolateId;
}

_NormalizedJson _decodeAndNormalize(String payloadJson, JsonDocumentLimits limits) {
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
  return _NormalizedJson(document: document, payloadJson: payloadJson, workerIsolateId: Isolate.current.hashCode);
}

List<_NormalizedJson> _decodeAndUpgradeManyInWorker(
  List<String> payloads,
  List<int> versions,
  int currentVersion,
  JsonDocumentLimits limits,
  Map<int, JsonValidator> validators,
  Map<int, JsonUpgrader> upgraders,
) {
  final workerIsolateId = Isolate.current.hashCode;
  return List<_NormalizedJson>.unmodifiable(
    List<_NormalizedJson>.generate(
      payloads.length,
      (index) => _decodeAndUpgradeInWorker(
        payloadJson: payloads[index],
        version: versions[index],
        currentVersion: currentVersion,
        limits: limits,
        validators: validators,
        upgraders: upgraders,
        workerIsolateId: workerIsolateId,
      ),
      growable: false,
    ),
  );
}

List<_NormalizedJson> _decodeAndUpgradeRegistryManyInWorker(List<String> payloads, List<int> versions, List<RecordDocumentCodec> codecs) {
  final workerIsolateId = Isolate.current.hashCode;
  return List<_NormalizedJson>.unmodifiable(
    List<_NormalizedJson>.generate(
      payloads.length,
      (index) => _decodeAndUpgradeInWorker(
        payloadJson: payloads[index],
        version: versions[index],
        currentVersion: codecs[index].currentVersion,
        limits: codecs[index].limits,
        validators: codecs[index]._validators,
        upgraders: codecs[index]._upgraders,
        workerIsolateId: workerIsolateId,
      ),
      growable: false,
    ),
  );
}

_NormalizedJson _decodeAndUpgradeInWorker({
  required String payloadJson,
  required int version,
  required int currentVersion,
  required JsonDocumentLimits limits,
  required Map<int, JsonValidator> validators,
  required Map<int, JsonUpgrader> upgraders,
  required int workerIsolateId,
}) {
  var normalized = _decodeAndNormalize(payloadJson, limits);
  var working = normalized.document;
  var cursor = version;
  while (cursor < currentVersion) {
    validators[cursor]?.call(freezeJsonObject(working));
    final JsonUpgrader? upgrader = upgraders[cursor];
    if (upgrader == null) {
      throw const PersistenceCorruptionError();
    }
    final upgraded = upgrader(freezeJsonObject(working));
    normalized = _normalizeAndEncode(upgraded, limits);
    working = normalized.document;
    cursor++;
  }
  return _NormalizedJson(document: normalized.document, payloadJson: normalized.payloadJson, workerIsolateId: workerIsolateId);
}

bool _canDecodeInline(List<String> payloads) {
  var totalCodeUnits = 0;
  for (final payload in payloads) {
    if (payload.length > _maximumInlineDocumentCodeUnits) return false;
    totalCodeUnits += payload.length;
    if (totalCodeUnits > _maximumInlineBatchCodeUnits) return false;
  }
  return true;
}

List<_NormalizedJson> _normalizeAndEncodeMany(List<JsonObject> documents, JsonDocumentLimits limits) =>
    documents.map((document) => _normalizeAndEncode(document, limits)).toList(growable: false);

_NormalizedJson _normalizeAndEncode(JsonObject document, JsonDocumentLimits limits) {
  final copy = _copyObject(document);
  _validateJsonShape(copy, limits, corruption: false);
  final payload = jsonEncode(copy);
  if (utf8.encode(payload).length > limits.maxEncodedBytes) {
    throw PersistenceValidationError('JSON document exceeds ${limits.maxEncodedBytes} encoded bytes.');
  }
  return _NormalizedJson(document: copy, payloadJson: payload, workerIsolateId: Isolate.current.hashCode);
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
  if (value is String || value is bool || value == null || value is num && value.isFinite) {
    return value;
  }
  throw const PersistenceValidationError('The document contains a non-JSON value.');
}

void _validateJsonShape(JsonObject document, JsonDocumentLimits limits, {required bool corruption}) {
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
