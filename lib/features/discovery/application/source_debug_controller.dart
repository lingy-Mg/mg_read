/// 顺序巡检可用源的发现、首个资源详情、目录及首章解析。
///
/// 只通过现有内容网关读取；不写主页面选择、书架或播放进度。
/// 每步有超时与 Runtime 取消，停止/销毁后忽略迟到结果；一源失败不阻断下一源。
/// 成功只代表首个样本的接口检查通过，不代表封面下载或媒体实际播放成功。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
import 'source_content_gateway.dart';

enum SourceDebugOutcome { passed, failed, skipped, cancelled }

@immutable
class SourceDebugResult {
  const SourceDebugResult({required this.source, required this.outcome, required this.stage, required this.message, this.title});
  final PluginSourceDescriptor source;
  final SourceDebugOutcome outcome;
  final String stage;
  final String message;
  final String? title;

  String get label => switch (outcome) {
    SourceDebugOutcome.passed => '通过',
    SourceDebugOutcome.failed => '失败',
    SourceDebugOutcome.skipped => '未验证',
    SourceDebugOutcome.cancelled => '已停止',
  };
  String get report => '${source.displayName} (${source.id}) · $label\n$stage${title == null ? '' : ' · $title'}\n$message';
}

class SourceDebugController extends ChangeNotifier {
  SourceDebugController({
    required this.gateway,
    required Iterable<PluginSourceDescriptor> sources,
    this.stepTimeout = const Duration(seconds: 45),
    this.previewDuration = const Duration(milliseconds: 1200),
  }) : sources = List.unmodifiable(sources);

  final SourceContentGateway gateway;
  final List<PluginSourceDescriptor> sources;
  final Duration stepTimeout;
  final Duration previewDuration;
  final List<SourceDebugResult> _results = [];
  final Completer<void> _stop = Completer<void>();
  PluginInvocationCancellation? _cancellation;
  bool _disposed = false;
  bool _started = false;
  bool running = false;
  int index = -1;
  String stage = '准备检查';
  PluginDiscoveryDocumentResult? discovery;
  PluginContentDetail? detail;
  PluginChaptersResult? catalog;
  PluginContentSummary? content;

  List<SourceDebugResult> get results => List.unmodifiable(_results);
  PluginSourceDescriptor? get currentSource => index < 0 ? null : sources[index];
  bool get stopped => _stop.isCompleted;
  String get report =>
      '数据源 Debug · ${_results.length}/${sources.length}\n'
      '范围：发现 → 首个资源详情 → 目录 → 首章/媒体解析；不含图片下载、音视频播放和全部资源。\n\n'
      '${_results.map((result) => result.report).join('\n\n')}';

  Future<void> run() async {
    if (_started || stopped || _disposed) return;
    _started = true;
    running = true;
    for (var next = 0; next < sources.length && !stopped; next++) {
      index = next;
      discovery = null;
      detail = null;
      catalog = null;
      content = null;
      _cancellation = PluginInvocationCancellation();
      try {
        await _inspect(sources[next]);
      } on _DebugStopped {
        _record(SourceDebugOutcome.cancelled, '检查已停止，剩余数据源未检查。');
      } on _DebugSkipped catch (error) {
        _record(SourceDebugOutcome.skipped, error.message);
      } on TimeoutException {
        _record(SourceDebugOutcome.failed, '此步骤超过 ${stepTimeout.inSeconds} 秒，已取消并继续下一源。');
      } on Object catch (error) {
        final failure = AppError.fromUnknown(error);
        _record(
          stopped ? SourceDebugOutcome.cancelled : SourceDebugOutcome.failed,
          stopped ? '检查已停止，剩余数据源未检查。' : '${failure.code.wireValue}：${failure.detail ?? '数据源请求失败'}',
        );
      } finally {
        _cancellation?.cancel();
        _cancellation = null;
      }
      _publish();
    }
    running = false;
    stage = stopped ? '检查已停止' : '检查完成';
    _publish();
  }

