/// Windows 正式 App 内置的数据源全链路自检引擎。
///
/// 职责：经生产 SourceContentGateway 顺序验证发现、搜索、详情、完整目录、内容抽样和 Runtime 资源代理。
/// 注意：只产生计数与稳定错误码；内容值仅在当前调用栈内用于下一阶段，不进入报告或诊断。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

import 'source_verification_models.dart';

typedef SourceVerificationProgressCallback = void Function(SourceVerificationProgress progress);
typedef SourceVerificationHttpClientFactory = HttpClient Function();

final sourceVerificationEngineProvider = Provider<SourceVerificationEngine>((Ref ref) {
  return SourceVerificationEngine(ref.watch(sourceContentGatewayProvider));
});

final class SourceVerificationEngine {
  SourceVerificationEngine(this._gateway, {this._httpClientFactory = _defaultHttpClient, this.stageTimeout = const Duration(minutes: 2)});

  final SourceContentGateway _gateway;
  final SourceVerificationHttpClientFactory _httpClientFactory;
  final Duration stageTimeout;

  Future<SourceVerificationReport> run({
    String? pluginId,
    SourceVerificationProgressCallback? onProgress,
    SourceVerificationCancellationToken? cancellationToken,
  }) async {
    final startedAt = DateTime.now();
    final stopwatch = Stopwatch()..start();
    final sources = await _gateway.listSources().timeout(
      stageTimeout,
      onTimeout: () {
        throw const SourceVerificationRunException('runtime_timeout');
      },
    );
    final selected = pluginId == null
        ? (List<PluginSourceDescriptor>.of(sources)..sort((left, right) => left.id.compareTo(right.id)))
        : sources.where((source) => source.id == pluginId).toList(growable: false);
    if (selected.isEmpty) {
      throw SourceVerificationRunException(pluginId == null ? 'source_list_empty' : 'source_not_found');
    }
    final results = <SourceVerificationSourceResult>[];
    for (final source in selected) {
      if (cancellationToken?.isCancelled ?? false) break;
      final result = await _runSource(source, onProgress: onProgress, cancellationToken: cancellationToken);
      results.add(result);
      if (result.status == SourceVerificationResultStatus.cancelled) break;
    }
    stopwatch.stop();
    return SourceVerificationReport(
      startedAt: startedAt,
      duration: stopwatch.elapsed,
      mode: pluginId == null ? 'all' : 'single',
      sources: results,
    );
  }

