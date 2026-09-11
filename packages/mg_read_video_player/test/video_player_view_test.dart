/// Widget and session tests for the independently maintained video player.
///
/// Responsibilities:
/// - Verify restoration, controls, seeking, switching and lifecycle persistence.
/// - Exercise host fullscreen/exit intents using an injected fake backend.
///
/// Notes:
/// - Tests never initialize MediaKit or require native playback libraries.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  testWidgets('owns transparent system bars while the video session loads', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _playerApp(contentId: 'show', backend: _FakeVideoBackend()),
    );
    await tester.pump();

    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
    );
    expect(region.value.statusBarColor, Colors.transparent);
    expect(region.value.statusBarIconBrightness, Brightness.light);
    expect(region.value.systemNavigationBarColor, Colors.transparent);
    expect(region.value.systemStatusBarContrastEnforced, isFalse);
  });

  testWidgets(
    'loads content and progress together and reports one first frame',
    (WidgetTester tester) async {
      final backend = _FakeVideoBackend();
      final source = _ControlledDataSource();
      final store = _ControlledStore();
      final observer = _RecordingObserver();
      final startupSession = VideoStartupSession('video_startup_test');

      await tester.pumpWidget(
        _playerApp(
          contentId: 'show',
          backend: backend,
          source: source,
          store: store,
          observer: observer,
          startupSession: startupSession,
        ),
      );
      await tester.pump();

      expect(source.loadCount, 1);
      expect(store.loadCount, 1);
      store.complete(null);
      await tester.pump();
      expect(
        observer.startupEvents.map((event) => event.phase),
        contains(VideoStartupPhase.progressReady),
      );
      expect(backend.openCalls, isEmpty);

      source.complete('show');
      await tester.pumpAndSettle();
      expect(observer.firstFrames, 1);
      expect(
        observer.startupEvents.where(
          (event) => event.phase == VideoStartupPhase.firstFrame,
        ),
        hasLength(1),
      );
      expect(
        observer.startupEvents.map((event) => event.sessionId).toSet(),
        <String>{'video_startup_test'},
      );

      await tester.pumpWidget(
        _playerApp(
          contentId: 'show',
          backend: backend,
          source: source,
          store: store,
          observer: observer,
          startupSession: startupSession,
        ),
      );
      await tester.pump();
      expect(source.loadCount, 1);
      expect(observer.firstFrames, 1);
    },
  );

  testWidgets('restores the saved episode and position before autoplay', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final store = _RecordingStore(
      restored: const VideoPlaybackProgress(
        contentId: 'show',
        groupId: 'season-1',
        episodeId: 'episode-2',
        position: Duration(seconds: 42),
        duration: Duration(minutes: 2),
      ),
    );
    final observer = _RecordingObserver();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _playerApp(
        contentId: 'show',
        backend: backend,
        store: store,
        observer: observer,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.openCalls, hasLength(1));
    expect(backend.openCalls.single.episode.id, 'episode-2');
    expect(backend.openCalls.single.position, const Duration(seconds: 42));
    expect(backend.openCalls.single.play, isTrue);
    expect(
      backend.openCalls.single.episode.httpHeaders['Referer'],
      'https://example.test/',
    );
    expect(controller.snapshot.activeEpisodeId, 'episode-2');
    expect(controller.snapshot.activeGroupId, 'season-1');
    expect(controller.snapshot.position, const Duration(seconds: 42));
    expect(observer.firstFrames, 1);
    expect(find.text('演示视频'), findsOneWidget);
  });

  testWidgets('toggles controls and handles Space and arrow shortcuts', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _playerApp(contentId: 'show', backend: backend, controller: controller),
    );
    await tester.pumpAndSettle();

    expect(controller.snapshot.controlsVisible, isTrue);
    await controller.toggleControls();
    await tester.pump();
    expect(controller.snapshot.controlsVisible, isFalse);
    await tester.tap(find.byKey(const Key('video-player-gesture-layer')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.snapshot.controlsVisible, isTrue);

    expect(backend.state.value.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(backend.state.value.playing, isFalse);

    backend.emitPosition(const Duration(seconds: 30));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(backend.seekCalls.last, const Duration(seconds: 40));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(backend.seekCalls.last, const Duration(seconds: 30));
  });

  testWidgets('seeks with chrome and saves before switching episodes', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final store = _RecordingStore();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _playerApp(
        contentId: 'show',
        backend: backend,
        store: store,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    backend.emitPosition(const Duration(seconds: 24));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('video-player-slider')),
      const Offset(90, 0),
    );
    await tester.pump();
    expect(backend.seekCalls.last, greaterThan(const Duration(seconds: 24)));

    backend.emitPosition(const Duration(seconds: 51));
    await tester.tap(find.byKey(const Key('video-player-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const Key('video-player-episode-season-1-episode-2')),
    );
    await tester.pumpAndSettle();

    expect(
      store.saved.any(
        (VideoPlaybackProgress value) =>
            value.groupId == 'season-1' &&
            value.episodeId == 'episode-1' &&
            value.position == const Duration(seconds: 51),
      ),
      isTrue,
    );
    expect(backend.openCalls.last.episode.id, 'episode-2');
    expect(controller.snapshot.activeEpisodeId, 'episode-2');
  });

  testWidgets(
    'episode sheet keeps its glass contrast outside the player theme',
    (WidgetTester tester) async {
      final backend = _FakeVideoBackend();
      await tester.pumpWidget(_playerApp(contentId: 'show', backend: backend));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('video-player-episodes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final selected = tester.widget<ListTile>(
        find.byKey(const Key('video-player-episode-season-1-episode-1')),
      );
      final episodeTitle = tester.widget<Text>(find.text('第 1 集'));
      expect(selected.selectedTileColor, const Color(0x38FFA43A));
      expect(episodeTitle.style?.color, const Color(0xFFF7F7F8));
      expect(
        tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
        Colors.transparent,
      );
    },
  );

  testWidgets(
    'episode sheet uses irregular playback bars and follows pause state',
    (WidgetTester tester) async {
      final backend = _FakeVideoBackend();
      await tester.pumpWidget(_playerApp(contentId: 'show', backend: backend));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('video-player-episodes')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(const Key('video-player-episode-playing-indicator')),
        findsOneWidget,
      );
      final bar = find.byKey(const Key('video-player-episode-playing-bar-0'));
      final barHeights = List<double>.generate(
        5,
        (index) => tester
            .getSize(find.byKey(Key('video-player-episode-playing-bar-$index')))
            .height,
      );
      expect(barHeights.toSet().length, greaterThanOrEqualTo(4));
      final movingHeight = tester.getSize(bar).height;
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.getSize(bar).height, isNot(closeTo(movingHeight, .01)));

      await backend.pause();
      await tester.pump();
      final pausedHeight = tester.getSize(bar).height;
      await tester.pump(const Duration(milliseconds: 160));
      expect(tester.getSize(bar).height, closeTo(pausedHeight, .01));
    },
  );

  testWidgets(
    'background pause and Escape flush progress before one host exit',
    (WidgetTester tester) async {
      final backend = _FakeVideoBackend();
      final store = _RecordingStore();
      final navigatorKey = GlobalKey<NavigatorState>();
      final observer = _RecordingObserver(
        onExit: () => navigatorKey.currentState!.pop(),
      );
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (BuildContext rootContext) => Scaffold(
              key: const Key('video-root-route'),
              body: TextButton(
                key: const Key('open-middle-route'),
                onPressed: () => Navigator.of(rootContext).push<void>(
                  MaterialPageRoute<void>(
                    builder: (BuildContext middleContext) => Scaffold(
                      key: const Key('video-middle-route'),
                      body: TextButton(
                        key: const Key('open-player'),
                        onPressed: () => Navigator.of(middleContext).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => _player(
                              contentId: 'show',
                              backend: backend,
                              store: store,
                              observer: observer,
                              controller: controller,
                            ),
                          ),
                        ),
                        child: const Text('打开视频'),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开中间页'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-middle-route')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-player')));
      await tester.pumpAndSettle();
      backend.emitPosition(const Duration(seconds: 54));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(backend.pauseCount, greaterThan(0));
      expect(store.saved.last.position, const Duration(seconds: 54));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      await controller.requestFullscreen(true);
      expect(observer.fullscreenRequests, <bool>[true]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(observer.fullscreenRequests, <bool>[true, false]);
      expect(observer.exitCount, 0);
      expect(find.byKey(const Key('video-player-surface')), findsOneWidget);

      final pausesBeforeExit = backend.pauseCount;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(backend.pauseCount, greaterThan(pausesBeforeExit));
      expect(observer.exitCount, 1);
      expect(find.byKey(const Key('video-player-surface')), findsNothing);
      expect(find.byKey(const Key('video-middle-route')), findsOneWidget);
      expect(find.byKey(const Key('video-root-route')), findsNothing);
      expect(navigatorKey.currentState!.canPop(), isTrue);
      expect(store.saved.last.position, const Duration(seconds: 54));
      await tester.pumpAndSettle();
      expect(observer.exitCount, 1);
      expect(find.byKey(const Key('video-middle-route')), findsOneWidget);
    },
  );

  testWidgets('system back maybePops one video route without an observer', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            key: const Key('no-observer-root-route'),
            body: TextButton(
              key: const Key('open-no-observer-player'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => VideoPlayerView(
                    contentId: 'show',
                    dataSource: const _ImmediateDataSource(),
                    stateStore: _RecordingStore(),
                    backendFactory: () => backend,
                    controlsAutoHideDelay: const Duration(hours: 1),
                  ),
                ),
              ),
              child: const Text('打开无 Observer 视频'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-no-observer-player')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('video-player-surface')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('video-player-surface')), findsNothing);
    expect(find.byKey(const Key('no-observer-root-route')), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets(
    'system back exits fullscreen first and never bypasses the observer',
    (WidgetTester tester) async {
      final backend = _FakeVideoBackend();
      final observer = _RecordingObserver();
      final controller = VideoPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _playerApp(
          contentId: 'show',
          backend: backend,
          observer: observer,
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      await controller.requestFullscreen(true);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(observer.fullscreenRequests, <bool>[true, false]);
      expect(observer.exitCount, 0);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump();
      expect(observer.exitCount, 1);
    },
  );

  testWidgets('selects a season group before switching its episode', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final store = _RecordingStore();
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _playerApp(
        contentId: 'seasons',
        backend: backend,
        source: _FixedDataSource(_seasonContent()),
        store: store,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('video-player-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('video-player-group-season-2')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('video-player-episode-season-2-episode-1')),
    );
    await tester.pumpAndSettle();

    expect(controller.snapshot.activeGroupId, 'season-2');
    expect(controller.snapshot.activeEpisodeId, 'episode-1');
    expect(backend.openCalls.last.episode.uri, contains('/season-2/'));
    expect(store.saved.last.groupId, 'season-1');
  });

  testWidgets('restores and switches lines sharing one episode identifier', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final store = _RecordingStore(
      restored: const VideoPlaybackProgress(
        contentId: 'routes',
        groupId: 'route-b',
        episodeId: 'episode-1',
        position: Duration(seconds: 18),
        duration: Duration(minutes: 2),
      ),
    );
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _playerApp(
        contentId: 'routes',
        backend: backend,
        source: _FixedDataSource(_routeContent()),
        store: store,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.snapshot.activeGroupId, 'route-b');
    expect(controller.snapshot.activeEpisodeId, 'episode-1');
    expect(backend.openCalls.last.episode.uri, contains('backup.example.test'));
    await controller.selectEpisode('route-a', 'episode-1');
    backend.emitPosition(const Duration(seconds: 33));
    await controller.pause();

    expect(controller.snapshot.activeGroupId, 'route-a');
    expect(
      backend.openCalls.last.episode.uri,
      contains('primary.example.test'),
    );
    expect(store.saved.last.groupId, 'route-a');
    expect(store.saved.last.episodeId, 'episode-1');
  });

  testWidgets('stale content load cannot replace a newer session', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final source = _ControlledDataSource();
    final store = _RecordingStore();

    await tester.pumpWidget(
      _playerApp(
        contentId: 'old',
        backend: backend,
        source: source,
        store: store,
        playerKey: const ValueKey<String>('player'),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      _playerApp(
        contentId: 'new',
        backend: backend,
        source: source,
        store: store,
        playerKey: const ValueKey<String>('player'),
      ),
    );
    await tester.pump();
    source.complete('new');
    await tester.pumpAndSettle();
    source.complete('old');
    await tester.pumpAndSettle();

    expect(backend.openCalls, isNotEmpty);
    expect(backend.openCalls.last.episode.id, 'new-episode-1');
    expect(find.text('new 视频'), findsOneWidget);
  });

  testWidgets('changing content saves the old content position first', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final store = _RecordingStore();
    const playerKey = ValueKey<String>('stable-player');
    await tester.pumpWidget(
      _playerApp(
        contentId: 'old',
        backend: backend,
        store: store,
        playerKey: playerKey,
      ),
    );
    await tester.pumpAndSettle();
    backend.emitPosition(const Duration(seconds: 37));
    await tester.pump();

    await tester.pumpWidget(
      _playerApp(
        contentId: 'new',
        backend: backend,
        store: store,
        playerKey: playerKey,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      store.saved.any(
        (VideoPlaybackProgress value) =>
            value.contentId == 'old' &&
            value.position == const Duration(seconds: 37),
      ),
      isTrue,
    );
    expect(backend.openCalls.last.episode.id, 'new-episode-1');
  });

  testWidgets('dispose serializes final progress after an older delayed save', (
    WidgetTester tester,
  ) async {
    final backend = _FakeVideoBackend();
    final firstSave = Completer<void>();
    final store = _RecordingStore(firstSave: firstSave);
    final controller = VideoPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _playerApp(
        contentId: 'show',
        backend: backend,
        store: store,
        controller: controller,
      ),
    );
    await tester.pumpAndSettle();

    backend.emitPosition(const Duration(seconds: 10));
    unawaited(controller.pause());
    await tester.pump();
    expect(store.saved.first.position, const Duration(seconds: 10));
    backend.emitPosition(const Duration(seconds: 20));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(backend.disposed, isTrue);
    firstSave.complete();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    expect(store.saved.last.position, const Duration(seconds: 20));
  });

  testWidgets('shows a safe host content failure with its location and code', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _playerApp(
        contentId: 'show',
        backend: _FakeVideoBackend(),
        source: const _FailingDataSource(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('所选集的播放资源暂时无法获取，请稍后重试。'), findsOneWidget);
    expect(find.text('发生位置：请求选集播放资源'), findsOneWidget);
    expect(
      find.text('诊断编号：video_episode_resource_load_failed'),
      findsOneWidget,
    );
  });
}

Widget _playerApp({
  required String contentId,
  required _FakeVideoBackend backend,
  VideoDataSource? source,
  VideoPlaybackStateStore? store,
  _RecordingObserver? observer,
  VideoPlayerController? controller,
  Key? playerKey,
  Duration progressSaveThrottle = const Duration(hours: 1),
  VideoStartupSession? startupSession,
}) => MaterialApp(
  home: _player(
    contentId: contentId,
    backend: backend,
    source: source,
    store: store,
    observer: observer,
    controller: controller,
    playerKey: playerKey,
    progressSaveThrottle: progressSaveThrottle,
    startupSession: startupSession,
  ),
);

Widget _player({
  required String contentId,
  required _FakeVideoBackend backend,
  VideoDataSource? source,
  VideoPlaybackStateStore? store,
  _RecordingObserver? observer,
  VideoPlayerController? controller,
  Key? playerKey,
  Duration progressSaveThrottle = const Duration(hours: 1),
  VideoStartupSession? startupSession,
}) => VideoPlayerView(
  key: playerKey,
  contentId: contentId,
  dataSource: source ?? const _ImmediateDataSource(),
  stateStore: store ?? _RecordingStore(),
  observer: observer ?? _RecordingObserver(),
  startupSession: startupSession,
  controller: controller,
  backendFactory: () => backend,
  progressSaveThrottle: progressSaveThrottle,
  controlsAutoHideDelay: const Duration(hours: 1),
);

final class _ImmediateDataSource implements VideoDataSource {
  const _ImmediateDataSource();

  @override
  Future<VideoContent> load(String contentId) async => _content(contentId);
}

final class _FixedDataSource implements VideoDataSource {
  const _FixedDataSource(this.content);

  final VideoContent content;

  @override
  Future<VideoContent> load(String contentId) async => content;
}

final class _FailingDataSource implements VideoDataSource {
  const _FailingDataSource();

  @override
  Future<VideoContent> load(String contentId) => Future<VideoContent>.error(
    const VideoPlayerLoadException(
      code: 'video_episode_resource_load_failed',
      location: '请求选集播放资源',
      message: '所选集的播放资源暂时无法获取，请稍后重试。',
    ),
  );
}

final class _ControlledDataSource implements VideoDataSource {
  final Map<String, Completer<VideoContent>> _requests =
      <String, Completer<VideoContent>>{};
  int loadCount = 0;

  @override
  Future<VideoContent> load(String contentId) {
    loadCount++;
    return (_requests[contentId] ??= Completer<VideoContent>()).future;
  }

  void complete(String contentId) =>
      _requests[contentId]!.complete(_content(contentId));
}

VideoContent _content(String id) => VideoContent(
  id: id,
  title: id == 'show' ? '演示视频' : '$id 视频',
  groups: <VideoEpisodeGroup>[
    VideoEpisodeGroup(
      id: id == 'show' ? 'season-1' : '$id-group',
      title: id == 'show' ? '第一季' : '$id 分组',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: id == 'show' ? 'episode-1' : '$id-episode-1',
          title: '第 1 集',
          uri: 'https://example.test/$id/1.mp4',
          httpHeaders: const <String, String>{
            'Referer': 'https://example.test/',
          },
          durationHint: const Duration(minutes: 2),
        ),
        VideoEpisode(
          id: id == 'show' ? 'episode-2' : '$id-episode-2',
          title: '第 2 集',
          uri: 'https://example.test/$id/2.mp4',
          httpHeaders: const <String, String>{
            'Referer': 'https://example.test/',
          },
          durationHint: const Duration(minutes: 3),
        ),
      ],
    ),
  ],
);

VideoContent _seasonContent() => VideoContent(
  id: 'seasons',
  title: '分季节目',
  groups: <VideoEpisodeGroup>[
    VideoEpisodeGroup(
      id: 'season-1',
      title: '第一季',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '第一季第 1 集',
          uri: 'https://example.test/season-1/1.mp4',
        ),
      ],
    ),
    VideoEpisodeGroup(
      id: 'season-2',
      title: '第二季',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '第二季第 1 集',
          uri: 'https://example.test/season-2/1.mp4',
        ),
      ],
    ),
  ],
);

