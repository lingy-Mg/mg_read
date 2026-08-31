/// 数据源内容网关。
///
/// 职责：
/// - 通过强类型 Runtime Facade 查询搜索、发现与详情内容。
/// - 透传数据源图标元数据，并返回不等待封面字节的内容投影，使页面可先显示主体。
///
/// 注意：
/// - 封面由共享展示组件异步解析，网关不得耦合持久化或网络读取。
/// - 仅在这里将 Runtime 失败归一化为应用错误。
///
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

// The adapter keeps its implementation field private while exposing a named
// dependency for the composition root.
// ignore_for_file: prefer_initializing_formals

/// App-visible projection of one enabled source-capable plugin.
@immutable
final class PluginSourceDescriptor {
  PluginSourceDescriptor({
    required this.id,
    required this.displayName,
    required Iterable<PluginContentKind> contentKinds,
    this.description,
    this.iconUrl,
    this.pluginVersion = 'unknown',
  }) : contentKinds = List<PluginContentKind>.unmodifiable(contentKinds);

  final String id;
  final String displayName;
  final String? description;
  final String? iconUrl;
  final String pluginVersion;
  final List<PluginContentKind> contentKinds;
}

/// Narrow application port over the versioned public Runtime Facade.
///
/// Every returned model is already strongly decoded. Widgets never receive a
/// raw protocol map, transport handle, path, port, or process identifier.
abstract interface class SourceContentGateway {
  Future<List<PluginSourceDescriptor>> listSources();

  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20});

  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20});

  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  });

  Future<PluginContentDetail> getDetail({required String pluginId, required String id});

  Future<PluginChaptersResult> getChapters({required String pluginId, required String id});

  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId});
}

/// Production adapter. Runtime owns execution and transport; this adapter owns
/// only application error normalization and the main-app Facade span.
final class MgReadSourceContentGateway implements SourceContentGateway {
  const MgReadSourceContentGateway(this._runtime, this._diagnostics, this._loadRuntimeConnection);

  final PluginRuntime _runtime;
  final DiagnosticsManager _diagnostics;
  final Future<PluginRuntimeConnection> Function() _loadRuntimeConnection;

  @override
  Future<List<PluginSourceDescriptor>> listSources() {
    return _invoke(
      capability: 'plugins.list.v1',
      countField: 'pluginCount',
      action: () async {
        final connection = await _loadRuntimeConnection();
        return List<PluginSourceDescriptor>.unmodifiable(
          connection.plugins
              .where(_isUsableSource)
              .map(
                (plugin) => PluginSourceDescriptor(
                  id: plugin.id,
                  displayName: plugin.displayName,
                  description: plugin.description,
                  iconUrl: plugin.iconUrl,
                  pluginVersion: plugin.activeVersion!,
                  contentKinds: plugin.contentKinds.map(_contentKind),
                ),
              ),
        );
      },
      resultCount: (sources) => sources.length,
    );
  }

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) {
    return _invoke(
      capability: 'source.search.v1',
      action: () => _runtime.invoke(SourceSearchInvocation(pluginId: pluginId, query: query, cursor: cursor, pageSize: pageSize)),
      resultCount: (result) => result.items.length,
    );
  }

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) {
    return _invoke(
      capability: 'source.searchSuggestions.v1',
      action: () => _runtime.invoke(SourceSearchSuggestionsInvocation(pluginId: pluginId, cursor: cursor, pageSize: pageSize)),
      resultCount: (result) => result.items.length,
    );
  }

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) {
    return _invoke(
      capability: 'source.discover.v1',
      action: () => _runtime.invoke(
        SourceDiscoverInvocation(pluginId: pluginId, target: target, cursor: cursor, collectionId: collectionId, pageSize: pageSize),
      ),
      resultCount: (result) => switch (result) {
        PluginDiscoveryDocumentResult(:final document) => _discoveryDocumentItemCount(document),
        PluginDiscoveryAppendResult(:final items) => items.length,
      },
    );
  }

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) {
    return _invoke(
      capability: 'source.getDetail.v1',
      action: () => _runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: id)),
      resultCount: (_) => 1,
    );
  }

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) {
    return _invoke(
      capability: 'source.getChapters.v1',
      action: () => _runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: id)),
      resultCount: (result) => result.items.length,
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) {
    return _invoke(
      capability: 'source.getContent.v1',
      action: () => _runtime.invoke(SourceContentInvocation(pluginId: pluginId, id: id, chapterId: chapterId)),
      resultCount: (result) => switch (result.contentKind) {
        PluginContentKind.novel => 1,
        PluginContentKind.manga => result.pages.length,
        PluginContentKind.audio || PluginContentKind.video => result.media == null ? 0 : 1,
      },
    );
  }

  Future<T> _invoke<T>({
    required String capability,
    required Future<T> Function() action,
    required int Function(T result) resultCount,
    String countField = 'resultCount',
  }) async {
    final span = _diagnostics.startSpan(
      AppDiagnosticEvents.runtimeFacadeCall,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'capability': DiagnosticValue.string(capability),
        'attempt': DiagnosticValue.int64(1),
        'resultState': DiagnosticValue.string('loading'),
      }),
    );
    final stopwatch = Stopwatch()..start();
    try {
      final result = await action();
      final count = resultCount(result);
      span.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(capability),
          'attempt': DiagnosticValue.int64(1),
          countField: DiagnosticValue.int64(count),
          'resultState': DiagnosticValue.string(count == 0 ? 'empty' : 'content'),
        }),
      );
      _reportSlow(capability, stopwatch, DiagnosticOutcome.success, span);
      return result;
    } on Object catch (error, stackTrace) {
      final location =
          '$capability / ${error is PluginRuntimeException && _isInvalidRuntimeResponse(error) ? 'runtime.response.validation' : 'runtime.invocation'}';
      final normalized = error is PluginRuntimeException
          ? normalizePluginRuntimeError(error, location: location)
          : AppError.fromUnknown(error);
      final appError = normalized.withContext(location: location);
      span.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'capability': DiagnosticValue.string(capability),
          'attempt': DiagnosticValue.int64(1),
          'resultState': DiagnosticValue.string('failure'),
          'errorCode': DiagnosticValue.string(appError.code.wireValue),
          'errorLocation': DiagnosticValue.string(location),
          if (appError.detail != null) 'errorText': DiagnosticValue.string(appError.detail!),
          'stackTrace': DiagnosticValue.string(stackTrace.toString()),
        }),
      );
      _reportSlow(capability, stopwatch, DiagnosticOutcome.error, span);
      Error.throwWithStackTrace(appError, stackTrace);
    }
  }

  void _reportSlow(String capability, Stopwatch stopwatch, DiagnosticOutcome outcome, DiagnosticSpanHandle span) {
    stopwatch.stop();
    reportSlowDiagnostic(
      _diagnostics,
      subjectComponent: 'feature.discovery',
      operation: capability,
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.runtimeFacade,
      outcome: outcome,
      traceContext: span.traceContext,
    );
  }
}

