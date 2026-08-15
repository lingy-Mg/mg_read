import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';

/// Narrow application port; main-project code never sees Runtime transport.
abstract interface class PluginRuntimeGateway {
  Future<PluginRuntimeConnection> inspect();
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
}

/// Collapses Runtime-internal startup detail into the app's stable UI taxonomy.
AppError normalizePluginRuntimeError(PluginRuntimeException error) {
  final code = switch (error.code) {
    'runtime_data_root_unavailable' ||
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

/// Lazily starts Runtime only when a UI capability reads this provider.
final pluginRuntimeConnectionProvider =
    FutureProvider.autoDispose<PluginRuntimeConnection>((Ref ref) async {
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
    });

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
