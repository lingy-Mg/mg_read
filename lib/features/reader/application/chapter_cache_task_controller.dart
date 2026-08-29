/// 全局小说章节缓存任务状态。
///
/// 职责：
/// - 只维护一个跨路由存活的章节缓存任务及其有界并发、延迟和进度。
/// - 新任务替换旧任务；关闭浮条时停止调度后续章节并隐藏任务。
///
/// 注意：
/// - 具体网络和持久化由调用方传入的单章操作负责。
/// - 取消不能强行中断已经交给宿主网关的单个 Future，但其结果不再更新已关闭任务。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Process-wide controller watched by the root application shell.
final chapterCacheTaskControllerProvider = NotifierProvider<ChapterCacheTaskController, ChapterCacheTaskState?>(
  ChapterCacheTaskController.new,
);

/// Visible lifecycle of the single global cache task.
enum ChapterCacheTaskStatus { running, completed }

/// Result of one selected chapter before the scheduler applies its delay.
enum ChapterCacheItemResult {
  /// The task fetched or persisted this chapter and should respect the delay.
  downloaded,

  /// Durable content already existed, so the scheduler should continue now.
  alreadyCached,
}

/// Immutable projection rendered by the global floating task bar.
final class ChapterCacheTaskState {
  const ChapterCacheTaskState({
    required this.bookTitle,
    required this.total,
    required this.cached,
    required this.failed,
    required this.status,
  });

  final String bookTitle;
  final int total;
  final int cached;
  final int failed;
  final ChapterCacheTaskStatus status;

  int get processed => cached + failed;

  double get progress => total <= 0 ? 1 : (processed / total).clamp(0, 1);

  ChapterCacheTaskState copyWith({int? cached, int? failed, ChapterCacheTaskStatus? status}) => ChapterCacheTaskState(
    bookTitle: bookTitle,
    total: total,
    cached: cached ?? this.cached,
    failed: failed ?? this.failed,
    status: status ?? this.status,
  );
}

/// Schedules cache work without owning source or persistence implementations.
final class ChapterCacheTaskController extends Notifier<ChapterCacheTaskState?> {
  int _generation = 0;

  @override
  ChapterCacheTaskState? build() {
    ref.onDispose(() => _generation++);
    return null;
  }

  /// Starts one task and returns as soon as its workers have been scheduled.
  void start({
    required String bookTitle,
    required int total,
    required int concurrency,
    required Duration delay,
    required Future<ChapterCacheItemResult> Function(int chapterIndex) cacheChapter,
  }) {
    if (total < 0) throw ArgumentError.value(total, 'total');
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency');
    if (delay.isNegative) throw ArgumentError.value(delay, 'delay');
    final int generation = ++_generation;
    state = ChapterCacheTaskState(
      bookTitle: bookTitle,
      total: total,
      cached: 0,
      failed: 0,
      status: total == 0 ? ChapterCacheTaskStatus.completed : ChapterCacheTaskStatus.running,
    );
    if (total == 0) return;
    unawaited(
      _run(generation: generation, total: total, concurrency: concurrency.clamp(1, total), delay: delay, cacheChapter: cacheChapter),
    );
  }

  /// Stops future scheduling and removes the global floating task bar.
  void cancelAndDismiss() {
    _generation++;
    state = null;
  }

  Future<void> _run({
    required int generation,
    required int total,
    required int concurrency,
    required Duration delay,
    required Future<ChapterCacheItemResult> Function(int chapterIndex) cacheChapter,
  }) async {
    var nextIndex = 0;

    Future<void> worker() async {
      var delayBeforeNext = false;
      while (_isCurrent(generation)) {
        if (nextIndex >= total) return;
        if (delayBeforeNext && delay > Duration.zero) {
          await Future<void>.delayed(delay);
          if (!_isCurrent(generation)) return;
        }
        delayBeforeNext = false;
        if (nextIndex >= total) return;
        final int index = nextIndex++;
        try {
          final result = await cacheChapter(index);
          if (!_isCurrent(generation)) return;
          delayBeforeNext = result == ChapterCacheItemResult.downloaded;
          final current = state!;
          state = current.copyWith(cached: current.cached + 1);
        } on Object {
          if (!_isCurrent(generation)) return;
          // A failure can only occur after attempting host work, so throttle
          // the next request just like a successful download.
          delayBeforeNext = true;
          final current = state!;
          state = current.copyWith(failed: current.failed + 1);
        }
      }
    }

    await Future.wait<void>(<Future<void>>[for (var workerIndex = 0; workerIndex < concurrency; workerIndex += 1) worker()]);
    if (!_isCurrent(generation)) return;
    state = state!.copyWith(status: ChapterCacheTaskStatus.completed);
  }

  bool _isCurrent(int generation) => generation == _generation && state?.status == ChapterCacheTaskStatus.running;
}
