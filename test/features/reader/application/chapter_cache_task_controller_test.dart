import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/reader/application/chapter_cache_task_controller.dart';
import 'package:mg_read/features/reader/presentation/chapter_cache_task_bar.dart';

void main() {
  test('runs only the selected concurrency and reports completed progress', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(chapterCacheTaskControllerProvider.notifier);
    final gates = <int, Completer<void>>{};
    var active = 0;
    var maxActive = 0;

    controller.start(
      bookTitle: '并发测试书',
      total: 4,
      concurrency: 2,
      delay: Duration.zero,
      cacheChapter: (int index) async {
        active += 1;
        maxActive = active > maxActive ? active : maxActive;
        final gate = gates[index] = Completer<void>();
        await gate.future;
        active -= 1;
        return ChapterCacheItemResult.downloaded;
      },
    );
    await _flush();
    expect(gates.keys, <int>{0, 1});
    expect(maxActive, 2);

    gates[0]!.complete();
    gates[1]!.complete();
    await _flush();
    expect(gates.keys, <int>{0, 1, 2, 3});
    gates[2]!.complete();
    gates[3]!.complete();
    await _flush();

    final state = container.read(chapterCacheTaskControllerProvider);
    expect(state?.status, ChapterCacheTaskStatus.completed);
    expect(state?.cached, 4);
    expect(state?.failed, 0);
    expect(state?.progress, 1);
  });

  test('closing the task stops scheduling later chapters', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(chapterCacheTaskControllerProvider.notifier);
    final first = Completer<void>();
    final started = <int>[];

    controller.start(
      bookTitle: '取消测试书',
      total: 3,
      concurrency: 1,
      delay: Duration.zero,
      cacheChapter: (int index) async {
        started.add(index);
        if (index == 0) await first.future;
        return ChapterCacheItemResult.downloaded;
      },
    );
    await _flush();
    controller.cancelAndDismiss();
    first.complete();
    await _flush();

    expect(started, <int>[0]);
    expect(container.read(chapterCacheTaskControllerProvider), isNull);
  });

  test('applies the selected delay before one worker starts another chapter', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(chapterCacheTaskControllerProvider.notifier);
    final started = <int>[];

    controller.start(
      bookTitle: '延迟测试书',
      total: 2,
      concurrency: 1,
      delay: const Duration(milliseconds: 40),
      cacheChapter: (int index) async {
        started.add(index);
        return ChapterCacheItemResult.downloaded;
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(started, <int>[0]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await _flush();

    expect(started, <int>[0, 1]);
    expect(container.read(chapterCacheTaskControllerProvider)?.status, ChapterCacheTaskStatus.completed);
  });

  test('already cached chapters skip the selected delay', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(chapterCacheTaskControllerProvider.notifier);
    final started = <int>[];

    controller.start(
      bookTitle: '跳过缓存测试书',
      total: 2,
      concurrency: 1,
      delay: const Duration(seconds: 1),
      cacheChapter: (int index) async {
        started.add(index);
        return ChapterCacheItemResult.alreadyCached;
      },
    );
    await _flush();

    expect(started, <int>[0, 1]);
    expect(container.read(chapterCacheTaskControllerProvider)?.status, ChapterCacheTaskStatus.completed);
  });

  testWidgets('global bar renders progress and its close action cancels the task', (WidgetTester tester) async {
    late ChapterCacheTaskController controller;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) => Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              controller = ref.read(chapterCacheTaskControllerProvider.notifier);
              return Stack(fit: StackFit.expand, children: <Widget>[child ?? const SizedBox.shrink(), const ChapterCacheTaskBar()]);
            },
          ),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                key: const ValueKey<String>('open-second-route'),
                onPressed: () =>
                    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('第二个页面')))),
                child: const Text('打开页面'),
              ),
            ),
          ),
        ),
      ),
    );
    final gate = Completer<void>();
    controller.start(
      bookTitle: '全局任务测试书',
      total: 2,
      concurrency: 1,
      delay: Duration.zero,
      cacheChapter: (_) async {
        await gate.future;
        return ChapterCacheItemResult.downloaded;
      },
    );
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('global-chapter-cache-task-bar')), findsOneWidget);
    expect(find.text('全局任务测试书'), findsOneWidget);
    expect(find.textContaining('缓存进度 0/2'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('open-second-route')));
    await tester.pumpAndSettle();
    expect(find.text('第二个页面'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('global-chapter-cache-task-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('global-chapter-cache-close')));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('global-chapter-cache-task-bar')), findsNothing);
    gate.complete();
  });
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
