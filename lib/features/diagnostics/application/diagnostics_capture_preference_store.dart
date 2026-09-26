/// 诊断文件保存偏好与旧设置数据的兼容边界。
/// 文件保存显式开关由应用启动恢复；旧实时详情偏好仅保留存储兼容，
/// 诊断页不会读取它来自动开启详细记录。临时捕获由网关在内存中持有。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/settings/settings.dart';

abstract interface class DiagnosticsCapturePreferenceStore {
  Future<bool> loadDiagnosticsEnabled();

  Future<void> saveDiagnosticsEnabled(bool enabled);

  Future<bool> loadRealtimeDetailsEnabled();

  Future<void> saveRealtimeDetailsEnabled(bool enabled);
}

final diagnosticsCapturePreferenceStoreProvider = Provider<DiagnosticsCapturePreferenceStore>((ref) {
  return AppSettingsDiagnosticsCapturePreferenceStore(ref.watch(appSettingsProvider));
});

final class AppSettingsDiagnosticsCapturePreferenceStore implements DiagnosticsCapturePreferenceStore {
  const AppSettingsDiagnosticsCapturePreferenceStore(this._settings);

  final AppSettingsManager _settings;

  @override
  Future<bool> loadDiagnosticsEnabled() async => _settings.get(AppSettingKeys.diagnosticsEnabled);

  @override
  Future<void> saveDiagnosticsEnabled(bool enabled) => _settings.set(AppSettingKeys.diagnosticsEnabled, enabled);

  @override
  Future<bool> loadRealtimeDetailsEnabled() async => _settings.get(AppSettingKeys.diagnosticsRealtimeDetailsEnabled);

  @override
  Future<void> saveRealtimeDetailsEnabled(bool enabled) => _settings.set(AppSettingKeys.diagnosticsRealtimeDetailsEnabled, enabled);
}
