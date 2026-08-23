import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

/// Narrow application port for Runtime-owned source cache maintenance.
abstract interface class PluginCacheGateway {
  Future<List<PluginCacheUsage>> listUsage();

  Future<PluginCacheClearResult> clearAll();

  Future<PluginCacheClearResult> clearPlugin(String pluginId);
}

/// Production adapter that preserves the Runtime's cache-directory boundary.
final class MgReadPluginCacheGateway implements PluginCacheGateway {
  MgReadPluginCacheGateway({PluginRuntime? runtime})
    : _runtime = runtime ?? PluginRuntime();

  final PluginRuntime _runtime;

  @override
  Future<List<PluginCacheUsage>> listUsage() =>
      _invoke(() => _runtime.invoke(const PluginCacheUsageInvocation()));

  @override
  Future<PluginCacheClearResult> clearAll() =>
      _invoke(() => _runtime.invoke(const ClearAllPluginCachesInvocation()));

  @override
  Future<PluginCacheClearResult> clearPlugin(String pluginId) => _invoke(
    () => _runtime.invoke(ClearPluginCacheInvocation(pluginId: pluginId)),
  );

  Future<T> _invoke<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PluginRuntimeException catch (error) {
      throw normalizePluginRuntimeError(error);
    } on Object catch (error) {
      throw AppError.fromUnknown(error);
    }
  }
}

final pluginCacheGatewayProvider = Provider<PluginCacheGateway>(
  (Ref ref) =>
      MgReadPluginCacheGateway(runtime: ref.watch(pluginRuntimeFacadeProvider)),
);

final pluginCacheManagementProvider =
    AsyncNotifierProvider<
      PluginCacheManagementController,
      PluginCacheManagementState
    >(PluginCacheManagementController.new);

/// Owns loading, confirmation result feedback and stale-result protection.
final class PluginCacheManagementController
    extends AsyncNotifier<PluginCacheManagementState> {
  int _generation = 0;

  @override
  Future<PluginCacheManagementState> build() => _load();

  Future<void> refresh() async {
    final current = _currentState();
    if (current?.isClearing == true || current?.isRefreshing == true) return;
    if (current == null && state is AsyncLoading<PluginCacheManagementState>) {
      return;
    }
    final generation = ++_generation;
    if (current == null) {
      state = const AsyncLoading<PluginCacheManagementState>();
    } else {
      state = AsyncData(current.copyWith(isRefreshing: true));
    }
    try {
      final result = await _load();
      if (generation == _generation) {
        state = AsyncData(result.copyWith(isRefreshing: false));
      }
    } on Object catch (error, stackTrace) {
      if (generation == _generation) {
        state = current == null
            ? AsyncError<PluginCacheManagementState>(error, stackTrace)
            : AsyncData(current.copyWith(isRefreshing: false));
      }
    }
  }

  Future<void> clearPlugin(String pluginId) => _clear(
    pluginIds: <String>{pluginId},
    capability: 'runtime.plugins.cache.clear.v1',
    operation: () => ref.read(pluginCacheGatewayProvider).clearPlugin(pluginId),
  );

  Future<void> clearAll() => _clear(
    pluginIds:
        _currentState()?.entries.map((entry) => entry.pluginId).toSet() ??
        const <String>{},
    capability: 'runtime.plugins.cache.clearAll.v1',
    operation: () => ref.read(pluginCacheGatewayProvider).clearAll(),
  );

  Future<PluginCacheManagementState> _load() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      ref.read(pluginCacheGatewayProvider).listUsage(),
      ref.read(pluginRuntimeConnectionProvider.future),
    ]);
    final usages = results[0] as List<PluginCacheUsage>;
    final connection = results[1] as PluginRuntimeConnection;
    final names = <String, String>{
      for (final plugin in connection.plugins) plugin.id: plugin.displayName,
    };
    return PluginCacheManagementState(
      entries: List<PluginCacheEntry>.unmodifiable(
        usages
            .map(
              (usage) => PluginCacheEntry(
                pluginId: usage.pluginId,
                displayName: names[usage.pluginId] ?? usage.pluginId,
                bytes: usage.bytes,
              ),
            )
            .toList()
          ..sort(
            (left, right) => left.displayName.compareTo(right.displayName),
          ),
      ),
    );
  }

  Future<void> _clear({
    required Set<String> pluginIds,
    required String capability,
    required Future<PluginCacheClearResult> Function() operation,
  }) async {
    final current = _currentState();
    if (current == null || current.isClearing) return;
    final generation = ++_generation;
    state = AsyncData(current.copyWith(clearingPluginIds: pluginIds));
    final diagnostics = ref.read(diagnosticsManagerProvider);
    final span = diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string(capability),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    try {
      final result = await operation();
      final failed = result.items
          .where((item) => item.status == PluginCacheClearStatus.failed)
          .length;
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(capability),
          'pluginCount': DiagnosticValue.int64(result.items.length),
          'resultState': DiagnosticValue.string(
            failed == 0 ? 'success' : 'partialFailure',
          ),
        }),
      );
      final reloaded = await _load();
      if (generation == _generation) {
        state = AsyncData(
          reloaded.copyWith(
            feedback: failed == 0
                ? PluginCacheFeedback.success(result.items)
                : PluginCacheFeedback.partialFailure(result.items),
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      final appError = AppError.fromUnknown(error);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(capability),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
          'resultState': DiagnosticValue.string('failure'),
        }),
      );
      if (generation == _generation) {
        state = AsyncData(
          current.copyWith(
            feedback: const PluginCacheFeedback.requestFailure(),
            clearingPluginIds: const <String>{},
          ),
        );
      }
      Error.throwWithStackTrace(appError, stackTrace);
    }
  }

  PluginCacheManagementState? _currentState() => switch (state) {
    AsyncData<PluginCacheManagementState>(:final value) => value,
    _ => null,
  };
}

