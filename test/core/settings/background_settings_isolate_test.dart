import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/settings/settings.dart';

import 'settings_testkit.dart';

const backgroundMapKey = SettingKey<Map<String, Object?>>(
  id: 'appearance.backgroundMap',
  documentKind: 'settings.appearance',
  defaultValue: {},
  codec: SettingCodec<Map<String, Object?>>(
    _backgroundMapEncode,
    _backgroundMapDecode,
    freeze: freezeJsonSettingMap,
  ),
  validator: _validateBackgroundMap,
);

void main() {
  test('background isolates share one serialized owner entry', () async {
    final store = FakeSettingsStore();
    final manager = AppSettingsManager(
      store: store,
      registry: SettingsRegistry(
        keys: [...settingsTestRegistry.keys.values, backgroundMapKey],
        documents: settingsTestRegistry.documents.values,
      ),
      policy: const SettingsPersistencePolicy(
        debounce: Duration(milliseconds: 100),
      ),
    );
    addTearDown(manager.close);
    await manager.initialize();

    final done = ReceivePort('settings-isolate-test-done');
    addTearDown(done.close);
    await Future.wait([
      Isolate.spawn(_writeTheme, [
        manager.backgroundCommandPort,
        done.sendPort,
      ]),
      Isolate.spawn(_writeLabel, [
        manager.backgroundCommandPort,
        done.sendPort,
      ]),
      Isolate.spawn(_writeMap, [manager.backgroundCommandPort, done.sendPort]),
    ]);
    final completions = await done.take(3).toList();

    expect(completions, everyElement(true));
    expect(manager.get(themeKey), 'dark');
    expect(manager.get(nullableLabelKey), 'from-background');
    expect(manager.get(backgroundMapKey), {
      'nested': [1, 2],
    });
    expect(manager.status.isDirty, isTrue);

    final result = await manager.flush();
    expect(result.persisted, isTrue);
    expect(store.writeCalls, 1);
    final values = store.documents[appearanceDocument.kind]!.values;
    expect(values[themeKey.id], 'dark');
    expect(values[nullableLabelKey.id], 'from-background');
    expect(values[backgroundMapKey.id], {
      'nested': [1, 2],
    });
  });
}

Future<void> _writeTheme(List<Object?> arguments) async {
  final client = BackgroundSettingsClient(arguments[0]! as SendPort);
  await client.set(themeKey, 'dark');
  (arguments[1]! as SendPort).send(true);
}

Future<void> _writeLabel(List<Object?> arguments) async {
  final client = BackgroundSettingsClient(arguments[0]! as SendPort);
  await client.set(nullableLabelKey, 'from-background');
  (arguments[1]! as SendPort).send(true);
}

Future<void> _writeMap(List<Object?> arguments) async {
  final client = BackgroundSettingsClient(arguments[0]! as SendPort);
  await client.set(backgroundMapKey, {
    'nested': [1, 2],
  });
  (arguments[1]! as SendPort).send(true);
}

Object? _backgroundMapEncode(Map<String, Object?> value) => value;

Map<String, Object?> _backgroundMapDecode(Object? value) {
  if (value is! Map) {
    throw const FormatException('Expected a settings map.');
  }
  return Map<String, Object?>.from(value);
}

void _validateBackgroundMap(Map<String, Object?> value) {}