  Future<SourceVerificationSourceResult> _runSource(
    PluginSourceDescriptor source, {
    SourceVerificationProgressCallback? onProgress,
    SourceVerificationCancellationToken? cancellationToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    final stages = <SourceVerificationStageResult>[
      SourceVerificationStageResult(
        stage: 'runtime',
        status: SourceVerificationStageStatus.passed,
        duration: Duration.zero,
        summary: <String, Object?>{'contentKinds': source.contentKinds.map((kind) => kind.code).toList(growable: false)},
      ),
    ];
    final context = _SourceRunContext(
      source: source,
      stages: stages,
      stageTimeout: stageTimeout,
      onProgress: onProgress,
      cancellationToken: cancellationToken,
    );
    var status = SourceVerificationResultStatus.passed;
    try {
      final discovery = await context.stage<_DiscoverySelection>(
        'discover',
        () => _loadDiscovery(source.id),
        summary: (value) => <String, Object?>{'items': value.items.length, 'followedTargets': value.followedTargets},
      );
      final discoveryCandidate = discovery.items.first.content;
      final search = await context.stage<PluginSearchResult>(
        'search',
        () => _gateway.search(pluginId: source.id, query: discoveryCandidate.title, pageSize: 8),
        validate: (value) {
          if (value.items.isEmpty) throw const _VerificationFailure('search_empty');
        },
        summary: (value) => <String, Object?>{'items': value.items.length},
      );
      final selected = search.items.first;
      final detail = await context.stage<PluginContentDetail>(
        'detail',
        () => _gateway.getDetail(pluginId: source.id, id: selected.id),
        validate: (value) {
          if (value.summary.id != selected.id || value.summary.title.trim().isEmpty) {
            throw const _VerificationFailure('detail_invalid');
          }
        },
        summary: (value) => <String, Object?>{'contentKind': value.summary.contentKind.code},
      );
      final chapters = await context.stage<PluginChaptersResult>(
        'chapters',
        () => _gateway.getChapters(pluginId: source.id, id: selected.id),
        validate: (value) => _validateChapters(detail, value),
        summary: (value) => <String, Object?>{'items': value.items.length, 'groups': value.groups.length},
      );
      final samples = _sampleChapters(chapters.items);
      if (samples.isEmpty) throw const _VerificationFailure('content_interaction_required', interactionRequired: true);
      final contents = <PluginChapterContent>[];
      for (var index = 0; index < samples.length; index += 1) {
        final chapter = samples[index];
        final sampleName = switch ((samples.length, index)) {
          (_, 0) => 'first',
          (2, _) => 'last',
          (_, 1) => 'middle',
          _ => 'last',
        };
        final content = await context.stage<PluginChapterContent>(
          'content.$sampleName',
          () => _gateway.getContent(pluginId: source.id, id: selected.id, chapterId: chapter.id),
          validate: (value) => _validateContent(detail, chapter, value),
          summary: (value) => <String, Object?>{'units': _contentUnits(value), 'contentKind': detail.summary.contentKind.code},
        );
        contents.add(content);
      }
      final covers = <Uri>[
        ...discovery.items.take(6).map((item) => item.content.coverUrl).nonNulls,
        ...search.items.take(6).map((item) => item.coverUrl).nonNulls,
        ...<Uri?>[detail.summary.coverUrl].nonNulls,
      ];
      if (covers.isEmpty) {
        context.skip('resource.cover', 'resource_not_declared');
      } else {
        await context.stage<_ResourceProbeResult>(
          'resource.cover',
          () => _probeAny(covers, expectedImage: true),
          summary: (value) => value.summary,
        );
      }
      final contentResources = _contentResourceCandidates(contents);
      if (contentResources.isEmpty) {
        context.skip('resource.content', 'resource_not_required');
      } else {
        await context.stage<_ResourceProbeResult>(
          'resource.content',
          () => _probeAny(contentResources, expectedImage: detail.summary.contentKind == PluginContentKind.manga),
          summary: (value) => value.summary,
        );
      }
    } on _StageAbort catch (failure) {
      status = failure.cancelled
          ? SourceVerificationResultStatus.cancelled
          : failure.interactionRequired
          ? SourceVerificationResultStatus.interactionRequired
          : SourceVerificationResultStatus.failed;
    } on _VerificationFailure catch (failure) {
      stages.add(
        SourceVerificationStageResult(
          stage: 'content',
          status: SourceVerificationStageStatus.failed,
          duration: Duration.zero,
          code: failure.code,
        ),
      );
      status = failure.interactionRequired ? SourceVerificationResultStatus.interactionRequired : SourceVerificationResultStatus.failed;
    }
    stopwatch.stop();
    return SourceVerificationSourceResult(
      pluginId: source.id,
      displayName: source.displayName,
      version: source.pluginVersion,
      status: status,
      duration: stopwatch.elapsed,
      stages: stages,
    );
  }

  Future<_DiscoverySelection> _loadDiscovery(String pluginId) async {
    final root = await _gateway.discover(pluginId: pluginId, pageSize: 20);
    var items = _collectDiscoveryItems(root);
    var followedTargets = 0;
    if (items.isEmpty && root is PluginDiscoveryDocumentResult) {
      for (final target in _collectDiscoveryTargets(root.document.components).take(6)) {
        final child = await _gateway.discover(pluginId: pluginId, target: target, pageSize: 20);
        followedTargets += 1;
        items = _collectDiscoveryItems(child);
        if (items.isNotEmpty) break;
      }
    }
    if (items.isEmpty) throw const _VerificationFailure('discovery_empty');
    return _DiscoverySelection(items: items, followedTargets: followedTargets);
  }

  Future<_ResourceProbeResult> _probeAny(List<Uri> candidates, {required bool expectedImage}) async {
    final unique = <Uri>[];
    for (final candidate in candidates) {
      if ((candidate.scheme == 'http' || candidate.scheme == 'https') && !unique.contains(candidate)) unique.add(candidate);
      if (unique.length == 8) break;
    }
    if (unique.isEmpty) throw const _VerificationFailure('resource_url_invalid');
    final statuses = <int>[];
    for (final candidate in unique) {
      final client = _httpClientFactory();
      try {
        final request = await client.getUrl(candidate).timeout(stageTimeout);
        request.followRedirects = true;
        request.maxRedirects = 5;
        final response = await request.close().timeout(stageTimeout);
        statuses.add(response.statusCode);
        final contentType = response.headers.contentType?.mimeType ?? '';
        var bytesRead = 0;
        final signature = <int>[];
        await response
            .take(1)
            .forEach((bytes) {
              bytesRead += bytes.length;
              signature.addAll(bytes.take(16));
            })
            .timeout(stageTimeout);
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            (!expectedImage || contentType.startsWith('image/') || _hasImageSignature(signature)) &&
            bytesRead > 0) {
          return _ResourceProbeResult(attempts: statuses.length, status: response.statusCode, bytesRead: bytesRead);
        }
      } on Object {
        statuses.add(0);
      } finally {
        client.close(force: true);
      }
    }
    throw _VerificationFailure('resource_unreachable', summary: <String, Object?>{'attempts': statuses.length, 'statuses': statuses});
  }
}

