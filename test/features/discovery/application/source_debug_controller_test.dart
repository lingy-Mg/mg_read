/// Debug runner regression coverage: ordering, failed samples, traversal and cancellation.
library;

import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_debug_controller.dart';
import '../fixtures/source_debug_gateway.dart';

void main() {
  SourceDebugController runner(DebugTestGateway gateway, {Duration timeout = const Duration(seconds: 2)}) {
    final controller = SourceDebugController(
      gateway: gateway,
      sources: gateway.sources,
      previewDuration: Duration.zero,
      stepTimeout: timeout,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('opens the first nested resource serially and continues after a failed source', () async {
    final gateway = DebugTestGateway()
      ..detailOverride = (id) async {
        if (id == 'b') throw AppError.fromCode(AppErrorCode.sourceAccessBlocked, detail: '需要验证');
        return DebugTestGateway.detail(id);
      };
    final controller = runner(gateway);
    await controller.run();
    expect(gateway.calls, [
      'a:discover:home',
      'a:detail:book-a',
      'a:catalog:book-a',
      'a:content:chapter-1',
      'b:discover:home',
      'b:detail:book-b',
      'c:discover:home',
      'c:detail:book-c',
      'c:catalog:book-c',
      'c:content:chapter-1',
    ]);
    expect(controller.results.map((r) => r.outcome), [SourceDebugOutcome.passed, SourceDebugOutcome.failed, SourceDebugOutcome.passed]);
    expect(controller.results[1].message, contains('source_access_blocked'));
    expect(controller.report, contains('不含图片下载'));
    await controller.run();
    expect(controller.results.length, 3);
  });

  test('category-only landing pages reach the first resource and cycles terminate', () async {
    final gateway = DebugTestGateway()
      ..discoverOverride = (id, target) async {
        if (id != 'b' && target == 'category') return DebugTestGateway.document(id);
        return DebugTestGateway.document(
          id,
          components: [
            PluginDiscoveryCategoryCollectionComponent(
              id: 'categories',
              layout: PluginDiscoveryCategoryLayout.list,
              categories: const [PluginDiscoveryCategory(id: 'one', title: '分类', target: 'category', count: null, url: null)],
            ),
          ],
        );
      };
    final controller = runner(gateway);
    await controller.run();
    expect(controller.results.map((r) => r.outcome), [SourceDebugOutcome.passed, SourceDebugOutcome.skipped, SourceDebugOutcome.passed]);
    expect(gateway.calls.where((value) => value.startsWith('b:')), ['b:discover:home', 'b:discover:category']);
  });

  test('deferred groups are loaded and locked first entries are not requested', () async {
    final gateway = DebugTestGateway()
      ..catalogOverride = (id) => PluginChaptersResult(
        pluginId: id,
        sourceName: id,
        items: id == 'b' ? [DebugTestGateway.chapter(locked: true)] : [],
        groups: id == 'a' ? [PluginMediaGroup(id: 'group', title: '线路', order: 0, episodes: [], deferred: true)] : [],
      );
    final controller = runner(gateway);
    await controller.run();
    expect(gateway.calls, contains('a:group:group'));
    expect(gateway.calls, isNot(contains('b:content:chapter-1')));
    expect(controller.results.map((r) => r.outcome), [SourceDebugOutcome.passed, SourceDebugOutcome.skipped, SourceDebugOutcome.skipped]);
  });

  test('empty chapter text fails rather than reporting a false pass', () async {
    final gateway = DebugTestGateway()..contentOverride = (id, chapter) => DebugTestGateway.chapterContent(id, chapter, text: '  ');
    final controller = runner(gateway);
    await controller.run();
    expect(controller.results.every((r) => r.outcome == SourceDebugOutcome.failed), isTrue);
    expect(controller.results.first.message, contains('正文为空'));
  });

  test('manga and media report parsing coverage without claiming download or playback', () async {
    final kinds = {'a': PluginContentKind.manga, 'b': PluginContentKind.audio, 'c': PluginContentKind.video};
    final gateway = DebugTestGateway()
      ..detailOverride = ((id) async => DebugTestGateway.detail(id, kind: kinds[id]!))
      ..contentOverride = (id, chapter) => PluginChapterContent(
        pluginId: id,
        sourceName: id,
        contentKind: kinds[id]!,
        chapterId: chapter,
        title: '第一项',
        updatedAt: null,
        text: null,
        pages: id == 'a'
            ? [
                PluginMangaPage(
                  id: 'page',
                  index: 0,
                  url: Uri.parse('https://example.test/page.jpg'),
                  mimeType: 'image/jpeg',
                  width: null,
                  height: null,
                  resourcePolicy: PluginMangaPageResourcePolicy.durable,
                  expiresAt: null,
                ),
              ]
            : [],
        media: id == 'a'
            ? null
            : PluginMediaResource(
                url: Uri.parse('https://example.test/media'),
                resourceType: id == 'b' ? PluginMediaResourceType.audio : PluginMediaResourceType.video,
                resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
                expiresAt: null,
                mimeType: null,
                headers: {},
              ),
      );
    final controller = runner(gateway);
    await controller.run();
    expect(controller.results.every((r) => r.outcome == SourceDebugOutcome.passed), isTrue);
    expect(controller.results.first.message, contains('未验证图片下载'));
    expect(controller.results.last.message, contains('未验证实际播放'));
  });

  test('mismatched content kind is recorded as a failed sample', () async {
    final gateway = DebugTestGateway()..detailOverride = (id) async => DebugTestGateway.detail(id, kind: PluginContentKind.video);
    final controller = runner(gateway);
    await controller.run();
    expect(controller.results.every((r) => r.outcome == SourceDebugOutcome.failed), isTrue);
    expect(controller.results.first.message, contains('类型不一致'));
  });

  test('a timed out source is cancelled and late completion cannot overwrite the next one', () async {
    final pending = Completer<PluginDiscoverResult>();
    final gateway = DebugTestGateway()..discoverOverride = (id, _) async => id == 'a' ? pending.future : DebugTestGateway.document(id);
    final controller = runner(gateway, timeout: const Duration(milliseconds: 30));
    await controller.run();
    expect(controller.results.map((r) => r.outcome), [SourceDebugOutcome.failed, SourceDebugOutcome.passed, SourceDebugOutcome.passed]);
    expect(gateway.cancellations.first.isCancelled, isTrue);
    pending.complete(DebugTestGateway.document('a'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.discovery?.pluginId, 'c');
    expect(controller.results.length, 3);
  });

  test('stop completes promptly even when the gateway never completes', () async {
    final pending = Completer<PluginDiscoverResult>();
    final gateway = DebugTestGateway()..discoverOverride = (_, _) => pending.future;
    final controller = runner(gateway);
    final run = controller.run();
    controller.stop();
    await run;
    expect(controller.running, isFalse);
    expect(gateway.cancellations.first.isCancelled, isTrue);
    expect(gateway.calls, ['a:discover:home']);
    expect(controller.results.single.outcome, SourceDebugOutcome.cancelled);
    pending.completeError(StateError('late source failure'));
    await Future<void>.delayed(Duration.zero);
    expect(controller.results.length, 1);
  });

  test('stop during detail preview records only one result and prevents content access', () async {
    final gateway = DebugTestGateway();
    final controller = runner(gateway);
    controller.addListener(() {
      if (controller.catalog != null) controller.stop();
    });
    await controller.run();
    expect(controller.results.single.outcome, SourceDebugOutcome.cancelled);
    expect(gateway.calls, isNot(contains('a:content:chapter-1')));
  });
}
