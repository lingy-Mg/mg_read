import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_video_cache.dart';
import 'package:mg_read/features/media/presentation/source_video_downloads_page.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  testWidgets('queues the selected episode and cancels it from the download list', (tester) async {
    final support = (await tester.runAsync(() => Directory.systemTemp.createTemp('mgread-video-download-ui-')))!;
    final cache = SourceVideoCache(supportDirectory: () async => support);
    addTearDown(() async {
      cache.dispose();
      await support.delete(recursive: true);
    });
    await tester.runAsync(() => cache.ready);

    const key = (pluginId: 'video-test', contentId: 'series', groupId: 'season', episodeId: 'episode-1');
    final resolution = Completer<VideoEpisode>();
    var resolutionRequests = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceVideoCacheProvider.overrideWithValue(cache)],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSourceVideoDownloadActions(
                  context,
                  cache: cache,
                  key: key,
                  title: '测试剧集',
                  episodeTitle: '第 1 集',
                  resolve: () {
                    resolutionRequests++;
                    return resolution.future;
                  },
                ),
                child: const Text('打开下载菜单'),
              ),
            ),
          ),
        ),
      ),
    );

    await _tap(tester, '打开下载菜单');
    await _tap(tester, '下载此集');
    expect(resolutionRequests, 1);
    expect(cache.entryOf(key)?.status, SourceVideoCacheStatus.downloading);

    await _tap(tester, '打开下载菜单');
    expect(find.textContaining('下载中'), findsOneWidget);
    await _tap(tester, '下载列表');
    expect(find.text('测试剧集'), findsOneWidget);
    expect(find.text('第 1 集'), findsOneWidget);

    await _tap(tester, '取消下载');
    expect(find.text('暂无下载的视频'), findsOneWidget);
    expect(cache.entryOf(key), isNull);
  });
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.runAsync(() => tester.tap(find.text(label)));
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}