bool _hasImageSignature(List<int> bytes) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  return startsWith(const <int>[0xFF, 0xD8, 0xFF]) ||
      startsWith(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ||
      startsWith(const <int>[0x47, 0x49, 0x46, 0x38]) ||
      startsWith(const <int>[0x42, 0x4D]) ||
      (startsWith(const <int>[0x52, 0x49, 0x46, 0x46]) && startsWith(const <int>[0x57, 0x45, 0x42, 0x50], 8));
}

final class _SourceRunContext {
  const _SourceRunContext({
    required this.source,
    required this.stages,
    required this.stageTimeout,
    required this.onProgress,
    required this.cancellationToken,
  });

  final PluginSourceDescriptor source;
  final List<SourceVerificationStageResult> stages;
  final Duration stageTimeout;
  final SourceVerificationProgressCallback? onProgress;
  final SourceVerificationCancellationToken? cancellationToken;

  Future<T> stage<T>(
    String stage,
    Future<T> Function() action, {
    void Function(T value)? validate,
    Map<String, Object?> Function(T value)? summary,
  }) async {
    checkCancellation();
    onProgress?.call(SourceVerificationProgress(pluginId: source.id, displayName: source.displayName, stage: stage, running: true));
    final stopwatch = Stopwatch()..start();
    try {
      final value = await action().timeout(stageTimeout);
      checkCancellation();
      validate?.call(value);
      stopwatch.stop();
      stages.add(
        SourceVerificationStageResult(
          stage: stage,
          status: SourceVerificationStageStatus.passed,
          duration: stopwatch.elapsed,
          summary: summary?.call(value) ?? const <String, Object?>{},
        ),
      );
      onProgress?.call(SourceVerificationProgress(pluginId: source.id, displayName: source.displayName, stage: stage, running: false));
      return value;
    } on Object catch (error) {
      stopwatch.stop();
      final code = _stableErrorCode(error);
      final cancelled = error is _VerificationCancelled;
      final interactionRequired =
          error is _VerificationFailure && error.interactionRequired || error is AppError && error.code == AppErrorCode.interactionRequired;
      stages.add(
        SourceVerificationStageResult(
          stage: stage,
          status: cancelled ? SourceVerificationStageStatus.cancelled : SourceVerificationStageStatus.failed,
          duration: stopwatch.elapsed,
          code: code,
          summary: error is _VerificationFailure ? error.summary : const <String, Object?>{},
        ),
      );
      onProgress?.call(SourceVerificationProgress(pluginId: source.id, displayName: source.displayName, stage: stage, running: false));
      throw _StageAbort(cancelled: cancelled, interactionRequired: interactionRequired);
    }
  }

  void skip(String stage, String code) {
    stages.add(
      SourceVerificationStageResult(stage: stage, status: SourceVerificationStageStatus.skipped, duration: Duration.zero, code: code),
    );
  }

  void checkCancellation() {
    if (cancellationToken?.isCancelled ?? false) throw const _VerificationCancelled();
  }
}

void _validateChapters(PluginContentDetail detail, PluginChaptersResult chapters) {
  if (chapters.items.isEmpty) throw const _VerificationFailure('chapters_empty');
  final ids = chapters.items.map((chapter) => chapter.id).toList(growable: false);
  if (ids.any((id) => id.trim().isEmpty) || ids.toSet().length != ids.length) {
    throw const _VerificationFailure('chapters_invalid');
  }
  for (var index = 1; index < chapters.items.length; index += 1) {
    if (chapters.items[index].order < chapters.items[index - 1].order) {
      throw const _VerificationFailure('chapters_unordered');
    }
  }
  final expected = detail.summary.chapterCount;
  if (expected != null && expected > 0 && chapters.items.length < expected) {
    throw _VerificationFailure('chapters_truncated', summary: <String, Object?>{'expected': expected, 'actual': chapters.items.length});
  }
}

