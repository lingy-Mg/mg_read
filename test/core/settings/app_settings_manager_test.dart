import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';

void main() {
  const key = SettingKey<String>(
    id: 'appearance.themeMode',
    documentKind: 'settings.appearance',
    defaultValue: 'system',
    codec: SettingCodec(_encode, _decode),
    validator: _validate,
  );
  late _FakeStore store;
  late AppSettingsManager manager;
  setUp(() {
    store = _FakeStore();
    manager = AppSettingsManager(store: store, keys: const [key]);
  });
  tearDown(() => manager.close());
  test('loads registered documents once and defaults do not write', () async {
    await manager.initialize();
    expect(manager.get(key), 'system');
    expect(store.loads, 1);
    expect(store.writes, 0);
    expect(manager.get(key), 'system');
    expect(store.loads, 1);
  });
  test('set reset and transaction publish only after persistence', () async {
    await manager.initialize();
    await manager.set(key, 'dark');
    expect(manager.get(key), 'dark');
    await manager.reset(key);
    expect(manager.get(key), 'system');
  });
  test('unknown fields and null are preserved', () async {
    store.docs['settings.appearance'] = SettingsDocument(
      kind: 'settings.appearance',
      values: {'unknown': null},
    );
    await manager.initialize();
    await manager.set(key, 'dark');
    expect(store.docs['settings.appearance']!.values, {
      'unknown': null,
      key.id: 'dark',
    });
  });
  test('failure leaves snapshot unchanged and close waits writes', () async {
    await manager.initialize();
    store.fail = true;
    await expectLater(manager.set(key, 'dark'), throwsStateError);
    expect(manager.get(key), 'system');
  });
}

Object? _encode(String value) => value;
String _decode(Object? value) => value as String;
void _validate(String value) {
  if (value != 'system' && value != 'dark') throw ArgumentError.value(value);
}

final class _FakeStore implements SettingsStore {
  final docs = <String, SettingsDocument>{};
  int loads = 0;
  int writes = 0;
  bool fail = false;
  @override
  Future<List<SettingsDocument>> loadAll(Iterable<String> kinds) async {
    loads++;
    return [
      for (final kind in kinds)
        if (docs.containsKey(kind)) docs[kind]!,
    ];
  }

  @override
  Future<void> writeAll(List<SettingsDocument> documents) async {
    writes++;
    if (fail) throw StateError('failed');
    for (final document in documents) {
      docs[document.kind] = document;
    }
  }

  @override
  Future<void> close() async {}
}
