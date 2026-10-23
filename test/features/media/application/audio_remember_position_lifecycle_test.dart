/// Audio resume regression checks across the public engine and real library.
/// Covers pause, track changes, background flush, exit and reopening, using an
/// in-memory transport without native media, Runtime or network access.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  testWidgets('ten-second throttle saves the latest tick and pause flushes immediately', (tester) async {
    final backend = _Backend();
    final store = _RecordingStore();
    final engine = AudioPlayerEngine(
      collectionId: 'audio-1',
      dataSource: const _Playlist(),
      backend: backend,
      stateStore: store,
      saveInterval: const Duration(seconds: 10),
      recoveryStallTimeout: const Duration(minutes: 1),
    );
    try {
      await engine.initialize();
      await backend.seek(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 9));
      expect(store.saved, isEmpty);
      await backend.seek(const Duration(seconds: 14));
      await tester.pump(const Duration(seconds: 1));
      expect(store.saved.single.position, const Duration(seconds: 14));
      await backend.seek(const Duration(seconds: 16));
      await engine.controller.pause();
      expect(store.saved.last.position, const Duration(seconds: 16));
    } finally {
      await engine.close();
    }
  });

  for (final enabled in <bool>[true, false]) {
    test('engine lifecycle honors recording=$enabled and preserves the restart position', () async {
      final root = await Directory.systemTemp.createTemp('mg-read-audio-resume-lifecycle-');
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.addLibraryItem(
        const BookshelfAddRequest(
          title: '音频进度回归',
          author: null,
          kind: ContentKind.audio,
          pluginId: 'fixture',
          pluginVersion: '1.0.0',
          remoteContentId: 'audio-1',
        ),
      );
      await library.saveProgress(
        LibraryAudioPlaybackProgress(
          itemId: item.id,
          chapterId: 'chapter-2',
          position: const Duration(seconds: 42),
          updatedAtUtc: DateTime.utc(2026, 10, 23),
        ),
      );
      var remember = enabled;
      AudioPlayerEngine createEngine(_Backend backend) => AudioPlayerEngine(
        collectionId: 'audio-1',
        dataSource: const _Playlist(),
        backend: backend,
        stateStore: TransientSourceAudioPlaybackStateStore(
          collectionId: 'audio-1',
          initialTrackId: 'chapter-1',
          library: library,
          libraryItemId: item.id,
          rememberPosition: () => remember,
        ),
        saveInterval: const Duration(hours: 1),
      );
      final backend = _Backend();
      final engine = createEngine(backend);
      addTearDown(engine.close);
      await engine.initialize();
      expect(engine.snapshot.currentTrack?.id, enabled ? 'chapter-2' : 'chapter-1');
      expect(engine.snapshot.position, Duration(seconds: enabled ? 42 : 0));
      expect(backend.events.take(enabled ? 3 : 1), enabled ? ['open:1:false', 'seek:42', 'play'] : ['open:0:true']);

      await engine.controller.seek(const Duration(seconds: 57));
      await engine.controller.pause();
      await engine.controller.jump(0);
      await engine.controller.seek(const Duration(seconds: 15));
      await engine.handleLifecycle(AudioPlayerLifecycleState.paused);
      await engine.controller.requestExit();
      await engine.close();
      final saved = await library.loadProgress(item.id) as LibraryAudioPlaybackProgress;
      expect(saved.chapterId, enabled ? 'chapter-1' : 'chapter-2');
      expect(saved.position, Duration(seconds: enabled ? 15 : 42));

      // Re-enable before reopening: disabled playback must leave the old
      // chapter/time intact even after seek, pause, lifecycle, exit and close.
      remember = true;
      final reopened = createEngine(_Backend());
      addTearDown(reopened.close);
      await reopened.initialize();
      expect(reopened.snapshot.currentTrack?.id, saved.chapterId);
      expect(reopened.snapshot.position, saved.position);
      expect(reopened.snapshot.failure, isNull);
      await reopened.close();
    });
  }

  test('live toggles keep playback in place and affect subsequent lifecycle saves', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-audio-resume-toggle-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '音频实时开关',
        author: null,
        kind: ContentKind.audio,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'audio-1',
      ),
    );
    var remember = false;
    final backend = _Backend();
    final engine = AudioPlayerEngine(
      collectionId: 'audio-1',
      dataSource: const _Playlist(),
      backend: backend,
      stateStore: TransientSourceAudioPlaybackStateStore(
        collectionId: 'audio-1',
        initialTrackId: 'chapter-1',
        library: library,
        libraryItemId: item.id,
        rememberPosition: () => remember,
      ),
      saveInterval: const Duration(hours: 1),
    );
    addTearDown(engine.close);
    await engine.initialize();
    await engine.controller.seek(const Duration(seconds: 33));
    expect(await library.loadProgress(item.id), isNull);
    remember = true;
    await engine.handleLifecycle(AudioPlayerLifecycleState.hidden);
    expect(engine.snapshot.position, const Duration(seconds: 33));
    expect(engine.snapshot.playing, isTrue);
    expect((await library.loadProgress(item.id) as LibraryAudioPlaybackProgress).position, const Duration(seconds: 33));
    remember = false;
    await engine.controller.seek(const Duration(seconds: 55));
    await engine.close();
    expect((await library.loadProgress(item.id) as LibraryAudioPlaybackProgress).position, const Duration(seconds: 33));
    expect(backend.events.where((event) => event.startsWith('open:')).length, 1);
  });
}

final class _Playlist implements AudioPlayerDataSource {
  const _Playlist();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async => AudioPlaylist(
    collectionId: collectionId,
    title: '音频回归',
    tracks: [
      for (var index = 1; index <= 2; index++)
        AudioTrack(id: 'chapter-$index', title: '第 $index 章', resource: Uri.parse('https://example.test/$index.mp3')),
    ],
  );
}

final class _RecordingStore implements AudioPlaybackStateStore {
  final saved = <AudioPlaybackProgress>[];

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async => null;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async => saved.add(progress);
}

final class _Backend implements AudioPlaybackBackend {
  final _stream = StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  final events = <String>[];
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot();

  void _emit(AudioPlaybackBackendSnapshot value) {
    _snapshot = value;
    _stream.add(value);
  }

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;
  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _stream.stream;
  @override
  Future<void> open(List<AudioTrack> tracks, {required int initialIndex, bool play = false}) async {
    events.add('open:$initialIndex:$play');
    _emit(AudioPlaybackBackendSnapshot(currentIndex: initialIndex, playing: play, duration: const Duration(minutes: 3)));
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek:${position.inSeconds}');
    _emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> play() async {
    events.add('play');
    _emit(_snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async => _emit(_snapshot.copyWith(playing: false));
  @override
  Future<void> jump(int index) async => _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));
  @override
  Future<void> previous() => jump(_snapshot.currentIndex - 1);
  @override
  Future<void> next() => jump(_snapshot.currentIndex + 1);
  @override
  Future<void> append(List<AudioTrack> tracks) async {}
  @override
  Future<void> setRate(double rate) async => _emit(_snapshot.copyWith(rate: rate));
  @override
  Future<void> setVolume(double volume) async => _emit(_snapshot.copyWith(volume: volume));
  @override
  Future<void> dispose() => _stream.close();
}
