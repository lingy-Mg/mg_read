/// 数据源启停与删除操作控制器。
///
/// 职责：串行化单个数据源的 Runtime 写操作、刷新共享投影并记录受控诊断终态。
/// 注意：删除仅安排下一次 Runtime 冷启动执行，不热卸载当前 Node VM 中的模块。
part of 'plugin_runtime_connection.dart';

/// Serializes source enable/disable and cold-start removal requests.
final pluginRuntimeSourceActionProvider = NotifierProvider<PluginRuntimeSourceActionController, Set<String>>(
  PluginRuntimeSourceActionController.new,
);

final class PluginRuntimeSourceActionController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  Future<void> setEnabled({required String pluginId, required bool enabled}) => _run(
    pluginId: pluginId,
    capability: 'runtime.plugins.setEnabled.v1',
    operation: () => ref.read(pluginRuntimeGatewayProvider).setEnabled(pluginId: pluginId, enabled: enabled),
    onSuccess: () => ref.read(pluginRuntimeCatalogChangeProvider.notifier).publish(pluginIds: <String>{pluginId}),
  );

  Future<void> scheduleUninstall({required String pluginId}) => _run(
    pluginId: pluginId,
    capability: 'runtime.plugins.uninstall.v1',
    operation: () => ref.read(pluginRuntimeGatewayProvider).scheduleUninstall(pluginId: pluginId),
  );

  Future<void> _run({
    required String pluginId,
    required String capability,
    required Future<void> Function() operation,
    void Function()? onSuccess,
  }) async {
    if (state.contains(pluginId)) throw AppError.fromCode(AppErrorCode.conflict);
    state = Set<String>.unmodifiable(<String>{...state, pluginId});
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string(capability),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      await operation();
      if (onSuccess != null) {
        onSuccess();
      } else {
        // A scheduled uninstall changes management metadata immediately, but
        // does not change the live source catalog until the next cold start.
        ref.invalidate(pluginRuntimeConnectionProvider);
        ref.invalidate(pluginRuntimeStatusProvider);
      }
      await ref.read(pluginRuntimeConnectionProvider.future);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(capability),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(capability),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    } finally {
      state = Set<String>.unmodifiable(state.where((String value) => value != pluginId));
    }
  }
}
