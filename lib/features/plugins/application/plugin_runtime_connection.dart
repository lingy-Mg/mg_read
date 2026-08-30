/// 数据源 Runtime 连接与 Debug 检查页应用端口。
///
/// 职责：
/// - 将版本化 Runtime Facade 投影为主应用的窄类型与状态。
/// - 统一管理数据源操作和仅 Debug 的检查页开关。
///
/// 注意：
/// - 不暴露 Runtime 端口、控制协议、路径或资源 token。
/// - Debug 检查页的持久化开关仍由 Runtime 自有数据根拥有。
///
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

import 'plugin_runtime_models.dart';

export 'plugin_runtime_models.dart';

part 'plugin_runtime_source_actions.dart';

/// Narrow application port; main-project code never sees Runtime transport.
abstract interface class PluginRuntimeGateway {
  Future<PluginRuntimeConnection> inspect();

  Future<PluginInstallationSize> inspectInstallationSize({required String pluginId, required PluginInstallationSizeScope scope});

  Stream<RuntimeInitializationProgress> get initialization;

  Future<bool> importLocalPlugin();

  Future<bool> selectDevelopmentDirectory();

  Future<void> setEnabled({required String pluginId, required bool enabled});

  Future<void> scheduleUninstall({required String pluginId});

  Future<PluginCodeDirectoryKind> openCodeDirectory({required String pluginId});

  Future<String?> packageDevelopmentPlugin({required String pluginId});

  Future<void> openRuntimePrivateDirectory();

  Future<PluginRuntimeDebugHttp> setDebugHttpEnabled(bool enabled);

  Future<PluginRuntimeDebugHttp> inspectDebugHttp();
}

/// Optional event capability for the Windows Debug development lifecycle.
abstract interface class PluginRuntimeDevelopmentGateway {
  Stream<DevelopmentPluginChangeBatch> get developmentChanges;
}

/// Production adapter over the Runtime-owned, versioned Flutter Facade.
final class MgReadPluginRuntimeGateway implements PluginRuntimeGateway, PluginRuntimeDevelopmentGateway {
  MgReadPluginRuntimeGateway({PluginRuntime? runtime}) : _runtime = runtime ?? PluginRuntime();

  final PluginRuntime _runtime;

  @override
  Stream<RuntimeInitializationProgress> get initialization => _runtime.initialization;

  @override
  Stream<DevelopmentPluginChangeBatch> get developmentChanges => _runtime.developmentChanges;

