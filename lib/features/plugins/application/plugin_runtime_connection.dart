import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';

/// Narrow application port; main-project code never sees Runtime transport.
abstract interface class PluginRuntimeGateway {
  Future<PluginRuntimeConnection> inspect();

  Future<PluginInstallationSize> inspectInstallationSize({
    required String pluginId,
    required PluginInstallationSizeScope scope,
  });

  Stream<RuntimeInitializationProgress> get initialization;

  Future<bool> importLocalPlugin();

  Future<bool> selectDevelopmentDirectory();

  Future<void> setEnabled({required String pluginId, required bool enabled});

  Future<PluginCodeDirectoryKind> openCodeDirectory({required String pluginId});

  Future<void> openRuntimePrivateDirectory();
}

/// Production adapter over the Runtime-owned, versioned Flutter Facade.
final class MgReadPluginRuntimeGateway implements PluginRuntimeGateway {
  MgReadPluginRuntimeGateway({PluginRuntime? runtime})
    : _runtime = runtime ?? PluginRuntime();

  final PluginRuntime _runtime;

  @override
  Stream<RuntimeInitializationProgress> get initialization =>
      _runtime.initialization;

  @override
  Future<PluginInstallationSize> inspectInstallationSize({
    required String pluginId,
    required PluginInstallationSizeScope scope,
  }) async {
    try {
      return await _runtime.invoke(
        PluginInstallationSizeInvocation(pluginId: pluginId, scope: scope),
      );
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
        startupRecovery: PluginRuntimeStartupRecovery(
          quarantinedCount: recovery.quarantinedCount,
        ),
        plugins: List<PluginRuntimePlugin>.unmodifiable(
          plugins.map(
            (plugin) => PluginRuntimePlugin(
              activeVersion: plugin.activeVersion,
              contentKinds: plugin.contentKinds,
              displayName: plugin.displayName,
              enabled: plugin.enabled,
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
  Future<void> setEnabled({
    required String pluginId,
    required bool enabled,
  }) async {
    try {
      await _runtime.invoke(
        SetPluginEnabledInvocation(pluginId: pluginId, enabled: enabled),
      );
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }

  @override
  Future<PluginCodeDirectoryKind> openCodeDirectory({
    required String pluginId,
  }) async {
    try {
      return await _runtime.invoke(
        OpenPluginCodeDirectoryInvocation(pluginId: pluginId),
      );
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
}

/// Narrow application port for the expandable Runtime status projection.
///
/// Keeping this separate from source-management commands lets the status page
/// grow without widening every plugin-management test double and use case.
abstract interface class PluginRuntimeStatusGateway {
  Future<PluginRuntimeStatus> inspect();
}

final class MgReadPluginRuntimeStatusGateway
    implements PluginRuntimeStatusGateway {
  MgReadPluginRuntimeStatusGateway({PluginRuntime? runtime})
    : _runtime = runtime ?? PluginRuntime();

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
        plugins: List<PluginRuntimePlugin>.unmodifiable(
          result.plugins.map(_toPluginRuntimePlugin),
        ),
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
    displayName: plugin.displayName,
    enabled: plugin.enabled,
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
    'runtime_http_readiness_failed' ||
    'runtime_invalid_ready_signal' ||
    'runtime_ready_timeout' => AppErrorCode.runtimeNotReady,
    'invalid_response' ||
    'plugin_invalid_response' => AppErrorCode.invalidFormat,
    'file_name_invalid' => AppErrorCode.fileNameInvalid,
    'file_unavailable' => AppErrorCode.fileUnavailable,
    'file_unreadable' => AppErrorCode.fileUnreadable,
    'file_too_large' => AppErrorCode.fileTooLarge,
    'file_read_failed' => AppErrorCode.fileReadFailed,
    'plugin_install_failed' ||
    'plugin_import_failed' => AppErrorCode.pluginInstallFailed,
    'plugin_load_failed' => AppErrorCode.pluginDamaged,
    'plugin_execution_failed' => AppErrorCode.pluginExecutionFailed,
    final value when value.startsWith('windows_job_object_') =>
      AppErrorCode.runtimeStartFailed,
    _ => AppErrorCode.fromWireValue(error.code),
  };
  return AppError.fromCode(code);
}

/// Process-scoped public Facade shared by every main-application capability.
final pluginRuntimeFacadeProvider = Provider<PluginRuntime>(
  (Ref ref) => PluginRuntime(),
);

final pluginRuntimeGatewayProvider = Provider<PluginRuntimeGateway>(
  (Ref ref) => MgReadPluginRuntimeGateway(
    runtime: ref.watch(pluginRuntimeFacadeProvider),
  ),
);

final pluginRuntimeStatusGatewayProvider = Provider<PluginRuntimeStatusGateway>(
  (Ref ref) => MgReadPluginRuntimeStatusGateway(
    runtime: ref.watch(pluginRuntimeFacadeProvider),
  ),
);

/// One refreshable status snapshot for the dedicated Node Runtime page.
final pluginRuntimeStatusProvider = FutureProvider<PluginRuntimeStatus>((
  Ref ref,
) async {
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
final pluginRuntimeConnectionProvider = FutureProvider<PluginRuntimeConnection>(
  (Ref ref) async {
    final gateway = ref.watch(pluginRuntimeGatewayProvider);
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
          'resultState': DiagnosticValue.string(
            result.plugins.isEmpty ? 'empty' : 'content',
          ),
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
  },
);

final pluginRuntimeSourceDataSizeProvider = FutureProvider.autoDispose
    .family<PluginInstallationSize, String>(
      (Ref ref, String pluginId) => ref
          .read(pluginRuntimeGatewayProvider)
          .inspectInstallationSize(
            pluginId: pluginId,
            scope: PluginInstallationSizeScope.data,
          ),
    );

final pluginRuntimeSourceArchiveSizeProvider = FutureProvider.autoDispose
    .family<PluginInstallationSize, String>(
      (Ref ref, String pluginId) => ref
          .read(pluginRuntimeGatewayProvider)
          .inspectInstallationSize(
            pluginId: pluginId,
            scope: PluginInstallationSizeScope.archive,
          ),
    );

final pluginRuntimeSourceNpmSizeProvider = FutureProvider.autoDispose
    .family<PluginInstallationSize, String>(
      (Ref ref, String pluginId) => ref
          .read(pluginRuntimeGatewayProvider)
          .inspectInstallationSize(
            pluginId: pluginId,
            scope: PluginInstallationSizeScope.npm,
          ),
    );

/// Serializes real source enable/disable requests and refreshes the shared
/// Runtime projection only after the Runtime acknowledges the persisted state.
final pluginRuntimeSourceActionProvider =
    NotifierProvider<PluginRuntimeSourceActionController, Set<String>>(
      PluginRuntimeSourceActionController.new,
    );

/// Serializes Runtime-owned Windows source-directory actions per plugin.
final pluginRuntimeSourceDirectoryProvider =
    NotifierProvider<PluginRuntimeSourceDirectoryController, Set<String>>(
      PluginRuntimeSourceDirectoryController.new,
    );

/// Serializes the Windows-only Runtime private-directory shell action.
final pluginRuntimePrivateDirectoryProvider =
    NotifierProvider<PluginRuntimePrivateDirectoryController, bool>(
      PluginRuntimePrivateDirectoryController.new,
    );

/// Imports one user-selected local `.mgplugin` and waits for cold activation.
final pluginRuntimeSourceImportProvider =
    NotifierProvider<
      PluginRuntimeSourceImportController,
      PluginSourceImportState
    >(PluginRuntimeSourceImportController.new);

final class PluginSourceImportState {
  const PluginSourceImportState({
    required this.isImporting,
    required this.message,
    this.logs = const <String>[],
    this.fraction,
  });

  const PluginSourceImportState.idle()
    : isImporting = false,
      message = '',
      logs = const <String>[],
      fraction = null;

  final bool isImporting;
  final String message;
  final List<String> logs;
  final double? fraction;

  PluginSourceImportState copyWith({
    bool? isImporting,
    List<String>? logs,
    String? message,
    double? fraction,
  }) {
    return PluginSourceImportState(
      isImporting: isImporting ?? this.isImporting,
      logs: logs ?? this.logs,
      message: message ?? this.message,
      fraction: fraction ?? this.fraction,
    );
  }
}

final class PluginRuntimeSourceImportController
    extends Notifier<PluginSourceImportState> {
  @override
  PluginSourceImportState build() {
    final subscription = ref
        .read(pluginRuntimeGatewayProvider)
        .initialization
        .listen(_onInitializationProgress);
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
    state = const PluginSourceImportState(
      isImporting: true,
      message: '正在打开文件选择器',
      logs: <String>['正在打开文件选择器'],
    );
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.plugins.importLocal.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final imported = await ref
          .read(pluginRuntimeGatewayProvider)
          .importLocalPlugin();
      if (imported) {
        state = const PluginSourceImportState(
          isImporting: true,
          message: '正在刷新数据来源列表',
          logs: <String>['正在刷新数据来源列表'],
        );
        ref.invalidate(pluginRuntimeConnectionProvider);
        ref.invalidate(pluginRuntimeStatusProvider);
        await ref.read(pluginRuntimeConnectionProvider.future);
      }
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(
            'runtime.plugins.importLocal.v1',
          ),
          'resultState': DiagnosticValue.string(
            imported ? 'success' : 'cancelled',
          ),
        }),
      );
      return imported;
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(
            'runtime.plugins.importLocal.v1',
          ),
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
    RuntimeInitializationStage.pluginCopying => '正在复制数据来源文件',
    RuntimeInitializationStage.pluginCopied => '数据来源文件复制完成',
    RuntimeInitializationStage.pluginInstalling => '正在安装数据来源并初始化 npm',
    RuntimeInitializationStage.ready => '数据来源运行环境已就绪',
  };
}

List<String> _appendImportLog(List<String> current, String message) {
  if (current.isNotEmpty && current.last == message) return current;
  final next = <String>[...current, message];
  if (next.length <= 12) return List<String>.unmodifiable(next);
  return List<String>.unmodifiable(next.sublist(next.length - 12));
}

/// Selects and activates a Windows Debug development-source directory.
final pluginRuntimeDevelopmentDirectoryProvider =
    NotifierProvider<PluginRuntimeDevelopmentDirectoryController, bool>(
      PluginRuntimeDevelopmentDirectoryController.new,
    );

final class PluginRuntimeDevelopmentDirectoryController extends Notifier<bool> {
  @override
  bool build() => false;

  Future<bool> selectDirectory() async {
    if (state) return false;
    state = true;
    try {
      final selected = await ref
          .read(pluginRuntimeGatewayProvider)
          .selectDevelopmentDirectory();
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

final class PluginRuntimeSourceActionController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  Future<void> setEnabled({
    required String pluginId,
    required bool enabled,
  }) async {
    if (state.contains(pluginId)) return;
    state = Set<String>.unmodifiable(<String>{...state, pluginId});
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string('runtime.plugins.setEnabled.v1'),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      await ref
          .read(pluginRuntimeGatewayProvider)
          .setEnabled(pluginId: pluginId, enabled: enabled);
      ref.invalidate(pluginRuntimeConnectionProvider);
      ref.invalidate(pluginRuntimeStatusProvider);
      await ref.read(pluginRuntimeConnectionProvider.future);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.setEnabled.v1'),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string('runtime.plugins.setEnabled.v1'),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    } finally {
      state = Set<String>.unmodifiable(
        state.where((String value) => value != pluginId),
      );
    }
  }
}

final class PluginRuntimeSourceDirectoryController
    extends Notifier<Set<String>> {
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
        'capability': DiagnosticValue.string(
          'runtime.plugins.openCodeDirectory.v1',
        ),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final result = await ref
          .read(pluginRuntimeGatewayProvider)
          .openCodeDirectory(pluginId: pluginId);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(
            'runtime.plugins.openCodeDirectory.v1',
          ),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
      return result;
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(
            'runtime.plugins.openCodeDirectory.v1',
          ),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
        }),
      );
      Error.throwWithStackTrace(appError, stackTrace);
    } finally {
      state = Set<String>.unmodifiable(
        state.where((String value) => value != pluginId),
      );
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
      await ref
          .read(pluginRuntimeGatewayProvider)
          .openRuntimePrivateDirectory();
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(
            'runtime.openPrivateDirectory.v1',
          ),
          'resultState': DiagnosticValue.string('success'),
        }),
      );
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(
            'runtime.openPrivateDirectory.v1',
          ),
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

@immutable
final class PluginRuntimeConnection {
  const PluginRuntimeConnection({
    required this.isHealthy,
    required this.nodeVersion,
    required this.runtimeVersion,
    required this.plugins,
    this.startupRecovery = const PluginRuntimeStartupRecovery(
      quarantinedCount: 0,
    ),
  });

  final bool isHealthy;
  final String nodeVersion;
  final String runtimeVersion;
  final List<PluginRuntimePlugin> plugins;
  final PluginRuntimeStartupRecovery startupRecovery;
}

@immutable
final class PluginRuntimeStartupRecovery {
  const PluginRuntimeStartupRecovery({required this.quarantinedCount});

  final int quarantinedCount;
}

@immutable
final class PluginRuntimeStatus {
  const PluginRuntimeStatus({
    required this.arch,
    required this.isHealthy,
    required this.memory,
    required this.nodeVersion,
    required this.platform,
    required this.plugins,
    required this.runtimeVersion,
    required this.runtimeKind,
    required this.uptime,
  });

  final String arch;
  final bool isHealthy;
  final PluginRuntimeMemory memory;
  final String nodeVersion;
  final String platform;
  final List<PluginRuntimePlugin> plugins;
  final String runtimeVersion;
  final String runtimeKind;
  final Duration uptime;
}

@immutable
final class PluginRuntimeMemory {
  const PluginRuntimeMemory({
    required this.arrayBuffers,
    required this.external,
    required this.heapTotal,
    required this.heapUsed,
    required this.rss,
  });

  final int arrayBuffers;
  final int external;
  final int heapTotal;
  final int heapUsed;
  final int rss;
}

@immutable
final class PluginRuntimePlugin {
  const PluginRuntimePlugin({
    required this.activeVersion,
    required this.contentKinds,
    required this.displayName,
    required this.enabled,
    required this.id,
    required this.name,
    required this.pendingVersion,
    required this.status,
  });

  final String? activeVersion;
  final List<String> contentKinds;
  final String displayName;
  final bool enabled;
  final String id;
  final String name;
  final String? pendingVersion;
  final String status;
}