bool _isInvalidRuntimeResponse(PluginRuntimeException error) => error.code == 'invalid_response' || error.code == 'plugin_invalid_response';

int _discoveryDocumentItemCount(PluginDiscoveryDocument document) =>
    document.components.fold<int>(0, (count, component) => count + _componentItemCount(component));

int _componentItemCount(PluginDiscoveryComponent component) => switch (component) {
  PluginDiscoveryContentCollectionComponent(:final items) => items.length,
  PluginDiscoveryCategoryCollectionComponent(:final categories) => categories.length,
  PluginDiscoverySectionComponent(:final children) ||
  PluginDiscoveryGroupComponent(:final children) => children.fold<int>(0, (count, child) => count + _componentItemCount(child)),
  _ => 0,
};

final sourceContentGatewayProvider = Provider<SourceContentGateway>((Ref ref) {
  return MgReadSourceContentGateway(
    ref.watch(pluginRuntimeFacadeProvider),
    ref.watch(diagnosticsManagerProvider),
    () => ref.read(pluginRuntimeConnectionProvider.future),
  );
});

/// Process-scoped cache of all enabled, source-capable plugins.
///
/// Discovery and search share this projection so entering either page never
/// causes a second Runtime readiness/list request. The provider is deliberately
/// not auto-disposed: the source list is part of the app's warmed Runtime
/// session and is refreshed when the Runtime projection is invalidated.
final availablePluginSourcesProvider = FutureProvider<List<PluginSourceDescriptor>>((Ref ref) {
  final gateway = ref.watch(sourceContentGatewayProvider);
  return gateway.listSources();
});

bool _isUsableSource(PluginRuntimePlugin plugin) {
  return plugin.enabled &&
      plugin.activeVersion != null &&
      plugin.contentKinds.any((kind) => kind == 'novel' || kind == 'manga' || kind == 'audio' || kind == 'video');
}

PluginContentKind _contentKind(String value) => switch (value) {
  'novel' => PluginContentKind.novel,
  'manga' => PluginContentKind.manga,
  'audio' => PluginContentKind.audio,
  'video' => PluginContentKind.video,
  _ => throw StateError('Runtime returned a non-content plugin kind.'),
};
