/// 后台 isolate 设置命令的验证、解码与事务投递。
///
/// 命令仍经同一设置事务入口应用，不直接写持久化。
part of 'app_settings_manager.dart';

extension _AppSettingsBackgroundExecution on AppSettingsManager {
  void _handleBackgroundCommand(Object? message) {
    SendPort? reply;
    try {
      if (message is! List ||
          message.length != 3 ||
          message[0] != SettingsCommandProtocol.operation ||
          message[1] is! List ||
          message[2] is! SendPort) {
        return;
      }
      reply = message[2] as SendPort;
      _ensureWritable();
      final mutations = <_SettingsMutation>[];
      for (final rawOperation in message[1] as List) {
        if (rawOperation is! List || rawOperation.length < 2) {
          throw ArgumentError('Invalid settings command.');
        }
        final operation = rawOperation[0];
        final id = rawOperation[1];
        if (id is! String) {
          throw ArgumentError('Invalid settings command ID.');
        }
        switch (operation) {
          case 'set':
            if (rawOperation.length != 3) {
              throw ArgumentError('Invalid set command.');
            }
            final key = _registry.requireKey(id);
            final encoded = freezeSettingsJsonValue(rawOperation[2]);
            validateSettingsEncodedValue(encoded);
            final value = key.decodeValue(encoded);
            key.validateValue(value);
            mutations.add(_SetMutation(key, key.freezeValue(value), encoded));
          case 'reset':
            if (rawOperation.length != 2) {
              throw ArgumentError('Invalid reset command.');
            }
            mutations.add(_ResetMutation(_registry.requireKey(id)));
          case 'resetGroup':
            if (rawOperation.length != 2) {
              throw ArgumentError('Invalid reset-group command.');
            }
            _registry.requireDocument(id);
            mutations.add(_ResetGroupMutation(id));
          default:
            throw ArgumentError('Unknown settings command.');
        }
      }
      _applyMutations(mutations, source: SettingsChangeSource.backgroundIsolate);
      reply.send(const <Object?>[true]);
    } catch (error) {
      reply?.send(<Object?>[false, _safeCommandErrorCode(error)]);
    }
  }

  String _safeCommandErrorCode(Object error) => switch (error) {
    SettingsReadOnlyException() => 'read_only_document',
    StateError() => 'settings_not_writable',
    ArgumentError() => 'invalid_command',
    _ => 'command_failed',
  };
}
