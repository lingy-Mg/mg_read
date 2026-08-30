/// 书架音频进度适配器测试。
///
/// 职责：
/// - 验证播放器章节与章内毫秒位置会写入 Content Library。
/// - 验证新播放器会话能从持久层恢复完整进度。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  test('persists shelf audio chapter and in-track position across sessions', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-audio-progress-store-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.bookshelf.addFromSource(
      const BookshelfAddRequest(
        title: '音频书架条目',
        author: null,
        kind: ContentKind.audio,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'audio-1',
      ),
    );
    final first = TransientSourceAudioPlaybackStateStore(
      collectionId: 'audio-1',
      initialTrackId: 'chapter-1',
      library: library,
      libraryItemId: item.id,
    );
    await first.saveProgress(
      AudioPlaybackProgress(
        collectionId: 'audio-1',
        trackId: 'chapter-7',
        position: const Duration(minutes: 12, seconds: 34, milliseconds: 567),
        updatedAt: DateTime.utc(2026, 8, 30),
      ),
    );

    final second = TransientSourceAudioPlaybackStateStore(
      collectionId: 'audio-1',
      initialTrackId: 'chapter-1',
      library: library,
      libraryItemId: item.id,
    );
    final restored = await second.loadProgress('audio-1');

    expect(restored?.trackId, 'chapter-7');
    expect(restored?.position, const Duration(minutes: 12, seconds: 34, milliseconds: 567));
    expect(await second.loadProgress('other-audio'), isNull);
  });
}
