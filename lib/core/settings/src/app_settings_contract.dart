part of 'app_settings_manager.dart';

typedef SettingsStoreFactory = Future<SettingsStore> Function();
typedef SettingsClock = DateTime Function();

final class SettingsPersistencePolicy {
  const SettingsPersistencePolicy({
    this.debounce = const Duration(milliseconds: 300),
    this.retryBaseDelay = const Duration(milliseconds: 300),
    this.retryMaxDelay = const Duration(seconds: 5),
    this.maxConflictRetries = 3,
    this.flushRetryAttempts = 3,
    this.closeTimeout = const Duration(seconds: 2),
  });

  final Duration debounce;
  final Duration retryBaseDelay;
  final Duration retryMaxDelay;
  final int maxConflictRetries;
  final int flushRetryAttempts;
  final Duration closeTimeout;
}

final class SettingsReadOnlyException implements Exception {
  const SettingsReadOnlyException(this.documentKind);

  final String documentKind;

  @override
  String toString() => 'SettingsReadOnlyException($documentKind)';
}
