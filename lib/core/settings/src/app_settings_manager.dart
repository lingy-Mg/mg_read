import 'dart:async';

import 'setting_key.dart';
import 'settings_store.dart';

final class AppSettingsManager {
  AppSettingsManager({
    required SettingsStore store,
    required Iterable<SettingKey<dynamic>> keys,
  }) : _store = store,
       _keys = Map.unmodifiable({for (final key in keys) key.id: key});
  final SettingsStore _store;
  final Map<String, SettingKey<dynamic>> _keys;
  final _changes = StreamController<SettingsSnapshot>.broadcast();
  Future<void> _tail = Future.value();
  SettingsSnapshot _snapshot = SettingsSnapshot(const {});
  SettingsState _state = SettingsState.loading;
  final Set<String> _degraded = {};
  final Map<String, Map<String, Object?>> _documents = {};
  SettingsState get state => _state;
  Stream<SettingsSnapshot> get changes => _changes.stream;
  T get<T>(SettingKey<T> key) => _snapshot.get(key);

  Future<void> initialize() async {
    if (_state != SettingsState.loading) return;
    try {
      final documents = await _store.loadAll(
        _keys.values.map((key) => key.documentKind).toSet(),
      );
      final merged = <String, Object?>{};
      for (final document in documents) {
        _documents[document.kind] = Map.of(document.values);
        if (document.readOnly) _degraded.add(document.kind);
        for (final entry in document.values.entries) {
          final key = _keys[entry.key];
          if (key == null) continue;
          try {
            merged[entry.key] = key.decodeValue(entry.value);
          } catch (_) {
            _degraded.add(document.kind);
          }
        }
      }
      _snapshot = SettingsSnapshot(merged);
      _state = _degraded.isEmpty ? SettingsState.ready : SettingsState.degraded;
    } catch (_) {
      _state = SettingsState.failed;
      rethrow;
    }
  }

  Future<void> set<T>(SettingKey<T> key, T value) =>
      transaction((editor) => editor.set(key, value));
  Future<void> reset<T>(SettingKey<T> key) =>
      transaction((editor) => editor.reset(key));
  Future<void> resetGroup(String documentKind) =>
      transaction((editor) => editor.resetGroup(documentKind));

  Future<void> transaction(void Function(SettingsTransaction editor) action) {
    final completer = Completer<void>();
    _tail = _tail
        .then((_) async {
          if (_state != SettingsState.ready && _state != SettingsState.degraded)
            throw StateError('Settings are not writable.');
          final editor = SettingsTransaction(_snapshot, _keys, _documents);
          action(editor);
          final documents = editor.documents();
          await _store.writeAll(documents);
          _documents.addAll(editor.documentValues());
          _snapshot = editor.snapshot();
          _changes.add(_snapshot);
          completer.complete();
        })
        .catchError((Object error, StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        });
    return completer.future;
  }

  Future<void> close() async {
    if (_state == SettingsState.closed) return;
    _state = SettingsState.closing;
    await _tail;
    await _store.close();
    await _changes.close();
    _state = SettingsState.closed;
  }
}

final class SettingsTransaction {
  SettingsTransaction(
    SettingsSnapshot snapshot,
    this.keys,
    Map<String, Map<String, Object?>> baseDocuments,
  ) : values = {
        for (final entry in keys.entries) entry.key: snapshot.get(entry.value),
      },
      bases = {
        for (final entry in baseDocuments.entries)
          entry.key: Map.of(entry.value),
      };
  final Map<String, SettingKey<dynamic>> keys;
  final Map<String, Object?> values;
  final Map<String, Map<String, Object?>> bases;
  final Set<String> changedKinds = {};
  void set<T>(SettingKey<T> key, T value) {
    key.validator(value);
    values[key.id] = value;
    changedKinds.add(key.documentKind);
  }

  void reset<T>(SettingKey<T> key) {
    values.remove(key.id);
    changedKinds.add(key.documentKind);
  }

  void resetGroup(String kind) {
    for (final key in keys.values.where((key) => key.documentKind == kind)) {
      values.remove(key.id);
    }
    changedKinds.add(kind);
  }

  List<SettingsDocument> documents() => changedKinds.map((kind) {
    final document = Map<String, Object?>.of(bases[kind] ?? const {});
    for (final key in keys.values.where((key) => key.documentKind == kind)) {
      document.remove(key.id);
      if (values.containsKey(key.id))
        document[key.id] = key.encodeValue(values[key.id]);
    }
    return SettingsDocument(kind: kind, values: document);
  }).toList();
  Map<String, Map<String, Object?>> documentValues() => {
    for (final document in documents()) document.kind: Map.of(document.values),
  };
  SettingsSnapshot snapshot() => SettingsSnapshot(values);
}
