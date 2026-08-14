import 'dart:async';
import 'dart:isolate';

import 'setting_key.dart';
import 'settings_registry.dart';

final class BackgroundSettingsClient {
  const BackgroundSettingsClient(
    this._commandPort, {
    this.commandTimeout = const Duration(seconds: 5),
  });

  final SendPort _commandPort;
  final Duration commandTimeout;

  Future<void> set<T>(SettingKey<T> key, T value) =>
      transaction((editor) => editor.set(key, value));

  Future<void> reset<T>(SettingKey<T> key) =>
      transaction((editor) => editor.reset(key));

  Future<void> resetGroup(String documentKind) =>
      transaction((editor) => editor.resetGroup(documentKind));

  Future<void> transaction(
    void Function(BackgroundSettingsTransaction editor) action,
  ) async {
    final editor = BackgroundSettingsTransaction._();
    action(editor);
    final reply = ReceivePort('mg-read-settings-command-reply');
    try {
      _commandPort.send(
        SettingsCommandProtocol.apply(
          operations: editor._operations,
          replyPort: reply.sendPort,
        ),
      );
      final response = await reply.first.timeout(commandTimeout);
      if (response is! List || response.isEmpty || response.first != true) {
        final code = response is List && response.length > 1
            ? response[1].toString()
            : 'command_failed';
        throw BackgroundSettingsCommandException(code);
      }
    } finally {
      reply.close();
    }
  }
}

final class BackgroundSettingsTransaction {
  BackgroundSettingsTransaction._();

  final List<List<Object?>> _operations = [];

  void set<T>(SettingKey<T> key, T value) {
    key.validator(value);
    final encoded = copySettingsJsonValue(key.codec.encode(value));
    validateSettingsEncodedValue(encoded);
    _operations.add(<Object?>['set', key.id, encoded]);
  }

  void reset<T>(SettingKey<T> key) {
    _operations.add(<Object?>['reset', key.id]);
  }

  void resetGroup(String documentKind) {
    _operations.add(<Object?>['resetGroup', documentKind]);
  }
}

final class BackgroundSettingsCommandException implements Exception {
  const BackgroundSettingsCommandException(this.code);

  final String code;

  @override
  String toString() => 'BackgroundSettingsCommandException($code)';
}

abstract final class SettingsCommandProtocol {
  static const String operation = 'settings.apply.v1';

  static List<Object?> apply({
    required List<List<Object?>> operations,
    required SendPort replyPort,
  }) => <Object?>[
    operation,
    [for (final operation in operations) List<Object?>.of(operation)],
    replyPort,
  ];
}
