/// Responsive layout tests for the package-owned video chrome and selector.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

part 'video_player_transport_test_cases.dart';

void main() {
  _registerTransportTests();
  testWidgets(
    'touch chrome keeps progress above a visible control row and safe area',
    (tester) async {
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
      expect(
        tester.getBottomRight(bottom),
        Offset(logicalWidth, logicalHeight),
      );
      final slider = find.byKey(const Key('video-player-slider'));
      expect(tester.getSize(slider).height, 28);
      expect(
        tester.getBottomRight(bottom).dy - tester.getBottomRight(slider).dy,
        greaterThanOrEqualTo(18),
      );
      expect(find.byKey(const Key('video-player-transport')), findsNothing);
      expect(find.byKey(const Key('video-player-play-pause')), findsOneWidget);
    },
  );

  testWidgets(
    'touch playback has persistent visible play pause and ten second actions',
    (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(_playerApp(backend: backend));
      await tester.pumpAndSettle();

      await backend.pause();
      await tester.pump();

      final pausedPlay = find.byKey(const Key('video-player-play-pause'));
      expect(pausedPlay, findsOneWidget);
      expect(find.byKey(const Key('video-player-transport')), findsNothing);
      expect(find.byKey(const Key('video-player-rewind')), findsOneWidget);
      expect(find.byKey(const Key('video-player-forward')), findsOneWidget);

      await tester.tap(pausedPlay);
      await tester.pump();
      expect(backend.state.value.playing, isTrue);
      expect(pausedPlay.hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'touch separates top settings from bottom episodes and fullscreen',
    (tester) async {
      final backend = _Backend();
      await tester.pumpWidget(_playerApp(backend: backend));
      await tester.pumpAndSettle();

      final top = find.byKey(const Key('video-player-top-band'));
      final bottom = find.byKey(const Key('video-player-bottom-band'));
      expect(find.byKey(const Key('video-player-slider')), findsOneWidget);
      expect(
        find.descendant(
          of: top,
          matching: find.byKey(const Key('video-player-settings')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bottom,
          matching: find.byKey(const Key('video-player-episodes')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bottom,
          matching: find.byKey(const Key('video-player-fullscreen')),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('video-player-settings')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('video-player-settings-sheet')),
        findsOneWidget,
      );
      expect(find.text('播放设置'), findsOneWidget);
      expect(find.byKey(const Key('video-player-rate-1-5')), findsOneWidget);
      expect(find.byKey(const Key('video-player-anime4k')), findsOneWidget);
      expect(
        find.byKey(const Key('video-player-fit-default-hint')),
        findsOneWidget,
      );

      final rate = find.byKey(const Key('video-player-rate-1-5'));
      await tester.ensureVisible(rate);
      await tester.tap(rate);
      await tester.pump();
      expect(backend.rates.last, 1.5);
      expect(
        tester.widget<ChoiceChip>(rate).selected,
        isTrue,
        reason: '倍速选择需要在设置面板中立即回显',
      );

      final fit = find.byKey(const Key('video-player-fit'));
      await tester.ensureVisible(fit);
      await tester.tap(fit);
      await tester.pump();
      expect(find.text('填充'), findsOneWidget);
      expect(
        find.byKey(const Key('video-player-fit-default-hint')),
        findsNothing,
      );
    },
  );

  testWidgets('opens current playback details from the top bar', (
    tester,
  ) async {
    await tester.pumpWidget(_playerApp(backend: _Backend()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('video-player-details')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-details-sheet')), findsOneWidget);
    expect(find.text('视频详情'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('video-details-url'))).data,
      'https://example.test/1.mp4',
    );
    expect(find.byKey(const Key('video-details-url-copy')), findsOneWidget);
    expect(find.byKey(const Key('video-details-headers-copy')), findsOneWidget);
    expect(find.text('show'), findsOneWidget);
    expect(find.text('group-a'), findsOneWidget);
    expect(find.text('episode-1'), findsOneWidget);
  });

  testWidgets(
    'fullscreen keeps the same single progress control and top actions',
    (tester) async {
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _playerApp(backend: _Backend(), controller: controller),
      );
      await tester.pumpAndSettle();

      await controller.requestFullscreen(true);
      await tester.pump();

      expect(find.byKey(const Key('video-player-slider')), findsOneWidget);
      expect(find.byKey(const Key('video-player-episodes')), findsOneWidget);
      expect(find.byKey(const Key('video-player-settings')), findsOneWidget);
    },
  );

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

  testWidgets(
    'horizontal and vertical gestures seek, dim, and change system volume',
    (tester) async {
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
      expect(backend.volumes, isEmpty);
      expect(observer.systemVolumes.last, lessThan(50));
    },
  );

  testWidgets('drag seek updates the bottom slider and central target live', (
    tester,
  ) async {
    final backend = _Backend();
    await tester.pumpWidget(_playerApp(backend: backend));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(180, 260));
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(230, 0));
    await tester.pump();

    expect(find.text('拖动进度'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('video-player-seek-preview-time')))
          .data,
      matches(RegExp(r'^\d+:\d{2} / 24:00$')),
    );
    final previewSlider = tester.widget<Slider>(
      find.byKey(const Key('video-player-slider')),
    );
    expect(previewSlider.value, greaterThan(0));
    expect(backend.seeks, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(backend.seeks, hasLength(1));
    expect(find.text('拖动进度'), findsNothing);
    final committedSlider = tester.widget<Slider>(
      find.byKey(const Key('video-player-slider')),
    );
    expect(committedSlider.value, backend.seeks.single.inMilliseconds);
  });

  testWidgets('bottom progress drag shares the live central seek preview', (
    tester,
  ) async {
    final backend = _Backend();
    await tester.pumpWidget(_playerApp(backend: backend));
    await tester.pumpAndSettle();

    final sliderFinder = find.byKey(const Key('video-player-slider'));
    final gesture = await tester.startGesture(tester.getCenter(sliderFinder));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();

    expect(find.text('拖动进度'), findsOneWidget);
    expect(
      tester.widget<Slider>(sliderFinder).value,
      greaterThan(backend.state.value.position.inMilliseconds),
    );
    expect(backend.seeks, isEmpty);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(backend.seeks, hasLength(1));
    expect(find.text('拖动进度'), findsNothing);
  });

  testWidgets('long press uses 2x only while held', (tester) async {
    final backend = _Backend();
    final hapticArguments = <dynamic>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        hapticArguments.add(call.arguments);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(_playerApp(backend: backend));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(const Offset(650, 240));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(backend.rates.last, 2);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(backend.rates.last, 1);
    expect(hapticArguments, <String>[
      'HapticFeedbackType.selectionClick',
      'HapticFeedbackType.selectionClick',
    ]);
  });

  testWidgets('transient seek and long-press feedback stays compact', (
    tester,
  ) async {
    final backend = _Backend();
    await tester.pumpWidget(_playerApp(backend: backend));
    await tester.pumpAndSettle();

    final drag = await tester.startGesture(const Offset(180, 260));
    await drag.moveBy(const Offset(180, 0));
    await tester.pump();
    final seekFeedback = find.byKey(const Key('video-player-seek-preview'));
    expect(tester.getSize(seekFeedback).width, lessThanOrEqualTo(180));
    await drag.up();
    await tester.pumpAndSettle();

    final hold = await tester.startGesture(const Offset(650, 240));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    final rateFeedback = find.byKey(const Key('video-player-gesture-hud'));
    expect(tester.getSize(rateFeedback).width, lessThanOrEqualTo(180));
    await hold.up();
  });
}

Widget _playerApp({
  required _Backend backend,
  VideoPlayerObserver? observer,
  VideoPlayerController? controller,
  Duration controlsDelay = const Duration(hours: 1),
}) => MaterialApp(
  home: VideoPlayerView(
    contentId: 'show',
    dataSource: const _Source(),
    stateStore: const _Store(),
    controller: controller,
    observer: observer,
    backendFactory: () => backend,
    controlsAutoHideDelay: controlsDelay,
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
  final List<double> systemVolumes = <double>[];

  @override
  void onPlaybackActiveChanged(bool active) => playbackActive.add(active);

  @override
  double onBrightnessReadRequested() => .5;

  @override
  void onBrightnessRequested(double value) => brightness.add(value);

  @override
  double onSystemVolumeReadRequested() => 50;

  @override
  void onSystemVolumeRequested(double value) => systemVolumes.add(value);
}