  @override
  Future<PluginInstallationSize> inspectInstallationSize({required String pluginId, required PluginInstallationSizeScope scope}) async {
    try {
      return await _runtime.invoke(PluginInstallationSizeInvocation(pluginId: pluginId, scope: scope));
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<PluginRuntimeConnection> inspect() async {
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _runtime.invoke(const RuntimePingInvocation()),
        _runtime.invoke(const InstalledPluginsInvocation()),
        _runtime.invoke(const PluginStartupRecoveryInvocation()),
      ]);
      final ping = results[0] as RuntimePingResult;
      final plugins = results[1] as List<InstalledPlugin>;
      final recovery = results[2] as PluginStartupRecovery;
      return PluginRuntimeConnection(
        isHealthy: ping.isHealthy,
        nodeVersion: ping.nodeVersion,
        runtimeVersion: ping.runtimeVersion,
        startupRecovery: PluginRuntimeStartupRecovery(quarantinedCount: recovery.quarantinedCount),
        plugins: List<PluginRuntimePlugin>.unmodifiable(
          plugins.map(
            (plugin) => PluginRuntimePlugin(
              activeVersion: plugin.activeVersion,
              contentKinds: plugin.contentKinds,
              description: plugin.description,
              displayName: plugin.displayName,
              enabled: plugin.enabled,
              iconUrl: plugin.iconUrl,
              id: plugin.id,
              name: plugin.name,
              pendingVersion: plugin.pendingVersion,
              status: plugin.status,
            ),
          ),
        ),
      );
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<bool> importLocalPlugin() async {
    try {
      return await _runtime.importLocalPlugin();
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<bool> selectDevelopmentDirectory() async {
    try {
      return await _runtime.selectDevelopmentDirectory();
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<void> setEnabled({required String pluginId, required bool enabled}) async {
    try {
      await _runtime.invoke(SetPluginEnabledInvocation(pluginId: pluginId, enabled: enabled));
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<void> scheduleUninstall({required String pluginId}) async {
    try {
      await _runtime.invoke(SchedulePluginUninstallInvocation(pluginId: pluginId));
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({required String pluginId}) async {
    try {
      return await _runtime.invoke(OpenPluginCodeDirectoryInvocation(pluginId: pluginId));
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<String?> packageDevelopmentPlugin({required String pluginId}) async {
    try {
      return (await _runtime.packageDevelopmentPlugin(pluginId))?.fileName;
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<void> openRuntimePrivateDirectory() async {
    try {
      await _runtime.invoke(const OpenRuntimePrivateDirectoryInvocation());
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<PluginRuntimeDebugHttp> setDebugHttpEnabled(bool enabled) async {
    try {
      final status = await _runtime.setDebugHttpEnabled(enabled);
      return PluginRuntimeDebugHttp(
        configuredEnabled: status.configuredEnabled,
        enabled: status.enabled,
        endpoints: List<String>.unmodifiable(status.endpoints),
        startedAt: status.startedAt,
        usingTemporaryPort: status.usingTemporaryPort,
      );
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<PluginRuntimeDebugHttp> inspectDebugHttp() async {
    try {
      final status = await _runtime.debugHttpStatus();
      return PluginRuntimeDebugHttp(
        configuredEnabled: status.configuredEnabled,
        enabled: status.enabled,
        endpoints: List<String>.unmodifiable(status.endpoints),
        startedAt: status.startedAt,
        usingTemporaryPort: status.usingTemporaryPort,
      );
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }
}

/// Narrow application port for the expandable Runtime status projection.
///
/// Keeping this separate from source-management commands lets the status page
/// grow without widening every plugin-management test double and use case.
abstract interface class PluginRuntimeStatusGateway {
  Future<PluginRuntimeStatus> inspect();
}

final class MgReadPluginRuntimeStatusGateway implements PluginRuntimeStatusGateway {
  MgReadPluginRuntimeStatusGateway({PluginRuntime? runtime}) : _runtime = runtime ?? PluginRuntime();

  final PluginRuntime _runtime;

  @override
  Future<PluginRuntimeStatus> inspect() async {
    try {
      final result = await _runtime.invoke(const RuntimeStatusInvocation());
      return PluginRuntimeStatus(
        arch: result.arch,
        isHealthy: result.isHealthy,
        memory: PluginRuntimeMemory(
          arrayBuffers: result.memory.arrayBuffers,
          external: result.memory.external,
          heapTotal: result.memory.heapTotal,
          heapUsed: result.memory.heapUsed,
          rss: result.memory.rss,
        ),
        nodeVersion: result.nodeVersion,
        platform: result.platform,
        plugins: List<PluginRuntimePlugin>.unmodifiable(result.plugins.map(_toPluginRuntimePlugin)),
        runtimeVersion: result.runtimeVersion,
        runtimeKind: result.runtimeKind,
        uptime: Duration(milliseconds: result.uptimeMs),
      );
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }
}

PluginRuntimePlugin _toPluginRuntimePlugin(InstalledPlugin plugin) {
  return PluginRuntimePlugin(
    activeVersion: plugin.activeVersion,
    contentKinds: plugin.contentKinds,
    description: plugin.description,
    displayName: plugin.displayName,
    enabled: plugin.enabled,
    iconUrl: plugin.iconUrl,
    id: plugin.id,
    name: plugin.name,
    pendingVersion: plugin.pendingVersion,
    status: plugin.status,
  );
}

/// Collapses Runtime-internal startup detail into the app's stable UI taxonomy.
AppError normalizePluginRuntimeError(PluginRuntimeException error) {
  final code = switch (error.code) {
    'runtime_data_root_unavailable' ||
    'runtime_bundled_plugin_assets_missing' ||
    'runtime_entrypoint_missing' ||
    'runtime_exited_before_ready' ||
    'runtime_node_executable_missing' ||
    'runtime_process_exited' ||
    'runtime_process_launch_failed' ||
    'runtime_startup_channel_failed' => AppErrorCode.runtimeStartFailed,
    'runtime_http_readiness_failed' || 'runtime_invalid_ready_signal' || 'runtime_ready_timeout' => AppErrorCode.runtimeNotReady,
    'invalid_response' || 'plugin_invalid_response' => AppErrorCode.invalidFormat,
    'file_name_invalid' => AppErrorCode.fileNameInvalid,
    'file_unavailable' => AppErrorCode.fileUnavailable,
    'file_unreadable' => AppErrorCode.fileUnreadable,
    'file_too_large' => AppErrorCode.fileTooLarge,
    'file_read_failed' => AppErrorCode.fileReadFailed,
    'plugin_install_failed' || 'plugin_import_failed' => AppErrorCode.pluginInstallFailed,
    'plugin_load_failed' => AppErrorCode.pluginDamaged,
    'file_already_exists' => AppErrorCode.conflict,
    'file_write_failed' => AppErrorCode.fileUnavailable,
    'plugin_execution_failed' => AppErrorCode.pluginExecutionFailed,
    final value when value.startsWith('windows_job_object_') => AppErrorCode.runtimeStartFailed,
    _ => AppErrorCode.fromWireValue(error.code),
  };
  return AppError.fromCode(code);
}

/// Process-scoped public Facade shared by every main-application capability.
final pluginRuntimeFacadeProvider = Provider<PluginRuntime>((Ref ref) => PluginRuntime());

/// Path-free Windows Debug development-source events from the shared Facade.
/// Android exposes the same typed contract as an empty stream.
final pluginRuntimeDevelopmentChangesProvider = StreamProvider<DevelopmentPluginChangeBatch>((Ref ref) {
  final gateway = ref.watch(pluginRuntimeGatewayProvider);
  return gateway is PluginRuntimeDevelopmentGateway
      ? (gateway as PluginRuntimeDevelopmentGateway).developmentChanges
      : const Stream<DevelopmentPluginChangeBatch>.empty();
});

final pluginRuntimeGatewayProvider = Provider<PluginRuntimeGateway>(
  (Ref ref) => MgReadPluginRuntimeGateway(runtime: ref.watch(pluginRuntimeFacadeProvider)),
);

final pluginRuntimeStatusGatewayProvider = Provider<PluginRuntimeStatusGateway>(
  (Ref ref) => MgReadPluginRuntimeStatusGateway(runtime: ref.watch(pluginRuntimeFacadeProvider)),
);

/// One refreshable status snapshot for the dedicated Node Runtime page.
final pluginRuntimeStatusProvider = FutureProvider<PluginRuntimeStatus>((Ref ref) async {
  final gateway = ref.watch(pluginRuntimeStatusGatewayProvider);
  final diagnostics = ref.watch(diagnosticsManagerProvider);
  final span = diagnostics.startSpan(
    AppDiagnosticEvents.runtimeFacadeCall,
    attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
      'capability': DiagnosticValue.string('runtime.status.v1'),
      'resultState': DiagnosticValue.string('loading'),
    }),
  );
  try {
    final result = await gateway.inspect();
    span.complete(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.status.v1'),
        'pluginCount': DiagnosticValue.int64(result.plugins.length),
        'resultState': DiagnosticValue.string('success'),
      }),
    );
    return result;
  } on Object catch (error, stackTrace) {
    final appError = AppError.fromUnknown(error);
    span.fail(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.status.v1'),
        'errorCode': DiagnosticValue.string(appError.code.wireValue),
        'resultState': DiagnosticValue.string('failure'),
      }),
    );
    Error.throwWithStackTrace(appError, stackTrace);
  }
});

/// Process-wide Runtime readiness shared by app startup and every feature.
///
/// The app warms this after its first frame. Keeping the result alive avoids
/// restarting inspection when a feature is opened later, while concurrent
/// consumers still share the Runtime Facade's one startup operation.
final pluginRuntimeConnectionProvider = FutureProvider<PluginRuntimeConnection>((Ref ref) async {
  final gateway = ref.watch(pluginRuntimeGatewayProvider);
  final runtime = ref.watch(pluginRuntimeFacadeProvider);
  final proxyManager = ref.watch(configuredFlutterNetworkProxyManagerProvider);
  await runtime.configureFlutterTransportProxy(await proxyManager.proxyUriFor(NetworkProxyTraffic.runtime));
  final diagnostics = ref.watch(diagnosticsManagerProvider);
  final span = diagnostics.startSpan(
    AppDiagnosticEvents.runtimeFacadeCall,
    attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
      'capability': DiagnosticValue.string('runtime.inspect.v1'),
      'attempt': DiagnosticValue.int64(1),
      'resultState': DiagnosticValue.string('loading'),
    }),
  );
  final stopwatch = Stopwatch()..start();
  try {
    final result = await gateway.inspect();
    span.complete(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.inspect.v1'),
        'attempt': DiagnosticValue.int64(1),
        'pluginCount': DiagnosticValue.int64(result.plugins.length),
        'resultState': DiagnosticValue.string(result.plugins.isEmpty ? 'empty' : 'content'),
      }),
    );
    stopwatch.stop();
    reportSlowDiagnostic(
      diagnostics,
      subjectComponent: 'feature.plugins',
      operation: 'runtime.inspect.v1',
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.runtimeFacade,
      outcome: DiagnosticOutcome.success,
      traceContext: span.traceContext,
    );
    return result;
  } on Object catch (error, stackTrace) {
    final appError = AppError.fromUnknown(error);
    span.fail(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.inspect.v1'),
        'attempt': DiagnosticValue.int64(1),
        'resultState': DiagnosticValue.string('failure'),
        'errorCode': DiagnosticValue.string(appError.code.wireValue),
      }),
    );
    stopwatch.stop();
    reportSlowDiagnostic(
      diagnostics,
      subjectComponent: 'feature.plugins',
      operation: 'runtime.inspect.v1',
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.runtimeFacade,
      outcome: DiagnosticOutcome.error,
      traceContext: span.traceContext,
    );
    Error.throwWithStackTrace(appError, stackTrace);
  }
});

final pluginRuntimeSourceDataSizeProvider = FutureProvider.autoDispose.family<PluginInstallationSize, String>(
  (Ref ref, String pluginId) =>
      ref.read(pluginRuntimeGatewayProvider).inspectInstallationSize(pluginId: pluginId, scope: PluginInstallationSizeScope.data),
);

final pluginRuntimeSourceArchiveSizeProvider = FutureProvider.autoDispose.family<PluginInstallationSize, String>(
  (Ref ref, String pluginId) =>
      ref.read(pluginRuntimeGatewayProvider).inspectInstallationSize(pluginId: pluginId, scope: PluginInstallationSizeScope.archive),
);

final pluginRuntimeSourceNpmSizeProvider = FutureProvider.autoDispose.family<PluginInstallationSize, String>(
  (Ref ref, String pluginId) =>
      ref.read(pluginRuntimeGatewayProvider).inspectInstallationSize(pluginId: pluginId, scope: PluginInstallationSizeScope.npm),
);

/// Serializes Runtime-owned Windows source-directory actions per plugin.
final pluginRuntimeSourceDirectoryProvider = NotifierProvider<PluginRuntimeSourceDirectoryController, Set<String>>(
  PluginRuntimeSourceDirectoryController.new,
);

/// Serializes user-triggered development-source packaging without exposing the output path.
final pluginRuntimeDevelopmentPackageProvider = NotifierProvider<PluginRuntimeDevelopmentPackageController, Set<String>>(
  PluginRuntimeDevelopmentPackageController.new,
);

/// Serializes the Windows-only Runtime private-directory shell action.
final pluginRuntimePrivateDirectoryProvider = NotifierProvider<PluginRuntimePrivateDirectoryController, bool>(
  PluginRuntimePrivateDirectoryController.new,
);

/// Imports one user-selected `.mgplugin.js` or `.mgplugin` and waits for cold activation.
final pluginRuntimeSourceImportProvider = NotifierProvider<PluginRuntimeSourceImportController, PluginSourceImportState>(
  PluginRuntimeSourceImportController.new,
);

final class PluginSourceImportState {
  const PluginSourceImportState({required this.isImporting, required this.message, this.logs = const <String>[], this.fraction});

  const PluginSourceImportState.idle() : isImporting = false, message = '', logs = const <String>[], fraction = null;

  final bool isImporting;
  final String message;
  final List<String> logs;
  final double? fraction;

  PluginSourceImportState copyWith({bool? isImporting, List<String>? logs, String? message, double? fraction}) {
    return PluginSourceImportState(
      isImporting: isImporting ?? this.isImporting,
      logs: logs ?? this.logs,
      message: message ?? this.message,
      fraction: fraction ?? this.fraction,
    );
  }
}

final class PluginRuntimeSourceImportController extends Notifier<PluginSourceImportState> {
  @override
  PluginSourceImportState build() {
    final subscription = ref.read(pluginRuntimeGatewayProvider).initialization.listen(_onInitializationProgress);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return const PluginSourceImportState.idle();
  }

  void _onInitializationProgress(RuntimeInitializationProgress progress) {
    if (!state.isImporting) return;
    final message = progress.detail ?? _initializationMessage(progress.stage);
    state = PluginSourceImportState(
      isImporting: true,
      message: message,
      logs: _appendImportLog(state.logs, message),
      fraction: progress.fraction,
    );
  }

  Future<bool> importLocalPlugin() async {
    if (state.isImporting) return false;
    state = const PluginSourceImportState(isImporting: true, message: '正在打开文件选择器', logs: <String>['正在打开文件选择器']);
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.plugins.importLocal.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final imported = await ref.read(pluginRuntimeGatewayProvider).importLocalPlugin();
      if (imported) {
        state = const PluginSourceImportState(isImporting: true, message: '正在刷新数据源列表', logs: <String>['正在刷新数据源列表']);
        ref.invalidate(pluginRuntimeConnectionProvider);
        ref.invalidate(pluginRuntimeStatusProvider);
        await ref.read(pluginRuntimeConnectionProvider.future);
      }
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.importLocal.v1'),
          'resultState': DiagnosticValue.string(imported ? 'success' : 'cancelled'),
        }),
      );
      return imported;
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.importLocal.v1'),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    } finally {
      state = const PluginSourceImportState.idle();
    }
  }
}

String _initializationMessage(RuntimeInitializationStage stage) {
  return switch (stage) {
    RuntimeInitializationStage.assetsCopying => '正在准备 Runtime 文件',
    RuntimeInitializationStage.assetsCopied => 'Runtime 文件准备完成',
    RuntimeInitializationStage.assetsReused => '正在复用 Runtime 文件',
    RuntimeInitializationStage.nodeStarting => '正在启动 Node Runtime',
    RuntimeInitializationStage.pluginCopying => '正在复制数据源插件文件',
    RuntimeInitializationStage.pluginCopied => '数据源插件文件复制完成',
    RuntimeInitializationStage.pluginInstalling => '正在安装数据源插件',
    RuntimeInitializationStage.ready => '数据源运行环境已就绪',
  };
}

List<String> _appendImportLog(List<String> current, String message) {
  if (current.isNotEmpty && current.last == message) return current;
  final next = <String>[...current, message];
  if (next.length <= 12) return List<String>.unmodifiable(next);
  return List<String>.unmodifiable(next.sublist(next.length - 12));
}

/// Selects and activates a Windows Debug development-source directory.
final pluginRuntimeDevelopmentDirectoryProvider = NotifierProvider<PluginRuntimeDevelopmentDirectoryController, bool>(
  PluginRuntimeDevelopmentDirectoryController.new,
);

final class PluginRuntimeDevelopmentDirectoryController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<bool> selectDirectory() async {
    if (state) return false;
    state = true;
    try {
      final selected = await ref.read(pluginRuntimeGatewayProvider).selectDevelopmentDirectory();
      if (selected) {
        ref.invalidate(pluginRuntimeConnectionProvider);
        ref.invalidate(pluginRuntimeStatusProvider);
        await ref.read(pluginRuntimeConnectionProvider.future);
      }
      return selected;
    } finally {
      state = false;
    }
  }
}

final class PluginRuntimeSourceDirectoryController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  Future<PluginCodeDirectoryKind> open({required String pluginId}) async {
    if (state.contains(pluginId)) {
      throw AppError.fromCode(AppErrorCode.conflict);
    }
    state = Set<String>.unmodifiable(<String>{...state, pluginId});
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.plugins.openCodeDirectory.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final result = await ref.read(pluginRuntimeGatewayProvider).openCodeDirectory(pluginId: pluginId);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.openCodeDirectory.v1'),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
      return result;
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.openCodeDirectory.v1'),
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

final class PluginRuntimeDevelopmentPackageController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  Future<String?> package({required String pluginId}) async {
    if (state.contains(pluginId)) return null;
    state = Set<String>.unmodifiable(<String>{...state, pluginId});
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.plugins.developmentPackage.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final fileName = await ref.read(pluginRuntimeGatewayProvider).packageDevelopmentPlugin(pluginId: pluginId);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.developmentPackage.v1'),
          'resultState': DiagnosticValue.string(fileName == null ? 'cancelled' : 'success'),
        }),
      );
      return fileName;
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.developmentPackage.v1'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
          'resultState': DiagnosticValue.string('failure'),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    } finally {
      state = Set<String>.unmodifiable(state.where((String value) => value != pluginId));
    }
  }
}

final class PluginRuntimePrivateDirectoryController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> open() async {
    if (state) throw AppError.fromCode(AppErrorCode.conflict);
    state = true;
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.openPrivateDirectory.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      await ref.read(pluginRuntimeGatewayProvider).openRuntimePrivateDirectory();
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.openPrivateDirectory.v1'),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.openPrivateDirectory.v1'),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    } finally {
      state = false;
    }
  }
}

/// Main-app projection of the Runtime-owned persisted Debug preference and listener.
final class PluginRuntimeDebugHttp {
  const PluginRuntimeDebugHttp({
    required this.configuredEnabled,
    required this.enabled,
    required this.endpoints,
    required this.startedAt,
    required this.usingTemporaryPort,
  });

  const PluginRuntimeDebugHttp.disabled()
    : configuredEnabled = false,
      enabled = false,
      endpoints = const <String>[],
      startedAt = null,
      usingTemporaryPort = false;

  final bool configuredEnabled;
  final bool enabled;
  final List<String> endpoints;
  final String? startedAt;
  final bool usingTemporaryPort;
}
