import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';

/// Narrow application port; main-project code never sees Runtime transport.
abstract interface class PluginRuntimeGateway {
  Future<PluginRuntimeConnection> inspect();

  Future<void> setEnabled({required String pluginId, required bool enabled});
}

/// Production adapter over the Runtime-owned, versioned Flutter Facade.
final class MgReadPluginRuntimeGateway implements PluginRuntimeGateway {
  MgReadPluginRuntimeGateway({PluginRuntime? runtime})
    : _runtime = runtime ?? PluginRuntime();

  final PluginRuntime _runtime;

  @override
  Future<PluginRuntimeConnection> inspect() async {
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _runtime.invoke(const RuntimePingInvocation()),
        _runtime.invoke(const InstalledPluginsInvocation()),
      ]);
      final ping = results[0] as RuntimePingResult;
      final plugins = results[1] as List<InstalledPlugin>;
      return PluginRuntimeConnection(
        isHealthy: ping.isHealthy,
        nodeVersion: ping.nodeVersion,
        runtimeVersion: ping.runtimeVersion,
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
    'plugin_load_failed' => AppErrorCode.pluginDamaged,
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

/// Serializes real source enable/disable requests and refreshes the shared
/// Runtime projection only after the Runtime acknowledges the persisted state.
final pluginRuntimeSourceActionProvider =
    NotifierProvider<PluginRuntimeSourceActionController, Set<String>>(
      PluginRuntimeSourceActionController.new,
    );

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

@immutable
final class PluginRuntimeConnection {
  const PluginRuntimeConnection({
    required this.isHealthy,
    required this.nodeVersion,
    required this.runtimeVersion,
    required this.plugins,
  });

  final bool isHealthy;
  final String nodeVersion;
  final String runtimeVersion;
  final List<PluginRuntimePlugin> plugins;
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
