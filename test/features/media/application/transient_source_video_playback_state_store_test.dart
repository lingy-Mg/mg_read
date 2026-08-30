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
    final item = await library.bookshelf.addFromSource(
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
}