VideoContent _routeContent() => VideoContent(
  id: 'routes',
  title: '多线路节目',
  groups: <VideoEpisodeGroup>[
    VideoEpisodeGroup(
      id: 'route-a',
      title: '线路 A',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '第 1 集',
          uri: 'https://primary.example.test/1.mp4',
        ),
      ],
    ),
    VideoEpisodeGroup(
      id: 'route-b',
      title: '线路 B',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '第 1 集',
          uri: 'https://backup.example.test/1.mp4',
        ),
      ],
    ),
  ],
);

final class _RecordingStore implements VideoPlaybackStateStore {
  _RecordingStore({this.restored, this.firstSave});

  final VideoPlaybackProgress? restored;
  final Completer<void>? firstSave;
  final List<VideoPlaybackProgress> saved = <VideoPlaybackProgress>[];

  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => restored;

  @override
  Future<void> save(VideoPlaybackProgress progress) {
    saved.add(progress);
    if (saved.length == 1 && firstSave != null) return firstSave!.future;
    return Future<void>.value();
  }
}

final class _RecordingObserver extends VideoPlayerObserver {
  _RecordingObserver({this.onExit});

  final VoidCallback? onExit;
  int firstFrames = 0;
  int exitCount = 0;
  final List<bool> fullscreenRequests = <bool>[];
  final List<VideoPlayerFailure> failures = <VideoPlayerFailure>[];
  final List<VideoStartupEvent> startupEvents = <VideoStartupEvent>[];

