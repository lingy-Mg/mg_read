/// Real MediaKit/mpv regression for shelf resume after a seek and player close.
/// Uses a temporary silent WAV and on-disk library, without network or Runtime.
/// Run with MGREAD_TEST_LIBMPV pointing to the host's libmpv DLL/shared library;
/// absent native libraries skip this explicit platform test in portable suites.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:media_kit/media_kit.dart' as media_kit;
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  final nativeLibrary = Platform.environment['MGREAD_TEST_LIBMPV'];
  test('native seek flushes its new timestamp and shelf resume restores it before playback', () async {
    media_kit.MediaKit.ensureInitialized(libmpv: nativeLibrary!);
    final root = await Directory.systemTemp.createTemp('mg-read-native-audio-');
    var library = await ContentLibrary.open(dataRoot: root);
    final engines = <AudioPlayerEngine>[];
    addTearDown(() async {
      for (final engine in engines) {
        await engine.close();
      }
      await library.close();
      await root.delete(recursive: true);
    });
    final wav = await _silentWav(root);
    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '原生音频续播',
        author: null,
        kind: ContentKind.audio,
        pluginId: 'native.fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'audio-1',
      ),
    );
    AudioPlayerEngine openEngine() {
      final engine = AudioPlayerEngine(
        collectionId: 'audio-1',
        dataSource: _LocalAudio(wav.uri),
        stateStore: TransientSourceAudioPlaybackStateStore(
          collectionId: 'audio-1',
          initialTrackId: 'chapter-1',
          library: library,
          libraryItemId: item.id,
        ),
        saveInterval: const Duration(seconds: 10),
      );
      engines.add(engine);
      return engine;
    }

    final first = openEngine();
    await first.initialize();
    // The command Future must await native position delivery. Closing right
    // after dragging must not flush the old zero timestamp.
    await first.controller.seek(const Duration(seconds: 42));
    await first.controller.requestExit();
    await first.controller.pause();
    await first.close();
    final saved = await library.loadProgress(item.id) as LibraryAudioPlaybackProgress;
    expect(saved.position.inSeconds, inInclusiveRange(41, 44));
    await library.close();
    library = await ContentLibrary.open(dataRoot: root);

    final reopened = openEngine();
    await reopened.initialize();
    expect(reopened.snapshot.failure, isNull);
    expect(reopened.snapshot.position.inSeconds, inInclusiveRange(41, 44));
    // A silent early seek would appear successful until the actual native
    // time stream arrives. Check after playback has really advanced too.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(reopened.snapshot.position.inSeconds, inInclusiveRange(42, 47));
    await reopened.controller.seek(const Duration(seconds: 67));
    await reopened.handleLifecycle(AudioPlayerLifecycleState.hidden);
    expect((await library.loadProgress(item.id) as LibraryAudioPlaybackProgress).position.inSeconds, inInclusiveRange(66, 69));
  }, skip: nativeLibrary == null ? 'Set MGREAD_TEST_LIBMPV for the real native audio regression.' : false);
}

final class _LocalAudio implements AudioPlayerDataSource {
  const _LocalAudio(this.uri);
  final Uri uri;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async => AudioPlaylist(
    collectionId: collectionId,
    title: '本地原生测试',
    tracks: [AudioTrack(id: 'chapter-1', title: '第一章', resource: uri)],
  );
}

Future<File> _silentWav(Directory root) async {
  final bytes = Uint8List(44 + 8000 * 2 * 90);
  final header = ByteData.sublistView(bytes);
  void tag(int offset, String value) => bytes.setRange(offset, offset + value.length, value.codeUnits);
  tag(0, 'RIFF');
  header.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 8000, Endian.little);
  header.setUint32(28, 16000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, bytes.length - 44, Endian.little);
  return File('${root.path}/sample.wav').writeAsBytes(bytes);
}
