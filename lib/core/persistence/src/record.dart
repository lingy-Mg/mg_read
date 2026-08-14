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
