/// Public engine and controlled-view lifecycle tests.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  testWidgets(
    'controlled views can disappear and rebuild without reopening playback',
    (tester) async {
      final backend = _EngineBackend();
      final controller = AudioPlayerController();
      final engine = AudioPlayerEngine(
        collectionId: 'book',
        dataSource: const _EngineDataSource(),
        stateStore: _EngineStateStore(),
        backend: backend,
        controller: controller,
      );
      await engine.initialize();

      await tester.pumpWidget(
        MaterialApp(home: AudioPlayerView.controlled(controller: controller)),
      );
      expect(find.byKey(const Key('audio-play-pause')), findsOneWidget);
      expect(backend.openCalls, 1);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      expect(controller.isAttached, isTrue);
      expect(backend.disposeCalls, 0);

      await controller.seek(const Duration(seconds: 42));
      await tester.pumpWidget(
        MaterialApp(home: AudioPlayerView.controlled(controller: controller)),
      );
      expect(controller.snapshot.position, const Duration(seconds: 42));
      expect(backend.openCalls, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await engine.close();
      await engine.close();
      expect(backend.disposeCalls, 1);
      controller.dispose();
    },
  );
}

final class _EngineDataSource implements AudioPlayerDataSource {
  const _EngineDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: collectionId,
        title: '测试音频',
        tracks: <AudioTrack>[
          AudioTrack(
            id: 'chapter-1',
            title: '第一章',
            resource: Uri.parse('https://example.test/audio.mp3'),
          ),
        ],
      );
}

final class _EngineStateStore implements AudioPlaybackStateStore {
  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      null;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {}
}

final class _EngineBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _events =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 2),
  );
  int openCalls = 0;
  int disposeCalls = 0;

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _events.stream;

  void _emit(AudioPlaybackBackendSnapshot snapshot) {
    _snapshot = snapshot;
    _events.add(snapshot);
  }

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    openCalls++;
    _emit(
      AudioPlaybackBackendSnapshot(
        currentIndex: initialIndex,
        duration: const Duration(minutes: 2),
        playing: play,
      ),
    );
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {}

  @override
  Future<void> play() async => _emit(_snapshot.copyWith(playing: true));

  @override
  Future<void> pause() async => _emit(_snapshot.copyWith(playing: false));

  @override
  Future<void> seek(Duration position) async =>
      _emit(_snapshot.copyWith(position: position));

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
  Future<void> jump(int index) async {}

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