  @override
  void onStartupEvent(VideoStartupEvent event) => startupEvents.add(event);

  @override
  void onFirstFrame(VideoPlayerSnapshot snapshot) => firstFrames++;

  @override
  void onFailure(VideoPlayerFailure failure) => failures.add(failure);

  @override
  void onFullscreenRequested(bool fullscreen) =>
      fullscreenRequests.add(fullscreen);

  @override
  void onExitRequested(VideoPlaybackProgress? progress) {
    exitCount++;
    onExit?.call();
  }
}

final class _ControlledStore implements VideoPlaybackStateStore {
  final Completer<VideoPlaybackProgress?> _request =
      Completer<VideoPlaybackProgress?>();
  int loadCount = 0;

  @override
  Future<VideoPlaybackProgress?> load(String contentId) {
    loadCount++;
    return _request.future;
  }

  void complete(VideoPlaybackProgress? progress) => _request.complete(progress);

  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}

final class _OpenCall {
  const _OpenCall(this.episode, this.position, this.play);

  final VideoEpisode episode;
  final Duration position;
  final bool play;
}

final class _FakeVideoBackend implements VideoPlaybackBackend {
  @override
  final ValueNotifier<VideoPlaybackBackendState> state =
      ValueNotifier<VideoPlaybackBackendState>(
        const VideoPlaybackBackendState(),
      );
  final List<_OpenCall> openCalls = <_OpenCall>[];
  final List<Duration> seekCalls = <Duration>[];
  int pauseCount = 0;
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
    openCalls.add(_OpenCall(episode, initialPosition, play));
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: episode.durationHint ?? const Duration(minutes: 2),
      firstFrameReady: true,
    );
  }

  @override
  Future<void> play() async =>
      state.value = state.value.copyWith(playing: true);

  @override
  Future<void> pause() async {
    pauseCount++;
    state.value = state.value.copyWith(playing: false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    state.value = state.value.copyWith(position: position);
  }

  @override
  Future<void> setRate(double rate) async =>
      state.value = state.value.copyWith(rate: rate);

  @override
  Future<void> setVolume(double volume) async =>
      state.value = state.value.copyWith(volume: volume);

  void emitPosition(Duration position) =>
      state.value = state.value.copyWith(position: position);

  @override
  Future<void> dispose() async {
    disposed = true;
    state.dispose();
  }
}