@immutable
final class PluginCacheManagementState {
  const PluginCacheManagementState({
    required this.entries,
    this.clearingPluginIds = const <String>{},
    this.feedback,
    this.isRefreshing = false,
  });

  final List<PluginCacheEntry> entries;
  final Set<String> clearingPluginIds;
  final PluginCacheFeedback? feedback;
  final bool isRefreshing;

  int get totalBytes => entries.fold(0, (total, entry) => total + entry.bytes);
  bool get isClearing => clearingPluginIds.isNotEmpty;

  PluginCacheManagementState copyWith({
    List<PluginCacheEntry>? entries,
    Set<String>? clearingPluginIds,
    PluginCacheFeedback? feedback,
    bool? isRefreshing,
  }) => PluginCacheManagementState(
    entries: entries ?? this.entries,
    clearingPluginIds: clearingPluginIds ?? this.clearingPluginIds,
    feedback: feedback ?? this.feedback,
    isRefreshing: isRefreshing ?? this.isRefreshing,
  );
}

@immutable
final class PluginCacheEntry {
  const PluginCacheEntry({
    required this.pluginId,
    required this.displayName,
    required this.bytes,
  });

  final String pluginId;
  final String displayName;
  final int bytes;
}

enum PluginCacheFeedbackKind { success, partialFailure, requestFailure }

@immutable
final class PluginCacheFeedback {
  const PluginCacheFeedback._(this.kind, this.items);
  const PluginCacheFeedback.success(List<PluginCacheClearItem> items)
    : this._(PluginCacheFeedbackKind.success, items);
  const PluginCacheFeedback.partialFailure(List<PluginCacheClearItem> items)
    : this._(PluginCacheFeedbackKind.partialFailure, items);
  const PluginCacheFeedback.requestFailure()
    : this._(
        PluginCacheFeedbackKind.requestFailure,
        const <PluginCacheClearItem>[],
      );

  final PluginCacheFeedbackKind kind;
  final List<PluginCacheClearItem> items;
}
