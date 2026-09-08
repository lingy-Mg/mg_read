/// Product behavior tests for completion, navigation, lock and desktop input.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  testWidgets('completion advances to the next ordered episode', (
    tester,
  ) async {
    final backend = _Backend();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(backend: backend, controller: controller));
    await tester.pumpAndSettle();

    backend.complete();
    await tester.pumpAndSettle();

    expect(backend.opened, <String>['episode-1', 'episode-2']);
    expect(controller.snapshot.activeEpisodeId, 'episode-2');
  });

  testWidgets('disabled auto advance shows replay and next actions', (
    tester,
  ) async {
    final backend = _Backend();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(backend: backend, controller: controller, autoAdvance: false),
    );
    await tester.pumpAndSettle();

    backend.complete();
    await tester.pump();
    expect(find.byKey(const Key('video-player-completed')), findsOneWidget);

    await tester.tap(find.byKey(const Key('video-player-replay')));
    await tester.pump();
    expect(backend.seeks.last, Duration.zero);
    expect(backend.state.value.playing, isTrue);

    backend.complete();
    await tester.pump();
    await tester.tap(find.byKey(const Key('video-player-completed-next')));
    await tester.pumpAndSettle();
    expect(controller.snapshot.activeEpisodeId, 'episode-2');
  });

  testWidgets('near-end progress restarts instead of reopening at EOF', (
    tester,
  ) async {
    final backend = _Backend();
    await tester.pumpWidget(
      _app(
        backend: backend,
        restored: const VideoPlaybackProgress(
          contentId: 'show',
          groupId: 'group-a',
          episodeId: 'episode-1',
          position: Duration(seconds: 116),
          duration: Duration(minutes: 2),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.openPositions.single, Duration.zero);
  });

  testWidgets('fullscreen lock blocks gestures until explicitly unlocked', (
    tester,
  ) async {
    final backend = _Backend();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(backend: backend, controller: controller));
    await tester.pumpAndSettle();

    await controller.requestFullscreen(true);
    await controller.setControlsLocked(true);
    await tester.pump();
    expect(find.byKey(const Key('video-player-controls-lock')), findsOneWidget);

    await tester.dragFrom(const Offset(200, 250), const Offset(200, 0));
    await tester.pump();
    expect(backend.seeks, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(controller.snapshot.controlsLocked, isFalse);
  });

  testWidgets('desktop shortcuts cover fullscreen mute volume and episodes', (
    tester,
  ) async {
    final backend = _Backend();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(backend: backend, controller: controller));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(controller.snapshot.fullscreenRequested, isTrue);

    await controller.setVolume(45);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(backend.state.value.volume, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(backend.state.value.volume, 45);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(backend.state.value.volume, 50);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(controller.snapshot.activeEpisodeId, 'episode-2');
  });

  testWidgets('slider exposes backend buffered position', (tester) async {
    final backend = _Backend();
    await tester.pumpWidget(_app(backend: backend));
    await tester.pumpAndSettle();

    backend.buffer(const Duration(seconds: 70));
    await tester.pump();
    final slider = tester.widget<Slider>(
      find.byKey(const Key('video-player-slider')),
    );
    expect(slider.secondaryTrackValue, 70000);
  });

  testWidgets('missing first frame becomes a recoverable timeout', (
    tester,
  ) async {
    final backend = _Backend(firstFrameReady: false);
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        backend: backend,
        controller: controller,
        firstFrameTimeout: const Duration(milliseconds: 50),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(controller.snapshot.failure?.code, 'first_frame_timeout');
    expect(find.byKey(const Key('video-player-retry')), findsOneWidget);
  });
}

Widget _app({
  required _Backend backend,
  VideoPlayerController? controller,
  VideoPlaybackProgress? restored,
  bool autoAdvance = true,
  Duration firstFrameTimeout = const Duration(seconds: 25),
}) => MaterialApp(
  home: VideoPlayerView(
    contentId: 'show',
    dataSource: const _Source(),
    stateStore: _Store(restored),
    controller: controller,
    backendFactory: () => backend,
    autoAdvance: autoAdvance,
    controlsAutoHideDelay: const Duration(hours: 1),
    firstFrameTimeout: firstFrameTimeout,
  ),
);

final class _Source implements VideoDataSource {
  const _Source();

  @override
  Future<VideoContent> load(String contentId) async => VideoContent(
    id: contentId,
    title: '演示视频',
    groups: <VideoEpisodeGroup>[
      VideoEpisodeGroup(
        id: 'group-a',
        title: '正片',
        episodes: <VideoEpisode>[_episode('episode-1'), _episode('episode-2')],
      ),
      VideoEpisodeGroup(
        id: 'group-b',
        title: '续篇',
        episodes: <VideoEpisode>[_episode('episode-3')],
      ),
    ],
  );

  static VideoEpisode _episode(String id) => VideoEpisode(
    id: id,
    title: id,
    uri: 'https://example.test/$id.mp4',
    durationHint: const Duration(minutes: 2),
  );
}

final class _Store implements VideoPlaybackStateStore {
  const _Store(this.restored);

  final VideoPlaybackProgress? restored;

  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => restored;

  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}

final class _Backend implements VideoPlaybackBackend {
  _Backend({this.firstFrameReady = true});

  final bool firstFrameReady;
  @override
  final ValueNotifier<VideoPlaybackBackendState> state =
      ValueNotifier<VideoPlaybackBackendState>(
        const VideoPlaybackBackendState(),
      );
  final List<String> opened = <String>[];
  final List<Duration> openPositions = <Duration>[];
  final List<Duration> seeks = <Duration>[];

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) =>
      ColoredBox(key: key, color: Colors.black);

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) async {
    opened.add(episode.id);
    openPositions.add(initialPosition);
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: episode.durationHint ?? Duration.zero,
      firstFrameReady: firstFrameReady,
    );
  }

  void complete() => state.value = state.value.copyWith(
    playing: false,
    position: state.value.duration,
    completed: true,
  );

  void buffer(Duration position) =>
      state.value = state.value.copyWith(bufferedPosition: position);

  @override
  Future<void> play() async =>
      state.value = state.value.copyWith(playing: true, completed: false);

  @override
  Future<void> pause() async =>
      state.value = state.value.copyWith(playing: false);

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state.value = state.value.copyWith(position: position, completed: false);
  }

  @override
  Future<void> setRate(double rate) async =>
      state.value = state.value.copyWith(rate: rate);

  @override
  Future<void> setVolume(double volume) async =>
      state.value = state.value.copyWith(volume: volume);

  @override
  Future<void> dispose() async => state.dispose();
}
