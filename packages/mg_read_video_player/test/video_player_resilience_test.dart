/// Ordering, lifecycle, first-frame and accessibility regression tests.
///
/// Responsibilities:
/// - Verify backend FIFO ordering and reload/background pause semantics.
/// - Verify per-episode first-frame reset and unbounded system text scaling.
///
/// Notes:
/// - A deterministic fake backend blocks open without native media libraries.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  testWidgets('queues background pause behind a blocked autoplay open', (
    WidgetTester tester,
  ) async {
    final openGate = Completer<void>();
    final backend = _OrderedBackend(openGate: openGate);
    await tester.pumpWidget(_app(backend: backend));
    await tester.pump();
    expect(backend.events, <String>['open:start']);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(backend.events, <String>['open:start']);
    openGate.complete();
    await tester.pumpAndSettle();

    expect(backend.events, containsAllInOrder(<String>['open:end', 'pause']));
    expect(backend.state.value.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('route disposal starts cleanup while open is still blocked', (
    WidgetTester tester,
  ) async {
    final openGate = Completer<void>();
    final backend = _OrderedBackend(openGate: openGate);
    await tester.pumpWidget(_app(backend: backend));
    await tester.pump();
    expect(backend.events, <String>['open:start']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(backend.disposed, isTrue);
    openGate.complete();
    await tester.pump();
  });

  testWidgets('reload pauses and saves old playback before a failed load', (
    WidgetTester tester,
  ) async {
    final backend = _OrderedBackend();
    final store = _Store();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    const playerKey = ValueKey<String>('reload-player');
    await tester.pumpWidget(
      _app(
        backend: backend,
        store: store,
        controller: controller,
        playerKey: playerKey,
      ),
    );
    await tester.pumpAndSettle();
    backend.emitPosition(const Duration(seconds: 27));

    await tester.pumpWidget(
      _app(
        contentId: 'failed',
        backend: backend,
        source: const _FailingSource(),
        store: store,
        controller: controller,
        playerKey: playerKey,
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.events, contains('pause'));
    expect(backend.state.value.playing, isFalse);
    expect(store.saved.last.contentId, 'show');
    expect(store.saved.last.position, const Duration(seconds: 27));
    expect(controller.snapshot.status, VideoPlayerStatus.failure);
  });

  testWidgets('lifecycle pauses even while no episode is selected', (
    WidgetTester tester,
  ) async {
    final backend = _OrderedBackend(initialPlaying: true);
    await tester.pumpWidget(_app(backend: backend, source: _PendingSource()));
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();
    expect(backend.events, contains('pause'));
    expect(backend.state.value.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('requires a new first frame after switching episodes', (
    WidgetTester tester,
  ) async {
    final backend = _OrderedBackend(firstFrameOnOpen: false);
    final observer = _Observer();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(backend: backend, observer: observer, controller: controller),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(controller.snapshot.firstFrameReady, isFalse);
    backend.emitFirstFrame();
    await tester.pump();
    expect(observer.firstFrames, 1);

    await controller.selectEpisode('group-a', 'episode-2');
    await tester.pump();
    expect(controller.snapshot.firstFrameReady, isFalse);
    expect(observer.firstFrames, 1);
    expect(
      find.byKey(const Key('video-player-status-message')),
      findsOneWidget,
    );
    backend.emitFirstFrame();
    await tester.pump();
    expect(observer.firstFrames, 2);
  });

  testWidgets('ignores restored progress owned by another content', (
    WidgetTester tester,
  ) async {
    final backend = _OrderedBackend();
    final store = _Store(
      restored: const VideoPlaybackProgress(
        contentId: 'other-show',
        groupId: 'group-a',
        episodeId: 'episode-2',
        position: Duration(seconds: 55),
        duration: Duration(minutes: 2),
      ),
    );
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(backend: backend, store: store, controller: controller),
    );
    await tester.pumpAndSettle();

    expect(controller.snapshot.activeGroupId, 'group-a');
    expect(controller.snapshot.activeEpisodeId, 'episode-1');
    expect(controller.snapshot.position, Duration.zero);
  });

  testWidgets('rejects content returned for a different identity', (
    WidgetTester tester,
  ) async {
    final backend = _OrderedBackend();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(
        contentId: 'requested-show',
        backend: backend,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.snapshot.status, VideoPlayerStatus.failure);
    expect(controller.snapshot.failure?.code, 'content_identity_mismatch');
    expect(backend.events, isNot(contains('open:start')));
  });

  testWidgets('reports the same backend error again for a new episode', (
    WidgetTester tester,
  ) async {
    final backend = _OrderedBackend();
    final observer = _Observer();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(backend: backend, observer: observer, controller: controller),
    );
    await tester.pumpAndSettle();

    backend.emitError('decoder failed');
    await tester.pump();
    expect(observer.failures, hasLength(1));

    await controller.selectEpisode('group-a', 'episode-2');
    await tester.pumpAndSettle();
    backend.emitError('decoder failed');
    await tester.pump();
    expect(observer.failures, hasLength(2));
  });

  testWidgets('ignores stale ready state before queued episode open', (
    WidgetTester tester,
  ) async {
    final pauseGate = Completer<void>();
    final source = _PendingSource();
    final backend = _OrderedBackend(
      pauseGate: pauseGate,
      initialPlaying: true,
      initialFirstFrame: true,
    );
    final observer = _Observer();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        backend: backend,
        source: source,
        observer: observer,
        controller: controller,
      ),
    );
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(backend.events, contains('pause'));

    source.request.complete(_content());
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(controller.snapshot.activeEpisodeId, 'episode-1');
    expect(backend.events, isNot(contains('open:start')));

    backend.emitPosition(const Duration(seconds: 1));
    await tester.pump();
    expect(observer.firstFrames, 0);

    pauseGate.complete();
    await tester.pumpAndSettle();
    expect(observer.firstFrames, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  testWidgets('narrow large-text chrome and grouped sheet do not overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final backend = _OrderedBackend();
    await tester.pumpWidget(
      _app(backend: backend, source: _Source(_longTitleContent())),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('video-player-episodes')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Widget _app({
  String contentId = 'show',
  required _OrderedBackend backend,
  VideoDataSource? source,
  _Store? store,
  _Observer? observer,
  VideoPlayerController? controller,
  Key? playerKey,
}) => MaterialApp(
  home: VideoPlayerView(
    key: playerKey,
    contentId: contentId,
    dataSource: source ?? _Source(_content()),
    stateStore: store ?? _Store(),
    observer: observer,
    controller: controller,
    backendFactory: () => backend,
    controlsAutoHideDelay: const Duration(hours: 1),
    progressSaveThrottle: const Duration(hours: 1),
  ),
);

VideoContent _content() => VideoContent(
  id: 'show',
  title: '演示视频',
  groups: <VideoEpisodeGroup>[
    VideoEpisodeGroup(
      id: 'group-a',
      title: '第一季',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '第 1 集',
          uri: 'https://example.test/1.mp4',
          durationHint: const Duration(minutes: 2),
        ),
        VideoEpisode(
          id: 'episode-2',
          title: '第 2 集',
          uri: 'https://example.test/2.mp4',
          durationHint: const Duration(minutes: 2),
        ),
      ],
    ),
  ],
);

VideoContent _longTitleContent() => VideoContent(
  id: 'show',
  title: '非常非常长的视频标题用于验证窄窗口与大字体布局',
  groups: <VideoEpisodeGroup>[
    VideoEpisodeGroup(
      id: 'group-a',
      title: '第一季这是一个非常长的通用分组标题',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '这是一个非常非常长的第一集标题用于布局验证',
          uri: 'https://example.test/1.mp4',
        ),
      ],
    ),
    VideoEpisodeGroup(
      id: 'group-b',
      title: '备用线路 B 同样拥有一个非常长的标题',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '备用线路第一集',
          uri: 'https://backup.example.test/1.mp4',
        ),
      ],
    ),
  ],
);

final class _Source implements VideoDataSource {
  const _Source(this.content);

  final VideoContent content;

  @override
  Future<VideoContent> load(String contentId) async => content;
}

final class _FailingSource implements VideoDataSource {
  const _FailingSource();

  @override
  Future<VideoContent> load(String contentId) =>
      Future<VideoContent>.error(StateError('load failed'));
}

final class _PendingSource implements VideoDataSource {
  final Completer<VideoContent> request = Completer<VideoContent>();

  @override
  Future<VideoContent> load(String contentId) => request.future;
}

final class _Store implements VideoPlaybackStateStore {
  _Store({this.restored});

  final VideoPlaybackProgress? restored;
  final List<VideoPlaybackProgress> saved = <VideoPlaybackProgress>[];

  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => restored;

  @override
  Future<void> save(VideoPlaybackProgress progress) async =>
      saved.add(progress);
}

final class _Observer extends VideoPlayerObserver {
  int firstFrames = 0;
  final List<VideoPlayerFailure> failures = <VideoPlayerFailure>[];

  @override
  void onFirstFrame(VideoPlayerSnapshot snapshot) => firstFrames++;

  @override
  void onFailure(VideoPlayerFailure failure) => failures.add(failure);
}

final class _OrderedBackend implements VideoPlaybackBackend {
  _OrderedBackend({
    this.openGate,
    this.pauseGate,
    this.firstFrameOnOpen = true,
    bool initialPlaying = false,
    bool initialFirstFrame = false,
  }) : state = ValueNotifier<VideoPlaybackBackendState>(
         VideoPlaybackBackendState(
           playing: initialPlaying,
           firstFrameReady: initialFirstFrame,
         ),
       );

  final Completer<void>? openGate;
  final Completer<void>? pauseGate;
  final bool firstFrameOnOpen;
  @override
  final ValueNotifier<VideoPlaybackBackendState> state;
  final List<String> events = <String>[];
  bool disposed = false;

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) =>
      ColoredBox(key: key, color: Colors.black);

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) async {
    events.add('open:start');
    state.value = state.value.copyWith(
      buffering: true,
      firstFrameReady: false,
      clearError: true,
    );
    await openGate?.future;
    if (disposed) return;
    events.add('open:end');
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: episode.durationHint ?? const Duration(minutes: 2),
      firstFrameReady: firstFrameOnOpen,
    );
  }

  @override
  Future<void> play() async {
    events.add('play');
    state.value = state.value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    events.add('pause');
    await pauseGate?.future;
    if (disposed) return;
    state.value = state.value.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    events.add('seek');
    state.value = state.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async {
    events.add('rate');
    state.value = state.value.copyWith(rate: rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    events.add('volume');
    state.value = state.value.copyWith(volume: volume);
  }

  void emitPosition(Duration position) =>
      state.value = state.value.copyWith(position: position);

  void emitFirstFrame() =>
      state.value = state.value.copyWith(firstFrameReady: true);

  void emitError(String message) =>
      state.value = state.value.copyWith(errorMessage: message);

  @override
  Future<void> dispose() async {
    disposed = true;
    state.dispose();
  }
}
