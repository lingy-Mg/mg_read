import 'dart:async';

import 'package:mg_read/core/settings/settings.dart';

const appearanceDocument = SettingsDocumentDefinition(
  id: 'app-settings:settings.appearance',
  kind: 'settings.appearance',
);
const behaviorDocument = SettingsDocumentDefinition(
  id: 'app-settings:settings.behavior',
  kind: 'settings.behavior',
);

const themeKey = SettingKey<String>(
  id: 'appearance.themeMode',
  documentKind: 'settings.appearance',
  defaultValue: 'system',
  codec: SettingCodec<String>(stringEncode, stringDecode),
  validator: validateTheme,
);

const nullableLabelKey = SettingKey<String?>(
  id: 'appearance.optionalLabel',
  documentKind: 'settings.appearance',
  defaultValue: 'fallback',
  codec: SettingCodec<String?>(nullableStringEncode, nullableStringDecode),
  validator: validateNullableLabel,
);

const pageStepKey = SettingKey<int>(
  id: 'behavior.pageStep',
  documentKind: 'settings.behavior',
  defaultValue: 1,
  codec: SettingCodec<int>(intEncode, intDecode),
  validator: validatePageStep,
);

final settingsTestRegistry = SettingsRegistry(
  keys: const [themeKey, nullableLabelKey, pageStepKey],
  documents: const [appearanceDocument, behaviorDocument],
);

Object? stringEncode(String value) => value;
String stringDecode(Object? value) {
  if (value is! String) {
    throw const FormatException('Expected string.');
  }
  return value;
}

Object? nullableStringEncode(String? value) => value;
String? nullableStringDecode(Object? value) {
  if (value != null && value is! String) {
    throw const FormatException('Expected nullable string.');
  }
  return value as String?;
}

Object? intEncode(int value) => value;
int intDecode(Object? value) {
  if (value is! int) {
    throw const FormatException('Expected integer.');
  }
  return value;
}

void validateTheme(String value) {
  if (value != 'system' && value != 'light' && value != 'dark') {
    throw ArgumentError.value(value);
  }
}

void validateNullableLabel(String? value) {
  if (value != null && value.length > 64) {
    throw ArgumentError.value(value);
  }
}

void validatePageStep(int value) {
  if (value < 1 || value > 100) {
    throw ArgumentError.value(value);
  }
}

final class FakeSettingsStore implements SettingsStore {
  final Map<String, SettingsDocument> documents = {};
  final List<List<SettingsDocument>> writeBatches = [];
  int loadCalls = 0;
  int writeCalls = 0;
  int closeCalls = 0;
  int failWrites = 0;
  bool failLoads = false;
  Completer<void>? loadGate;
  Completer<void>? writeGate;
  Completer<void>? closeGate;

  @override
  Future<List<SettingsDocument>> loadAll(
    Iterable<SettingsDocumentDefinition> requested,
  ) async {
    loadCalls++;
    await loadGate?.future;
    if (failLoads) {
      throw const SettingsStoreFailure('load_failed');
    }
    return [
      for (final definition in requested)
        if (documents[definition.kind] case final document?)
          SettingsDocument(
            id: document.id,
            kind: document.kind,
            values: document.values,
            revision: document.revision,
            problem: document.problem,
          ),
    ];
  }

  @override
  Future<List<SettingsDocument>> writeAll(
    List<SettingsDocument> requested,
  ) async {
    writeCalls++;
    await writeGate?.future;
    if (failWrites > 0) {
      failWrites--;
      throw const SettingsStoreFailure('injected_write_failure');
    }
    for (final document in requested) {
      final current = documents[document.kind];
      if (current?.revision != document.revision) {
        throw const SettingsStoreConflict();
      }
    }
    final saved = <SettingsDocument>[];
    for (final document in requested) {
      final current = documents[document.kind];
      saved.add(
        SettingsDocument(
          id: document.id,
          kind: document.kind,
          values: document.values,
          revision: (current?.revision ?? 0) + 1,
        ),
      );
    }
    for (final document in saved) {
      documents[document.kind] = document;
    }
    writeBatches.add(saved);
    return saved;
  }

  void externalWrite(String kind, Map<String, Object?> values) {
    final current = documents[kind];
    final definition = settingsTestRegistry.requireDocument(kind);
    documents[kind] = SettingsDocument(
      id: definition.id,
      kind: kind,
      values: values,
      revision: (current?.revision ?? 0) + 1,
    );
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await closeGate?.future;
  }
}

Future<void> waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached.', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