List<PluginChapterSummary> _sampleChapters(List<PluginChapterSummary> chapters) {
  final available = chapters.where((chapter) => chapter.isLocked != true).toList(growable: false);
  if (available.isEmpty) return const <PluginChapterSummary>[];
  final indexes = <int>{0, (available.length - 1) ~/ 2, available.length - 1}.toList()..sort();
  return List<PluginChapterSummary>.unmodifiable(indexes.map((index) => available[index]));
}

void _validateContent(PluginContentDetail detail, PluginChapterSummary chapter, PluginChapterContent content) {
  if (content.chapterId != chapter.id || content.contentKind != detail.summary.contentKind || _contentUnits(content) == 0) {
    throw const _VerificationFailure('content_invalid');
  }
}

int _contentUnits(PluginChapterContent content) => switch (content.contentKind) {
  PluginContentKind.novel => content.text?.trim().length ?? 0,
  PluginContentKind.manga => content.pages.length,
  PluginContentKind.audio || PluginContentKind.video => content.media == null ? 0 : 1,
};

List<Uri> _contentResourceCandidates(List<PluginChapterContent> contents) {
  final resources = <Uri>[];
  for (final content in contents) {
    if (content.pages.isNotEmpty) {
      resources.add(content.pages.first.url);
      if (content.pages.length > 1) resources.add(content.pages.last.url);
    }
    if (content.media != null) resources.add(content.media!.url);
  }
  return resources;
}

List<PluginDiscoveryContentItem> _collectDiscoveryItems(PluginDiscoverResult result) {
  if (result is PluginDiscoveryAppendResult) return result.items;
  final items = <PluginDiscoveryContentItem>[];
  void visit(PluginDiscoveryComponent component) {
    switch (component) {
      case PluginDiscoveryContentCollectionComponent(items: final values):
        items.addAll(values);
      case PluginDiscoverySectionComponent(:final children) || PluginDiscoveryGroupComponent(:final children):
        children.forEach(visit);
      default:
        break;
    }
  }

  if (result case PluginDiscoveryDocumentResult(:final document)) document.components.forEach(visit);
  return List<PluginDiscoveryContentItem>.unmodifiable(items);
}

List<String> _collectDiscoveryTargets(Iterable<PluginDiscoveryComponent> components) {
  final targets = <String>[];
  void add(String value) {
    if (value.isNotEmpty && !targets.contains(value)) targets.add(value);
  }

  void visit(PluginDiscoveryComponent component) {
    switch (component) {
      case PluginDiscoveryTabsComponent(:final tabs):
        tabs.map((tab) => tab.target).forEach(add);
      case PluginDiscoveryCategoryCollectionComponent(:final categories):
        categories.map((category) => category.target).forEach(add);
      case PluginDiscoverySectionComponent(:final children) || PluginDiscoveryGroupComponent(:final children):
        children.forEach(visit);
      default:
        break;
    }
  }

  components.forEach(visit);
  return List<String>.unmodifiable(targets);
}

String _stableErrorCode(Object error) => switch (error) {
  _VerificationFailure(:final code) => code,
  _VerificationCancelled() => 'cancelled',
  TimeoutException() => 'timeout',
  AppError(:final code) => code.wireValue,
  _ => 'internal',
};

HttpClient _defaultHttpClient() => HttpClient();

final class _DiscoverySelection {
  const _DiscoverySelection({required this.items, required this.followedTargets});
  final List<PluginDiscoveryContentItem> items;
  final int followedTargets;
}

final class _ResourceProbeResult {
  const _ResourceProbeResult({required this.attempts, required this.status, required this.bytesRead});
  final int attempts;
  final int status;
  final int bytesRead;
  Map<String, Object?> get summary => <String, Object?>{'attempts': attempts, 'status': status, 'bytesRead': bytesRead};
}

final class _VerificationFailure implements Exception {
  const _VerificationFailure(this.code, {this.interactionRequired = false, this.summary = const <String, Object?>{}});
  final String code;
  final bool interactionRequired;
  final Map<String, Object?> summary;
}

final class _VerificationCancelled implements Exception {
  const _VerificationCancelled();
}

final class _StageAbort implements Exception {
  const _StageAbort({required this.cancelled, required this.interactionRequired});
  final bool cancelled;
  final bool interactionRequired;
}
