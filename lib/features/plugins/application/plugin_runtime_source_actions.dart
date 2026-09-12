/// 数据源启停与删除操作控制器。
///
/// 职责：串行化单个数据源的 Runtime 写操作、刷新共享投影并记录受控诊断终态。
/// 注意：删除会即时从 Runtime 快照和调度入口移除，但不热卸载当前 Node VM 中的模块。
part of 'plugin_runtime_connection.dart';

/// Serializes source enable/disable and immediate removal requests.
final pluginRuntimeSourceActionProvider = NotifierProvider<PluginRuntimeSourceActionController, Set<String>>(
  PluginRuntimeSourceActionController.new,
);

/// Projects bounded Runtime-owned bulk-removal progress for the management UI.
final pluginRuntimeSourceRemovalProgressProvider =
    NotifierProvider<PluginRuntimeSourceRemovalProgressController, PluginSourceRemovalProgress>(
      PluginRuntimeSourceRemovalProgressController.new,
    );

final class PluginSourceRemovalProgress {
  const PluginSourceRemovalProgress({
    required this.completedItems,
    required this.isRemoving,
    required this.message,
    required this.totalItems,
  });

  const PluginSourceRemovalProgress.idle() : completedItems = 0, isRemoving = false, message = '', totalItems = 0;

  final int completedItems;
  final bool isRemoving;
  final String message;
  final int totalItems;

  double? get fraction => totalItems == 0 ? null : completedItems / totalItems;
}

final class PluginRuntimeSourceRemovalProgressController extends Notifier<PluginSourceRemovalProgress> {
  @override
  PluginSourceRemovalProgress build() {
    final subscription = ref.read(pluginRuntimeGatewayProvider).initialization.listen(_onRuntimeProgress);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return const PluginSourceRemovalProgress.idle();
  }

  void begin({required int totalItems}) {
    state = PluginSourceRemovalProgress(completedItems: 0, isRemoving: true, message: '正在准备清理本地数据源', totalItems: totalItems);
  }

  void finish() => state = const PluginSourceRemovalProgress.idle();

  void _onRuntimeProgress(RuntimeInitializationProgress progress) {
    if (!state.isRemoving ||
        (progress.stage != RuntimeInitializationStage.pluginUninstalling &&
            progress.stage != RuntimeInitializationStage.pluginUninstalled)) {
      return;
    }
    state = PluginSourceRemovalProgress(
      completedItems: progress.completedBytes,
      isRemoving: true,
      message: progress.detail ?? _initializationMessage(progress.stage),
      totalItems: progress.totalBytes,
    );
  }
}

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

  Future<void> uninstallAll({int totalItems = 0}) async {
    final progress = ref.read(pluginRuntimeSourceRemovalProgressProvider.notifier);
    progress.begin(totalItems: totalItems);
    try {
      await _run(
        pluginId: _allSourcesOperationKey,
        capability: 'runtime.plugins.uninstallAll.v1',
        operation: () async {
          // Let the pending state reach a Flutter frame before a fast local
          // deletion completes. Runtime progress drives every item update.
          await Future<void>.delayed(const Duration(milliseconds: 32));
          await ref.read(pluginRuntimeGatewayProvider).uninstallAll();
        },
      );
    } finally {
      progress.finish();
    }
  }

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
        ref.read(pluginRuntimeCatalogChangeProvider.notifier).publish();
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
