/// 书架视频进度适配器测试。
///
/// 职责：
/// - 验证播放器语义进度会映射到 Content Library 并可由新会话恢复。
///
/// 注意：
/// - 只使用临时 Content Library，不启动媒体后端或访问网络。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/media/application/transient_source_video_playback_state_store.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  test('persists shelf video progress and restores it in a new player session', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-video-progress-store-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '视频书架条目',
        author: null,
        kind: ContentKind.video,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'video-1',
      ),
    );
    final first = TransientSourceVideoPlaybackStateStore(
      contentId: 'video-1',
      initialGroupId: 'default',
      initialEpisodeId: 'episode-1',
      library: library,
      libraryItemId: item.id,
    );
    await first.save(
      const VideoPlaybackProgress(
        contentId: 'video-1',
        groupId: 'line-2',
        episodeId: 'episode-7',
        position: Duration(minutes: 12),
        duration: Duration(minutes: 40),
      ),
    );

    final second = TransientSourceVideoPlaybackStateStore(
      contentId: 'video-1',
      initialGroupId: 'default',
      initialEpisodeId: 'episode-1',
      library: library,
      libraryItemId: item.id,
    );
    final restored = await second.load('video-1');

    expect(restored?.groupId, 'line-2');
    expect(restored?.episodeId, 'episode-7');
    expect(restored?.position, const Duration(minutes: 12));
    expect(restored?.duration, const Duration(minutes: 40));
    expect(await second.load('other-video'), isNull);
  });

  test('persists unshelved source video history and explicit remote position wins', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-video-history-store-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final first = TransientSourceVideoPlaybackStateStore(
      contentId: 'unshelved',
      initialGroupId: 'line',
      initialEpisodeId: 'ep-1',
      library: library,
      pluginId: 'fixture',
      pluginVersion: '2.1.0',
      title: 'Unshelved video',
      originDeviceId: 'device-a',
      playbackSessionId: 'session-a',
    );
    await first.save(
      const VideoPlaybackProgress(
        contentId: 'unshelved',
        groupId: 'line-2',
        episodeId: 'ep-7',
        position: Duration(minutes: 12),
        duration: Duration(minutes: 40),
      ),
    );
    final saved = await library.readVideoHistory(videoHistorySourceKey('fixture', 'unshelved'));
    expect(saved?.checkpoint.position, const Duration(minutes: 12));
    expect(saved?.checkpoint.localGeneration, 1);

    final remote = TransientSourceVideoPlaybackStateStore(
      contentId: 'unshelved',
      initialGroupId: 'line',
      initialEpisodeId: 'ep-1',
      library: library,
      initialPosition: Duration.zero,
      pluginId: 'fixture',
      pluginVersion: '2.1.0',
      title: 'Unshelved video',
      originDeviceId: 'device-b',
      playbackSessionId: 'session-b',
    );
    final overridden = await remote.load('unshelved');
    expect(overridden?.groupId, 'line');
    expect(overridden?.episodeId, 'ep-1');
    expect(overridden?.position, Duration.zero);
  });

  test('private shelf video progress does not create shareable video history', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-private-video-history-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: 'Private video',
        author: null,
        kind: ContentKind.video,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'private-video',
      ),
    );
    await library.setLibraryItemVisibility(item.id, LibraryVisibility.private);
    final store = TransientSourceVideoPlaybackStateStore(
      contentId: 'private-video',
      initialGroupId: 'default',
      initialEpisodeId: 'episode-1',
      library: library,
      libraryItemId: item.id,
      pluginId: 'fixture',
      pluginVersion: '1.0.0',
      title: 'Private video',
      originDeviceId: 'device-a',
      playbackSessionId: 'session-private',
      privateContent: true,
    );
    await store.save(
      const VideoPlaybackProgress(
        contentId: 'private-video',
        groupId: 'default',
        episodeId: 'episode-2',
        position: Duration(seconds: 18),
        duration: Duration(minutes: 20),
      ),
    );
    expect(await library.readVideoHistory(videoHistorySourceKey('fixture', 'private-video')), isNull);
    expect(store.saveFailure, isFalse);
  });

  test('history generation stays fixed per session and stale sessions cannot replace newer progress', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-video-generation-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    TransientSourceVideoPlaybackStateStore create(String session) => TransientSourceVideoPlaybackStateStore(
      contentId: 'video',
      initialGroupId: 'line',
      initialEpisodeId: 'episode',
      library: library,
      pluginId: 'fixture',
      pluginVersion: '1.0',
      title: 'Video',
      originDeviceId: 'device',
      playbackSessionId: session,
    );
    const progress = VideoPlaybackProgress(
      contentId: 'video',
      groupId: 'line',
      episodeId: 'episode',
      position: Duration(seconds: 1),
      duration: Duration(minutes: 10),
    );
    VideoPlaybackProgress at(int seconds) => VideoPlaybackProgress(
      contentId: 'video',
      groupId: 'line',
      episodeId: 'episode',
      position: Duration(seconds: seconds),
      duration: const Duration(minutes: 10),
    );
    final a = create('session-a');
    await a.save(progress);
    final b = create('session-b');
    await b.save(at(2));
    final afterB = await library.readVideoHistory(videoHistorySourceKey('fixture', 'video'));
    await b.save(at(3));
    final sameSession = await library.readVideoHistory(videoHistorySourceKey('fixture', 'video'));
    expect(sameSession?.checkpoint.localGeneration, afterB?.checkpoint.localGeneration);
    expect(sameSession?.checkpoint.sequence, greaterThan(afterB!.checkpoint.sequence));
    await expectLater(a.save(at(4)), throwsStateError);
    await expectLater(a.save(at(5)), throwsStateError);
    final latest = await library.readVideoHistory(videoHistorySourceKey('fixture', 'video'));
    expect(latest?.checkpoint.playbackSessionId, 'session-b');
    expect(latest?.checkpoint.position, const Duration(seconds: 3));
  });

  test('prepared store buffers progress until activation', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-video-staged-history-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final store = TransientSourceVideoPlaybackStateStore(
      contentId: 'video',
      initialGroupId: 'line',
      initialEpisodeId: 'episode',
      library: library,
      pluginId: 'fixture',
      pluginVersion: '1.0',
      title: 'Video',
      originDeviceId: 'device',
      playbackSessionId: 'staged',
      initiallyActive: false,
    );
    await store.save(
      const VideoPlaybackProgress(
        contentId: 'video',
        groupId: 'line',
        episodeId: 'episode',
        position: Duration(seconds: 1),
        duration: Duration(minutes: 10),
      ),
    );
    expect(await library.readVideoHistory(videoHistorySourceKey('fixture', 'video')), isNull);
    await store.activate();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await library.readVideoHistory(videoHistorySourceKey('fixture', 'video')))?.checkpoint.position, const Duration(seconds: 1));
  });

  test('a large generation from another device does not block a local session', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-video-remote-generation-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    await library.saveVideoHistory(
      VideoHistoryCheckpoint(
        pluginId: 'fixture',
        contentId: 'video',
        pluginVersion: '1.0',
        title: 'Video',
        groupId: 'line',
        episodeId: 'episode',
        position: const Duration(seconds: 7),
        duration: const Duration(minutes: 10),
        originDeviceId: 'remote',
        playbackSessionId: 'remote-session',
        sequence: 1,
        localGeneration: 500,
        updatedAtUtc: DateTime.utc(2026),
      ),
      expectedLocalRevision: 0,
      remote: true,
    );
    final local = TransientSourceVideoPlaybackStateStore(
      contentId: 'video',
      initialGroupId: 'line',
      initialEpisodeId: 'episode',
      library: library,
      pluginId: 'fixture',
      pluginVersion: '1.0',
      title: 'Video',
      originDeviceId: 'local',
      playbackSessionId: 'local-session',
    );
    await local.save(
      const VideoPlaybackProgress(
        contentId: 'video',
        groupId: 'line',
        episodeId: 'episode',
        position: Duration(seconds: 8),
        duration: Duration(minutes: 10),
      ),
    );
    final latest = await library.readVideoHistory(videoHistorySourceKey('fixture', 'video'));
    expect(latest?.checkpoint.originDeviceId, 'local');
    expect(latest?.checkpoint.localGeneration, 1);
    expect(local.saveFailure, isFalse);
  });

  test('a remote compare-and-swap conflict stays authoritative over later local saves', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-video-remote-cas-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final local = TransientSourceVideoPlaybackStateStore(
      contentId: 'video',
      initialGroupId: 'line',
      initialEpisodeId: 'episode',
      library: library,
      pluginId: 'fixture',
      pluginVersion: '1.0',
      title: 'Video',
      originDeviceId: 'local',
      playbackSessionId: 'local-session',
    );
    const localProgress = VideoPlaybackProgress(
      contentId: 'video',
      groupId: 'line',
      episodeId: 'episode',
      position: Duration(seconds: 1),
      duration: Duration(minutes: 10),
    );
    await local.save(localProgress);
    final current = await library.readVideoHistory(videoHistorySourceKey('fixture', 'video'));
    await library.saveVideoHistory(
      VideoHistoryCheckpoint(
        pluginId: 'fixture',
        contentId: 'video',
        pluginVersion: '1.0',
        title: 'Video',
        groupId: 'line',
        episodeId: 'episode',
        position: const Duration(seconds: 9),
        duration: const Duration(minutes: 10),
        originDeviceId: 'remote',
        playbackSessionId: 'remote-session',
        sequence: 1,
        localGeneration: 1,
        updatedAtUtc: DateTime.utc(2026),
      ),
      expectedLocalRevision: current!.revision,
      remote: true,
    );
    await expectLater(
      local.save(
        const VideoPlaybackProgress(
          contentId: 'video',
          groupId: 'line',
          episodeId: 'episode',
          position: Duration(seconds: 2),
          duration: Duration(minutes: 10),
        ),
      ),
      throwsStateError,
    );
    await expectLater(
      local.save(
        const VideoPlaybackProgress(
          contentId: 'video',
          groupId: 'line',
          episodeId: 'episode',
          position: Duration(seconds: 3),
          duration: Duration(minutes: 10),
        ),
      ),
      throwsStateError,
    );
    expect((await library.readVideoHistory(videoHistorySourceKey('fixture', 'video')))?.checkpoint.originDeviceId, 'remote');
    expect((await library.readVideoHistory(videoHistorySourceKey('fixture', 'video')))?.checkpoint.position, const Duration(seconds: 9));
  });
}
