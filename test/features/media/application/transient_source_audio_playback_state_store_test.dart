/// 书架音频进度适配器测试。
///
/// 职责：
/// - 验证播放器章节与章内毫秒位置会写入 Content Library。
/// - 验证新播放器会话能从持久层恢复完整进度。
/// - 验证实时开关阻止持久层读写，并保留会话恢复和旧记录。
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
    final item = await library.addLibraryItem(
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

  test('live preference gates durable progress while preserving session recovery and old records', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-audio-remember-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '音频续播',
        author: null,
        kind: ContentKind.audio,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'audio-1',
      ),
    );
    var remember = true;
    TransientSourceAudioPlaybackStateStore store() => TransientSourceAudioPlaybackStateStore(
      collectionId: 'audio-1',
      initialTrackId: 'chapter-2',
      library: library,
      libraryItemId: item.id,
      rememberPosition: () => remember,
    );
    AudioPlaybackProgress progress(String chapter, int seconds) => AudioPlaybackProgress(
      collectionId: 'audio-1',
      trackId: chapter,
      position: Duration(seconds: seconds),
      updatedAt: DateTime.utc(2026, 10, 23),
    );
    await store().saveProgress(progress('chapter-7', 754));

    remember = false;
    final disabled = store();
    final start = await disabled.loadProgress('audio-1');
    expect(start?.trackId, 'chapter-2');
    expect(start?.position, Duration.zero);
    await disabled.saveProgress(progress('chapter-3', 42));
    final inSession = await disabled.loadProgress('audio-1');
    expect(inSession?.trackId, 'chapter-3');
    expect(inSession?.position, const Duration(seconds: 42));

    final original = await library.loadProgress(item.id) as LibraryAudioPlaybackProgress;
    expect(original.chapterId, 'chapter-7');
    expect(original.position, const Duration(seconds: 754));
    // A later disabled session starts at the requested chapter again.
    expect((await store().loadProgress('audio-1'))?.position, Duration.zero);

    remember = true;
    // Re-enabling does not rewind the active session to its old shelf position.
    expect((await disabled.loadProgress('audio-1'))?.position, const Duration(seconds: 42));
    expect((await store().loadProgress('audio-1'))?.position, const Duration(seconds: 754));
    await disabled.saveProgress(progress('chapter-3', 61));
    expect((await store().loadProgress('audio-1'))?.position, const Duration(seconds: 61));

    remember = false;
    await disabled.saveProgress(progress('chapter-4', 10));
    remember = true;
    final restored = await store().loadProgress('audio-1');
    expect(restored?.trackId, 'chapter-3');
    expect(restored?.position, const Duration(seconds: 61));
  });

  test('discovery playback keeps memory-only recovery even with recording disabled', () async {
    final store = TransientSourceAudioPlaybackStateStore(
      collectionId: 'audio-1',
      initialTrackId: 'chapter-1',
      rememberPosition: () => false,
    );
    await store.saveProgress(
      AudioPlaybackProgress(
        collectionId: 'audio-1',
        trackId: 'chapter-2',
        position: const Duration(seconds: 20),
        updatedAt: DateTime.utc(2026, 10, 23),
      ),
    );
    await store.saveProgress(
      AudioPlaybackProgress(collectionId: 'other', trackId: 'wrong', position: Duration.zero, updatedAt: DateTime.utc(2026, 10, 23)),
    );
    final resumed = await store.loadProgress('audio-1');
    expect(resumed?.trackId, 'chapter-2');
    expect(resumed?.position, const Duration(seconds: 20));
    expect(await store.loadProgress('other'), isNull);
  });
}
