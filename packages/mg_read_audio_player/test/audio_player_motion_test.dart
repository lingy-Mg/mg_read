/// Playback motion tests for the package-owned portrait audio surface.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  testWidgets('active playback drives indicator cover and glass controls', (
    tester,
  ) async {
    final backend = _MotionBackend();
    await tester.pumpWidget(
      _motionHost(backend: backend, disableAnimations: false),
    );
    await tester.pump();
    await tester.pump();

    final indicatorBar = find.byKey(const Key('audio-playing-indicator-bar-0'));
    final pausedBarHeight = tester.getSize(indicatorBar).height;
    final pausedCoverY = tester
        .getTopLeft(find.byKey(const Key('audio-cover')))
        .dy;
    final backdropMotion = find.byKey(
      const Key('audio-artwork-backdrop-motion'),
    );
    final pausedBackdropTransform = List<double>.of(
      tester.widget<Transform>(backdropMotion).transform.storage,
    );
    expect(
      find.ancestor(
        of: find.byKey(const Key('audio-play-pause')),
        matching: find.byType(BackdropFilter),
      ),
      findsAtLeastNWidgets(2),
    );

    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getSize(indicatorBar).height, isNot(pausedBarHeight));
    final backdropTint = tester.widget<AnimatedContainer>(
      find.byKey(const Key('audio-artwork-backdrop-tint')),
    );
    expect(
      (backdropTint.decoration! as BoxDecoration).color,
      const Color(0x78000000),
    );
    await tester.pump(const Duration(milliseconds: 1540));
    expect(
      tester.getTopLeft(find.byKey(const Key('audio-cover'))).dy,
      isNot(closeTo(pausedCoverY, 0.01)),
    );
    expect(
      tester.widget<Transform>(backdropMotion).transform.storage,
      isNot(orderedEquals(pausedBackdropTransform)),
    );
  });

  testWidgets('buffering and reduced motion stop decorative movement', (
    tester,
  ) async {
    final backend = _MotionBackend();
    await tester.pumpWidget(
      _motionHost(backend: backend, disableAnimations: true, autoplay: true),
    );
    await tester.pump();
    await tester.pump();

    final indicatorBar = find.byKey(const Key('audio-playing-indicator-bar-1'));
    final initialBarHeight = tester.getSize(indicatorBar).height;
    final initialCoverY = tester
        .getTopLeft(find.byKey(const Key('audio-cover')))
        .dy;
    final backdropMotion = find.byKey(
      const Key('audio-artwork-backdrop-motion'),
    );
    final initialBackdropTransform = List<double>.of(
      tester.widget<Transform>(backdropMotion).transform.storage,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(tester.getSize(indicatorBar).height, initialBarHeight);
    expect(
      tester.getTopLeft(find.byKey(const Key('audio-cover'))).dy,
      closeTo(initialCoverY, 0.01),
    );
    expect(
      tester.widget<Transform>(backdropMotion).transform.storage,
      orderedEquals(initialBackdropTransform),
    );
    expect(find.byKey(const Key('audio-buffering')), findsNothing);

    backend.setBuffering(true);
    await tester.pump();
    expect(find.text('正在缓冲'), findsOneWidget);
    expect(find.byKey(const Key('audio-buffering')), findsOneWidget);
  });

  testWidgets('seek and chapter controls expose directional feedback', (
    tester,
  ) async {
    final backend = _MotionBackend();
    await tester.pumpWidget(
      _motionHost(backend: backend, disableAnimations: false),
    );
    await tester.pump();
    await tester.pump();

    final seekMotion = find.byKey(const Key('audio-seek-forward-motion'));
    expect(tester.widget<AnimatedRotation>(seekMotion).turns, 0);
    await tester.tap(find.byKey(const Key('audio-seek-forward')));
    await tester.pump();
    expect(backend.snapshot.position, const Duration(seconds: 15));
    expect(tester.widget<AnimatedRotation>(seekMotion).turns, greaterThan(0));

    await tester.tap(find.byKey(const Key('audio-next')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const Key('audio-cover-switch-forward')), findsOneWidget);
    expect(backend.snapshot.currentIndex, 1);

    await tester.tap(find.byKey(const Key('audio-previous')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.byKey(const Key('audio-cover-switch-backward')),
      findsOneWidget,
    );
    expect(backend.snapshot.currentIndex, 0);
  });
}

Widget _motionHost({
  required _MotionBackend backend,
  required bool disableAnimations,
  bool autoplay = false,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.light(useMaterial3: true),
    home: MediaQuery(
      data: const MediaQueryData().copyWith(
        size: const Size(390, 844),
        disableAnimations: disableAnimations,
      ),
      child: AudioPlayerView(
        collectionId: 'motion-book',
        dataSource: const _MotionDataSource(),
        stateStore: const _MotionStateStore(),
        observer: const AudioPlayerObserver(),
        backend: backend,
        autoplay: autoplay,
        saveInterval: const Duration(hours: 1),
      ),
    ),
  );
}

final class _MotionDataSource implements AudioPlayerDataSource {
  const _MotionDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: collectionId,
        title: '动效测试书场',
        creator: '测试播讲',
        tracks: <AudioTrack>[
          AudioTrack(
            id: 'track-1',
            title: '第一集',
            resource: Uri.parse('https://example.test/1.mp3'),
          ),
          AudioTrack(
            id: 'track-2',
            title: '第二集',
            resource: Uri.parse('https://example.test/2.mp3'),
          ),
        ],
      );
}

final class _MotionStateStore implements AudioPlaybackStateStore {
  const _MotionStateStore();

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      null;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {}
}

final class _MotionBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _controller =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 2),
  );
  List<AudioTrack> _tracks = const <AudioTrack>[];

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _controller.stream;

  void _emit(AudioPlaybackBackendSnapshot value) {
    _snapshot = value;
    _controller.add(value);
  }

  void setBuffering(bool value) {
    _emit(_snapshot.copyWith(buffering: value));
  }

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    _tracks = List<AudioTrack>.of(tracks);
    _emit(
      AudioPlaybackBackendSnapshot(
        currentIndex: initialIndex,
        duration: const Duration(minutes: 2),
        playing: play,
      ),
    );
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {
    _tracks = <AudioTrack>[..._tracks, ...tracks];
  }

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
  Future<void> previous() =>
      jump((_snapshot.currentIndex - 1).clamp(0, _tracks.length - 1));

  @override
  Future<void> next() =>
      jump((_snapshot.currentIndex + 1).clamp(0, _tracks.length - 1));

  @override
  Future<void> jump(int index) async =>
      _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));

  @override
  Future<void> dispose() => _controller.close();
}
