/// Responsive layout tests for the package-owned video chrome and selector.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  testWidgets('chrome bands are full-bleed, flat, and compact', (tester) async {
    await tester.pumpWidget(_playerApp(backend: _Backend()));
    await tester.pumpAndSettle();

    final top = find.byKey(const Key('video-player-top-band'));
    final bottom = find.byKey(const Key('video-player-bottom-band'));
    final logicalWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;

    expect(tester.getTopLeft(top).dx, 0);
    expect(tester.getSize(top).width, logicalWidth);
    expect(tester.getBottomRight(bottom), Offset(logicalWidth, logicalHeight));
    expect(_clip(tester, top).borderRadius, BorderRadius.zero);
    expect(_clip(tester, bottom).borderRadius, BorderRadius.zero);
    expect(
      tester.getSize(find.byKey(const Key('video-player-transport'))).height,
      lessThan(64),
    );
  });

  testWidgets('landscape selector uses flat compact two-column rows', (
    tester,
  ) async {
    await tester.pumpWidget(_playerApp(backend: _Backend()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-player-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final selected = tester.widget<ListTile>(
      find.byKey(const Key('video-player-episode-group-a-episode-1')),
    );
    expect(selected.shape, isNull);
    expect(selected.dense, isTrue);
    expect(find.byType(GridView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('portrait selector stays single-column without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_playerApp(backend: _Backend()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('video-player-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double tap toggles playback and reports awake lifetime', (
    tester,
  ) async {
    final backend = _Backend();
    final observer = _Observer();
    await tester.pumpWidget(_playerApp(backend: backend, observer: observer));
    await tester.pumpAndSettle();
    expect(observer.playbackActive, <bool>[true]);

    final target =
        tester.getTopLeft(find.byKey(const Key('video-player-gesture-layer'))) +
        const Offset(650, 240);
    await tester.tapAt(target);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(target);
    await tester.pumpAndSettle();

    expect(backend.state.value.playing, isFalse);
    expect(observer.playbackActive, <bool>[true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(observer.playbackActive.last, isFalse);
  });

  testWidgets('horizontal and vertical gestures seek, dim, and change volume', (
    tester,
  ) async {
    final backend = _Backend();
    final observer = _Observer();
    await tester.pumpWidget(_playerApp(backend: backend, observer: observer));
    await tester.pumpAndSettle();

    await tester.dragFrom(const Offset(180, 260), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(backend.seeks.single, greaterThan(Duration.zero));

    await tester.dragFrom(const Offset(120, 280), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(observer.brightness.last, greaterThan(.5));

    await tester.dragFrom(const Offset(700, 280), const Offset(0, 180));
    await tester.pumpAndSettle();
    expect(backend.volumes.last, lessThan(100));
  });

  testWidgets('long press uses 2x only while held', (tester) async {
    final backend = _Backend();
    await tester.pumpWidget(_playerApp(backend: backend));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(650, 240));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(backend.rates.last, 2);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.rates.last, 1);
  });
}

ClipRRect _clip(WidgetTester tester, Finder panel) => tester.widget<ClipRRect>(
  find.descendant(of: panel, matching: find.byType(ClipRRect)).first,
);

Widget _playerApp({required _Backend backend, VideoPlayerObserver? observer}) =>
    MaterialApp(
      home: VideoPlayerView(
        contentId: 'show',
        dataSource: const _Source(),
        stateStore: const _Store(),
        observer: observer,
        backendFactory: () => backend,
        controlsAutoHideDelay: const Duration(hours: 1),
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
        title: '播放源',
        episodes: <VideoEpisode>[
          for (var index = 1; index <= 12; index++)
            VideoEpisode(
              id: 'episode-$index',
              title: '第 $index 集',
              uri: 'https://example.test/$index.mp4',
              durationHint: const Duration(minutes: 24),
            ),
        ],
      ),
    ],
  );
}

final class _Store implements VideoPlaybackStateStore {
  const _Store();

  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => null;

  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}

final class _Backend implements VideoPlaybackBackend {
  @override
  final ValueNotifier<VideoPlaybackBackendState> state =
      ValueNotifier<VideoPlaybackBackendState>(
        const VideoPlaybackBackendState(),
      );
  final List<Duration> seeks = <Duration>[];
  final List<double> rates = <double>[];
  final List<double> volumes = <double>[];

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) =>
      ColoredBox(key: key, color: Colors.black);

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) async {
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: episode.durationHint ?? const Duration(minutes: 24),
      firstFrameReady: true,
    );
  }

  @override
  Future<void> pause() async =>
      state.value = state.value.copyWith(playing: false);

  @override
  Future<void> play() async =>
      state.value = state.value.copyWith(playing: true);

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    state.value = state.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    state.value = state.value.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    state.value = state.value.copyWith(volume: volume);
  }

  @override
  Future<void> dispose() async => state.dispose();
}

final class _Observer extends VideoPlayerObserver {
  final List<bool> playbackActive = <bool>[];
  final List<double> brightness = <double>[];

  @override
  void onPlaybackActiveChanged(bool active) => playbackActive.add(active);

  @override
  double onBrightnessReadRequested() => .5;

  @override
  void onBrightnessRequested(double value) => brightness.add(value);
}
