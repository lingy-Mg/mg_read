/// 数据源启停与删除操作控制器。
///
/// 职责：串行化单个数据源的 Runtime 写操作、刷新共享投影并记录受控诊断终态。
/// 注意：删除仅安排下一次 Runtime 冷启动执行，不热卸载当前 Node VM 中的模块。
part of 'plugin_runtime_connection.dart';

/// Serializes source enable/disable and immediate removal requests.
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

  Future<void> uninstall({required String pluginId}) => _run(
    pluginId: pluginId,
    capability: 'runtime.plugins.uninstall.v1',
    operation: () => ref.read(pluginRuntimeGatewayProvider).uninstall(pluginId: pluginId),
  );

  Future<void> uninstallAll() => _run(
    pluginId: _allSourcesOperationKey,
    capability: 'runtime.plugins.uninstallAll.v1',
    operation: () => ref.read(pluginRuntimeGatewayProvider).uninstallAll(),
  );

  Future<void> _run({
    required String pluginId,
    required String capability,
    required Future<void> Function() operation,
    void Function()? onSuccess,
  }) async {
    if (state.contains(pluginId) ||
        (pluginId == _allSourcesOperationKey && state.isNotEmpty) ||
        (pluginId != _allSourcesOperationKey && state.contains(_allSourcesOperationKey))) {
      throw AppError.fromCode(AppErrorCode.conflict);
    }
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
        // Removal changes the Runtime-owned source catalog immediately.
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

const _allSourcesOperationKey = '__all_installed_sources__';
