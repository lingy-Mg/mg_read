/// 全局章节缓存浮动任务栏。
///
/// 职责：
/// - 在应用根导航之上显示当前书籍的缓存进度、失败数和完成状态。
/// - 提供可访问的关闭操作，并将其解释为停止任务和隐藏浮条。
///
/// 注意：
/// - 不创建 OverlayEntry，不依赖当前路由或阅读器 BuildContext。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/features/reader/application/chapter_cache_task_controller.dart';

/// Root-shell sibling that remains visible across every application route.
class ChapterCacheTaskBar extends ConsumerWidget {
  const ChapterCacheTaskBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(chapterCacheTaskControllerProvider);
    if (task == null) return const SizedBox.shrink();
    final bool completed = task.status == ChapterCacheTaskStatus.completed;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String progressLabel = task.total == 0 ? '没有待缓存章节' : '缓存进度 ${task.processed}/${task.total}';
    final String detailLabel = task.failed == 0 ? (completed ? '缓存完成' : '正在缓存') : '${completed ? '缓存结束' : '正在缓存'} · ${task.failed} 章失败';

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Material(
            key: const ValueKey<String>('global-chapter-cache-task-bar'),
            elevation: 10,
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: <Widget>[
                  Icon(completed ? Icons.download_done_rounded : Icons.downloading_rounded, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(task.bookTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          '$progressLabel · $detailLabel',
                          key: const ValueKey<String>('global-chapter-cache-progress-label'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          key: const ValueKey<String>('global-chapter-cache-progress'),
                          value: task.progress,
                          minHeight: 5,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ],
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: completed ? '关闭缓存任务栏' : '停止并关闭缓存任务',
                    child: IconButton(
                      key: const ValueKey<String>('global-chapter-cache-close'),
                      onPressed: () => ref.read(chapterCacheTaskControllerProvider.notifier).cancelAndDismiss(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
