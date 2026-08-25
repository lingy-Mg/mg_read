import 'dart:collection';

typedef JsonObject = Map<String, Object?>;

final class ScopeKey {
  const ScopeKey({required this.kind, required this.id});

  final String kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is ScopeKey && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

final class RecordDraft {
  const RecordDraft({
    required this.id,
    required this.recordKind,
    required this.scope,
    required this.document,
    this.parentId,
    this.identityKey,
    this.orderKey,
    this.stateKey,
  });

  final String id;
  final String recordKind;
  final ScopeKey scope;
  final JsonObject document;
  final String? parentId;
  final String? identityKey;
  final String? orderKey;
  final String? stateKey;
}

final class RecordEnvelope {
  const RecordEnvelope({
    required this.id,
    required this.recordKind,
    required this.scope,
    required this.formatVersion,
    required this.revision,
    required this.document,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.parentId,
    this.identityKey,
    this.orderKey,
    this.stateKey,
  });

  final String id;
  final String recordKind;
  final ScopeKey scope;
  final int formatVersion;
  final int revision;
  final JsonObject document;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final String? parentId;
  final String? identityKey;
  final String? orderKey;
  final String? stateKey;
}

/// A stable, keyset-paginated query.  The cursor is the last returned
/// `(orderKey, id)` pair, so inserts before a page never duplicate a row.
final class RecordQuery {
  const RecordQuery({
    required this.recordKind,
    required this.scope,
    this.parentId,
    this.stateKey,
    this.identityKey,
    this.orderKey,
    this.after,
    this.limit = 100,
  }) : assert(limit > 0 && limit <= 1000);

  final String recordKind;
  final ScopeKey scope;
  final String? parentId;
  final String? stateKey;
  final String? identityKey;

  /// Exact order projection filter used by typed repositories for point reads.
  final String? orderKey;
  final RecordCursor? after;
  final int limit;
}

final class RecordCursor {
  const RecordCursor({required this.orderKey, required this.id});
  final String orderKey;
  final String id;
}

final class RecordPage {
  const RecordPage({required this.records, this.nextCursor});
  final List<RecordEnvelope> records;
  final RecordCursor? nextCursor;
}

JsonObject freezeJsonObject(JsonObject value) => UnmodifiableMapView(
  value.map((key, child) => MapEntry(key, _freezeJson(child))),
);

Object? _freezeJson(Object? value) {
  if (value is Map<String, Object?>) {
    return freezeJsonObject(value);
  }
  if (value is List<Object?>) {
    return UnmodifiableListView(value.map(_freezeJson));
  }
  return value;
}
