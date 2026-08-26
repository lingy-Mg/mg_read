/// Runtime 调试检查页应用状态。
///
/// 职责：
/// - 读取 Runtime 自有的调试开关与 listener 状态。
/// - 串行提交用户切换并记录脱敏的应用诊断 span。
///
/// 注意：
/// - 不持有端口、路径或 Runtime 控制协议。
/// - 开关配置由 Runtime 数据根持久化，页面只展示强类型投影。
///
/// TODO:
/// - 无。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

final pluginRuntimeDebugHttpProvider = AsyncNotifierProvider<PluginRuntimeDebugHttpController, PluginRuntimeDebugHttp>(
  PluginRuntimeDebugHttpController.new,
);

final class PluginRuntimeDebugHttpController extends AsyncNotifier<PluginRuntimeDebugHttp> {
  @override
  Future<PluginRuntimeDebugHttp> build() => _inspect();

  Future<void> setEnabled(bool enabled) async {
    if (state.isLoading) return;
    state = const AsyncLoading<PluginRuntimeDebugHttp>();
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.debugHttp.setEnabled.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final result = await ref.read(pluginRuntimeGatewayProvider).setDebugHttpEnabled(enabled);
      state = AsyncData(result);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.debugHttp.setEnabled.v1'),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      state = AsyncError<PluginRuntimeDebugHttp>(appError, stackTrace);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.debugHttp.setEnabled.v1'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
          'resultState': DiagnosticValue.string('failure'),
        }),
      );
    }
  }

  Future<PluginRuntimeDebugHttp> _inspect() async {
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.debugHttp.status.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final result = await ref.read(pluginRuntimeGatewayProvider).inspectDebugHttp();
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.debugHttp.status.v1'),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
      return result;
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.debugHttp.status.v1'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
          'resultState': DiagnosticValue.string('failure'),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    }
  }
}
