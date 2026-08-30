/// Audio progress lifecycle regressions independent of the rendered player UI.
///
/// Responsibilities:
/// - Verify a saved in-track timestamp is applied before autoplay begins.
/// - Verify exit waits for the latest semantic track and timestamp to persist.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mg_read_audio_player/src/core/audio_player_session.dart';

void main() {
  test(
    'restores seconds before autoplay and flushes latest seconds on exit',
    () async {
      final events = <String>[];
      final backend = _RecordingBackend(events);
      final store = _RecordingStore(
        AudioPlaybackProgress(
          collectionId: 'audio-1',
          trackId: 'chapter-2',
          position: const Duration(seconds: 42),
          updatedAt: DateTime.utc(2026),
        ),
        events,
      );
      final controller = AudioPlayerController();
      final observer = _RecordingObserver(events);
      final session = AudioPlayerSession(
        collectionId: 'audio-1',
        dataSource: const _PlaylistSource(),
        stateStore: store,
        backend: backend,
        controller: controller,
        observer: observer,
        saveInterval: const Duration(hours: 1),
      );
      addTearDown(() async {
        await session.close();
        controller.dispose();
      });

      await session.initialize();

      expect(events.take(3), <String>['open:1:false', 'seek:42', 'play']);
      expect(session.snapshot.currentTrack?.id, 'chapter-2');
      expect(session.snapshot.position, const Duration(seconds: 42));
      expect(session.snapshot.playing, isTrue);

      backend.emitPosition(const Duration(seconds: 57));
      await session.requestExit();

      expect(store.saved.last.trackId, 'chapter-2');
      expect(store.saved.last.position, const Duration(seconds: 57));
      expect(events.indexOf('save:57'), lessThan(events.indexOf('exit:57')));
    },
  );
}

final class _PlaylistSource implements AudioPlayerDataSource {
  const _PlaylistSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: collectionId,
        title: '测试听书',
        tracks: <AudioTrack>[
          AudioTrack(
            id: 'chapter-1',
            title: '第一章',
            resource: Uri.parse('https://example.com/1.mp3'),
          ),
          AudioTrack(
            id: 'chapter-2',
            title: '第二章',
            resource: Uri.parse('https://example.com/2.mp3'),
          ),
        ],
      );
}

final class _RecordingStore implements AudioPlaybackStateStore {
  _RecordingStore(this.initial, this.events);

  final AudioPlaybackProgress initial;
  final List<String> events;
  final List<AudioPlaybackProgress> saved = <AudioPlaybackProgress>[];

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      initial;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {
    saved.add(progress);
    events.add('save:${progress.position.inSeconds}');
  }
}

final class _RecordingObserver extends AudioPlayerObserver {
  const _RecordingObserver(this.events);

  final List<String> events;

  @override
  void onExitRequested(AudioPlaybackProgress? progress) {
    events.add('exit:${progress?.position.inSeconds}');
  }
}

final class _RecordingBackend implements AudioPlaybackBackend {
  _RecordingBackend(this.events);

  final List<String> events;
  final StreamController<AudioPlaybackBackendSnapshot> _snapshots =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 10),
  );

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _snapshots.stream;

  void _emit(AudioPlaybackBackendSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  void emitPosition(Duration position) =>
      _emit(_snapshot.copyWith(position: position));

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    events.add('open:$initialIndex:$play');
    _emit(
      AudioPlaybackBackendSnapshot(
        currentIndex: initialIndex,
        duration: const Duration(minutes: 10),
        playing: play,
      ),
    );
  }

  @override
  Future<void> play() async {
    events.add('play');
    _emit(_snapshot.copyWith(playing: true));
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek:${position.inSeconds}');
    _emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {}

  @override
  Future<void> pause() async => _emit(_snapshot.copyWith(playing: false));

  @override
  Future<void> setRate(double rate) async =>
      _emit(_snapshot.copyWith(rate: rate));

  @override
  Future<void> setVolume(double volume) async =>
      _emit(_snapshot.copyWith(volume: volume));

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {}

  @override
  Future<void> jump(int index) async =>
      _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));

  @override
  Future<void> dispose() => _snapshots.close();
}
