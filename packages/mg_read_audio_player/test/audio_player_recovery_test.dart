/// Active-session recovery regressions for failed queue continuation.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mg_read_audio_player/src/core/audio_player_session.dart';

void main() {
  test(
    'foreground recovery retries continuation and resumes an ended track',
    () async {
      final controller = AudioPlayerController();
      final backend = _RecoveryBackend();
      final source = _RecoveringContinuationSource();
      final session = AudioPlayerSession(
        collectionId: 'book',
        dataSource: source,
        stateStore: const _MemoryStateStore(),
        backend: backend,
        controller: controller,
        autoplay: false,
        prefetchLeadTime: const Duration(seconds: 30),
        prefetchBatchSize: 1,
      );
      addTearDown(controller.dispose);

      await session.initialize();
      backend.emit(
        const AudioPlaybackBackendSnapshot(
          playing: true,
          position: Duration(seconds: 95),
          duration: Duration(seconds: 100),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(source.followingCalls, 1);

      backend.emit(
        const AudioPlaybackBackendSnapshot(
          position: Duration(seconds: 100),
          duration: Duration(seconds: 100),
        ),
      );
      await session.handleLifecycle(AudioPlayerLifecycleState.resumed);

      expect(source.followingCalls, 2);
      expect(backend.appendedIds, <String>['track-2']);
      expect(backend.nextCalls, 1);
      expect(backend.playCalls, 1);
      expect(controller.snapshot.currentTrack?.id, 'track-2');
      expect(controller.snapshot.playing, isTrue);

      await session.close();
    },
  );

  test('recovery is a no-op while active playback is healthy', () async {
    final controller = AudioPlayerController();
    final backend = _RecoveryBackend();
    final source = _RecoveringContinuationSource(failFirst: false);
    final session = AudioPlayerSession(
      collectionId: 'book',
      dataSource: source,
      stateStore: const _MemoryStateStore(),
      backend: backend,
      controller: controller,
      autoplay: false,
      prefetchLeadTime: const Duration(seconds: 30),
    );
    addTearDown(controller.dispose);

    await session.initialize();
    await controller.recover();

    expect(source.followingCalls, 0);
    expect(backend.nextCalls, 0);
    await session.close();
  });
}

final class _RecoveringContinuationSource
    implements AudioPlaylistContinuationDataSource {
  _RecoveringContinuationSource({this.failFirst = true});

  final bool failFirst;
  int followingCalls = 0;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: collectionId,
        title: '连续播放',
        tracks: <AudioTrack>[_track('track-1')],
      );

  @override
  Future<List<AudioTrack>> loadFollowingTracks(
    String collectionId, {
    required String afterTrackId,
    required int limit,
  }) async {
    followingCalls++;
    if (failFirst && followingCalls == 1) {
      throw StateError('network unavailable');
    }
    return <AudioTrack>[_track('track-2')];
  }

  static AudioTrack _track(String id) => AudioTrack(
    id: id,
    title: id,
    resource: Uri.parse('https://example.test/$id.mp3'),
  );
}

final class _MemoryStateStore implements AudioPlaybackStateStore {
  const _MemoryStateStore();

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      null;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {}
}

final class _RecoveryBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _snapshots =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(seconds: 100),
  );
  List<AudioTrack> _tracks = const <AudioTrack>[];
  final List<String> appendedIds = <String>[];
  int nextCalls = 0;
  int playCalls = 0;

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _snapshots.stream;

  void emit(AudioPlaybackBackendSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    _tracks = List<AudioTrack>.of(tracks);
    emit(_snapshot.copyWith(currentIndex: initialIndex, playing: play));
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {
    _tracks = <AudioTrack>[..._tracks, ...tracks];
    appendedIds.addAll(tracks.map((track) => track.id));
  }

  @override
  Future<void> play() async {
    playCalls++;
    emit(_snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async => emit(_snapshot.copyWith(playing: false));

  @override
  Future<void> seek(Duration position) async =>
      emit(_snapshot.copyWith(position: position));

  @override
  Future<void> setRate(double rate) async =>
      emit(_snapshot.copyWith(rate: rate));

  @override
  Future<void> setVolume(double volume) async =>
      emit(_snapshot.copyWith(volume: volume));

  @override
  Future<void> previous() async {}

  @override
  Future<void> next() async {
    nextCalls++;
    emit(_snapshot.copyWith(currentIndex: 1, position: Duration.zero));
  }

  @override
  Future<void> jump(int index) async =>
      emit(_snapshot.copyWith(currentIndex: index));

  @override
  Future<void> dispose() async => _snapshots.close();
}
