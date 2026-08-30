/// 调试日志详情捕获偏好边界。
///
/// 职责：
/// - 读取和保存“仅关键 / 实时详情”的用户选择。
/// - 将诊断页面与应用全局设置实现隔离。
///
/// 注意：
/// - 默认关闭实时详情，即仅展示关键日志。
/// - 只保存模式偏好，不保存捕获会话；页面销毁时会话仍必须停止。
/// - “保存详情 TXT”是一次性显式操作，不在此处持久化。
///
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