  Future<void> _inspect(PluginSourceDescriptor source) async {
    content = await _findFirst(source.id);
    if (content == null) throw const _DebugSkipped('未找到可打开的资源；本轮最多检查 8 个发现/分类页面，未验证内容可用性。');
    detail = await _step('打开首个资源：${content!.title}', () => gateway.getDetail(pluginId: source.id, id: content!.id));
    catalog = await _step('加载目录', () => gateway.getChapters(pluginId: source.id, id: content!.id));
    _publish();
    // Give the native detail preview a visible frame before testing its first entry.
    await _pause();
    var chapter = catalog!.items.firstOrNull;
    if (chapter == null) {
      for (final group in catalog!.groups) {
        chapter = group.episodes.firstOrNull;
        if (chapter == null && group.deferred && gateway is SourceChapterGroupGateway) {
          final loaded = await _step(
            '加载首个目录分组',
            () => (gateway as SourceChapterGroupGateway).getChapterGroup(pluginId: source.id, id: content!.id, groupId: group.id),
          );
          chapter = loaded.items.firstOrNull ?? loaded.groups.expand((value) => value.episodes).firstOrNull;
        }
        if (chapter != null) break;
      }
    }
    if (chapter == null) throw const _DebugSkipped('详情已打开，但目录没有可检查的章节或资源。');
    if (chapter.isLocked == true) throw const _DebugSkipped('首个章节/资源受限，需要登录或购买，未自动访问。');
    final firstChapter = chapter;
    final value = await _step(
      '解析首章/资源：${chapter.title}',
      () => gateway.getContent(pluginId: source.id, id: content!.id, chapterId: firstChapter.id),
    );
    if (value.contentKind != detail!.summary.contentKind) throw StateError('首章类型与详情类型不一致。');
    final message = switch (value.contentKind) {
      PluginContentKind.novel => (value.text?.trim().isNotEmpty ?? false) ? '详情、目录及首章正文正常。' : throw StateError('首章正文为空。'),
      PluginContentKind.manga => value.pages.isNotEmpty ? '详情、目录及首章图片地址正常；未验证图片下载。' : throw StateError('首章没有漫画页。'),
      PluginContentKind.audio ||
      PluginContentKind.video => value.media != null ? '详情、目录及首个媒体资源解析正常；未验证实际播放。' : throw StateError('未返回媒体资源。'),
    };
    await _pause();
    _record(SourceDebugOutcome.passed, message);
  }

  Future<PluginContentSummary?> _findFirst(String pluginId) async {
    final pending = <String?>[null];
    final visited = <String?>{};
    // Bounded breadth-first traversal handles category/tab-only landing pages.
    while (pending.isNotEmpty && visited.length < 8) {
      final target = pending.removeAt(0);
      if (!visited.add(target)) continue;
      final result = await _step(target == null ? '切换数据源并加载发现页' : '打开分类/栏目', () => gateway.discover(pluginId: pluginId, target: target));
      if (result is PluginDiscoveryAppendResult) {
        if (result.items.isNotEmpty) return result.items.first.content;
        continue;
      }
      discovery = result as PluginDiscoveryDocumentResult;
      _publish();
      await _pause();
      final components = _flatten(discovery!.document.components).toList();
      for (final component in components) {
        if (component is PluginDiscoveryContentCollectionComponent && component.items.isNotEmpty) return component.items.first.content;
      }
      for (final component in components) {
        final targets = switch (component) {
          PluginDiscoveryCategoryCollectionComponent(:final categories) => categories.map((value) => value.target),
          PluginDiscoveryTabsComponent(:final tabs) => tabs.map((value) => value.target),
          _ => const Iterable<String>.empty(),
        };
        pending.addAll(targets.where((value) => !visited.contains(value) && !pending.contains(value)));
      }
    }
    return null;
  }

  Future<T> _step<T>(String label, Future<T> Function() action) async {
    if (stopped) throw const _DebugStopped();
    stage = label;
    _publish();
    final cancellation = _cancellation!;
    final timeout = Completer<T>();
    final timer = Timer(stepTimeout, () {
      timeout.completeError(TimeoutException(label));
      cancellation.cancel();
    });
    try {
      final result = await Future.any<T>([
        Future.sync(() => runCancellableSourceRequest(gateway, cancellation, action)),
        timeout.future,
        _stop.future.then<T>((_) => throw const _DebugStopped()),
      ]);
      if (stopped) throw const _DebugStopped();
      return result;
    } finally {
      timer.cancel();
    }
  }

  Future<void> _pause() async {
    final elapsed = Completer<void>();
    final timer = Timer(previewDuration, elapsed.complete);
    try {
      await Future.any([elapsed.future, _stop.future]);
      if (stopped) throw const _DebugStopped();
    } finally {
      timer.cancel();
    }
  }

  void _record(SourceDebugOutcome outcome, String message) {
    _results.add(SourceDebugResult(source: currentSource!, outcome: outcome, stage: stage, message: message, title: content?.title));
  }

  void stop() {
    if (stopped) return;
    _stop.complete();
    _cancellation?.cancel();
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

Iterable<PluginDiscoveryComponent> _flatten(Iterable<PluginDiscoveryComponent> components) sync* {
  for (final component in components) {
    yield component;
    switch (component) {
      case PluginDiscoverySectionComponent(:final children) || PluginDiscoveryGroupComponent(:final children):
        yield* _flatten(children);
      default:
        break;
    }
  }
}

class _DebugStopped implements Exception {
  const _DebugStopped();
}

class _DebugSkipped implements Exception {
  const _DebugSkipped(this.message);
  final String message;
}
