/// Widget and session regression tests using an injectible fake transport.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  testWidgets('restores the saved track and position before becoming ready', (
    tester,
  ) async {
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore(
      initial: AudioPlaybackProgress(
        collectionId: 'book',
        trackId: 'track-2',
        position: const Duration(seconds: 42),
        updatedAt: DateTime.utc(2026),
      ),
    );

    await tester.pumpWidget(
      _testHost(
        backend: backend,
        store: store,
        observer: const AudioPlayerObserver(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(backend.openedInitialIndex, 1);
    expect(backend.seeks, contains(const Duration(seconds: 42)));
    expect(find.text('第二章 风经过窗口'), findsOneWidget);
    expect(find.byKey(const Key('audio-play-pause')), findsOneWidget);
  });

  testWidgets('ignores progress owned by another collection', (tester) async {
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore(
      initial: AudioPlaybackProgress(
        collectionId: 'another-book',
        trackId: 'track-2',
        position: const Duration(seconds: 42),
        updatedAt: DateTime.utc(2026),
      ),
    );

    await tester.pumpWidget(
      _testHost(
        backend: backend,
        store: store,
        observer: const AudioPlayerObserver(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(backend.openedInitialIndex, 0);
    expect(backend.seeks, isEmpty);
    expect(find.text('第一章 从这里开始'), findsOneWidget);
  });

  testWidgets('shows a host-safe failure location and diagnostic code', (
    tester,
  ) async {
    await tester.pumpWidget(
      _testHost(
        backend: _FakeAudioBackend(),
        store: _FakeAudioStateStore(),
        dataSource: const _FailingAudioDataSource(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('数据源未返回播放地址。'), findsOneWidget);
    expect(find.text('发生位置：所选章节的播放地址'), findsOneWidget);
    expect(find.text('诊断编号：audio_selected_resource_unavailable'), findsOneWidget);
  });

  testWidgets('controls transport and saves before switching tracks', (
    tester,
  ) async {
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore();

    await tester.pumpWidget(
      _testHost(
        backend: backend,
        store: store,
        observer: const AudioPlayerObserver(),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-play-pause')));
    await tester.pump();
    expect(backend.playCalls, 1);

    backend.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-seek-forward')));
    await tester.pump();
    expect(backend.seeks.last, const Duration(seconds: 35));

    await tester.tap(find.byKey(const Key('audio-rate')));
    await tester.pump();
    expect(backend.rates.last, 1.25);

    backend.emitPosition(const Duration(seconds: 37));
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-next')));
    await tester.pump();
    await tester.pump();

    expect(store.saved, isNotEmpty);
    expect(
      store.saved.any((progress) => progress.trackId == 'track-1'),
      isTrue,
    );
    expect(backend.nextCalls, 1);
    expect(find.text('第二章 风经过窗口'), findsOneWidget);
  });

  testWidgets('sleep timer pauses and exit flushes the latest position', (
    tester,
  ) async {
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore();
    final observer = _RecordingObserver();
    final controller = AudioPlayerController();

    await tester.pumpWidget(
      _testHost(
        backend: backend,
        store: store,
        observer: observer,
        controller: controller,
      ),
    );
    await tester.pump();
    await tester.pump();

    await controller.play();
    await controller.setSleepTimer(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 21));
    await tester.pump();
    expect(backend.pauseCalls, 1);

    backend.emitPosition(const Duration(seconds: 33));
    await tester.pump();
    await tester.tap(find.byKey(const Key('audio-back')));
    await tester.pump();
    await tester.pump();

    expect(observer.exitProgress?.trackId, 'track-1');
    expect(observer.exitProgress?.position, const Duration(seconds: 33));
    expect(store.saved.last.position, const Duration(seconds: 33));

    controller.dispose();
  });

  testWidgets('a stale first load cannot overwrite a retry result', (
    tester,
  ) async {
    final firstLoad = Completer<AudioPlaylist>();
    final dataSource = _SequencedDataSource(firstLoad);
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore();
    final controller = AudioPlayerController();

    await tester.pumpWidget(
      _testHost(
        backend: backend,
        store: store,
        observer: const AudioPlayerObserver(),
        controller: controller,
        dataSource: dataSource,
      ),
    );
    await tester.pump();

    await controller.retry();
    await tester.pump();
    await tester.pump();
    expect(find.text('重试后的队列'), findsOneWidget);

    firstLoad.complete(_playlist(title: '过期队列'));
    await tester.pump();
    await tester.pump();
    expect(find.text('重试后的队列'), findsOneWidget);
    expect(find.text('过期队列'), findsNothing);

    controller.dispose();
  });

  testWidgets(
    'blocked backend initialization stays loading and latest retry wins',
    (tester) async {
      final firstOpen = Completer<void>();
      final secondOpen = Completer<void>();
      final backend = _FakeAudioBackend(
        openGates: <Completer<void>>[firstOpen, secondOpen],
      );
      final store = _FakeAudioStateStore(
        initial: AudioPlaybackProgress(
          collectionId: 'book',
          trackId: 'track-2',
          position: const Duration(seconds: 9),
          updatedAt: DateTime.utc(2026),
        ),
      );
      final controller = AudioPlayerController();
      final dataSource = _ImmediateSequencedDataSource(<AudioPlaylist>[
        _singleTrackPlaylist(title: '旧 open 队列'),
        _playlist(title: '最终队列'),
      ]);

      await tester.pumpWidget(
        _testHost(
          backend: backend,
          store: store,
          observer: const AudioPlayerObserver(),
          controller: controller,
          dataSource: dataSource,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(backend.openCalls, 1);
      expect(controller.snapshot.status, AudioPlayerStatus.loading);
      await controller.play();
      expect(backend.playCalls, 0);

      unawaited(controller.retry());
      await tester.pump();
      await tester.pump();
      expect(dataSource.calls, 2);
      expect(backend.openCalls, 1);
      expect(controller.snapshot.status, AudioPlayerStatus.loading);

      firstOpen.complete();
      await tester.pump();
      await tester.pump();
      expect(backend.openCalls, 2);
      expect(controller.snapshot.status, AudioPlayerStatus.loading);

      secondOpen.complete();
      await tester.pumpAndSettle();
      expect(controller.snapshot.status, AudioPlayerStatus.ready);
      expect(controller.snapshot.collectionTitle, '最终队列');
      expect(controller.snapshot.currentTrack?.id, 'track-2');
      expect(backend.seeks, contains(const Duration(seconds: 9)));

      controller.dispose();
    },
  );

  testWidgets('repeated snapshots report one backend failure until cleared', (
    tester,
  ) async {
    final backend = _FakeAudioBackend();
    final observer = _RecordingObserver();

    await tester.pumpWidget(
      _testHost(
        backend: backend,
        store: _FakeAudioStateStore(),
        observer: observer,
      ),
    );
    await tester.pump();
    await tester.pump();

    backend.emitError('decoder failed');
    backend.emitPosition(const Duration(seconds: 1));
    backend.emitPosition(const Duration(seconds: 2));
    await tester.pump();
    expect(observer.failureCalls, 1);

    backend.clearError();
    backend.emitError('decoder failed');
    await tester.pump();
    expect(observer.failureCalls, 2);
  });

  testWidgets('system back is intercepted and flushes through exit observer', (
    tester,
  ) async {
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore();
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = _PoppingObserver(navigatorKey);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('宿主页'))),
      ),
    );
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AudioPlayerView(
          collectionId: 'book',
          dataSource: _FakeAudioDataSource(),
          stateStore: store,
          observer: observer,
          backend: backend,
          saveInterval: const Duration(hours: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();

    backend.emitPosition(const Duration(seconds: 51));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AudioPlayerView), findsNothing);
    expect(find.text('宿主页'), findsOneWidget);
    expect(observer.exitCalls, 1);
    expect(observer.exitProgress?.position, const Duration(seconds: 51));
    expect(store.saved.last.position, const Duration(seconds: 51));
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('external removal during a slow flush cannot double-pop', (
    tester,
  ) async {
    final saveGate = Completer<void>();
    final store = _FakeAudioStateStore(saveGate: saveGate);
    final backend = _FakeAudioBackend();
    final navigatorKey = GlobalKey<NavigatorState>();
    final observer = _PoppingObserver(navigatorKey);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('底层页面'))),
      ),
    );
    final hostRoute = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Center(child: Text('宿主页'))),
    );
    navigatorKey.currentState!.push<void>(hostRoute);
    await tester.pumpAndSettle();
    final playerRoute = MaterialPageRoute<void>(
      builder: (_) => AudioPlayerView(
        collectionId: 'book',
        dataSource: _FakeAudioDataSource(),
        stateStore: store,
        observer: observer,
        backend: backend,
        saveInterval: const Duration(hours: 1),
      ),
    );
    navigatorKey.currentState!.push<void>(playerRoute);
    await tester.pumpAndSettle();

    backend.emitPosition(const Duration(seconds: 18));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(store.saved, isNotEmpty);

    navigatorKey.currentState!.removeRoute(playerRoute);
    await tester.pump();
    saveGate.complete();
    await tester.pumpAndSettle();

    expect(observer.exitCalls, 0);
    expect(find.byType(AudioPlayerView), findsNothing);
    expect(find.text('宿主页'), findsOneWidget);
    expect(find.text('底层页面'), findsNothing);
    expect(navigatorKey.currentState!.canPop(), isTrue);
  });

  testWidgets(
    'route teardown releases transport before the final save completes',
    (tester) async {
      final saveGate = Completer<void>();
      final store = _FakeAudioStateStore(saveGate: saveGate);
      final backend = _FakeAudioBackend();
      final controller = AudioPlayerController();
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Center(child: Text('资源宿主页'))),
        ),
      );
      final playerRoute = MaterialPageRoute<void>(
        builder: (_) => AudioPlayerView(
          collectionId: 'book',
          dataSource: _FakeAudioDataSource(),
          stateStore: store,
          controller: controller,
          backend: backend,
          saveInterval: const Duration(hours: 1),
        ),
      );
      navigatorKey.currentState!.push<void>(playerRoute);
      await tester.pumpAndSettle();

      backend.emitPosition(const Duration(seconds: 10));
      await tester.pump();
      unawaited(controller.pause());
      await tester.pump();
      expect(store.saved.map((item) => item.position), <Duration>[
        const Duration(seconds: 10),
      ]);

      backend.emitPosition(const Duration(seconds: 20));
      await tester.pump();
      navigatorKey.currentState!.removeRoute(playerRoute);
      await tester.pump();

      expect(controller.isAttached, isFalse);
      expect(backend.disposeCalls, 1);
      expect(store.saved.map((item) => item.position), <Duration>[
        const Duration(seconds: 10),
      ]);

      saveGate.complete();
      await tester.pumpAndSettle();
      expect(store.saved.map((item) => item.position), <Duration>[
        const Duration(seconds: 10),
        const Duration(seconds: 20),
      ]);

      controller.dispose();
    },
  );

  testWidgets('exit can be requested again when the host keeps the route', (
    tester,
  ) async {
    final backend = _FakeAudioBackend();
    final store = _FakeAudioStateStore();
    final observer = _RecordingObserver();

    await tester.pumpWidget(
      _testHost(backend: backend, store: store, observer: observer),
    );
    await tester.pump();
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AudioPlayerView), findsOneWidget);
    expect(observer.exitCalls, 2);
  });

  testWidgets('system back pops one route when no observer is supplied', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final backend = _FakeAudioBackend();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Center(child: Text('默认宿主页'))),
      ),
    );
    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => AudioPlayerView(
          collectionId: 'book',
          dataSource: _FakeAudioDataSource(),
          stateStore: _FakeAudioStateStore(),
          backend: backend,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(AudioPlayerView), findsNothing);
    expect(find.text('默认宿主页'), findsOneWidget);
    expect(navigatorKey.currentState!.canPop(), isFalse);
  });
}

Widget _testHost({
  required _FakeAudioBackend backend,
  required _FakeAudioStateStore store,
  required AudioPlayerObserver observer,
  AudioPlayerController? controller,
  AudioPlayerDataSource? dataSource,
}) {
  return MaterialApp(
    theme: ThemeData.light(useMaterial3: true),
    home: MediaQuery(
      data: const MediaQueryData(
        size: Size(390, 844),
        textScaler: TextScaler.linear(1.15),
        disableAnimations: true,
      ),
      child: AudioPlayerView(
        collectionId: 'book',
        dataSource: dataSource ?? _FakeAudioDataSource(),
        stateStore: store,
        observer: observer,
        controller: controller,
        backend: backend,
        saveInterval: const Duration(hours: 1),
      ),
    ),
  );
}

AudioPlaylist _playlist({String title = '风声书场'}) => AudioPlaylist(
  collectionId: 'book',
  title: title,
  creator: '讲述者',
  tracks: <AudioTrack>[
    AudioTrack(
      id: 'track-1',
      title: '第一章 从这里开始',
      collectionTitle: title,
      creator: '讲述者',
      resource: Uri.parse('https://example.test/audio/1.mp3'),
      httpHeaders: const <String, String>{'Authorization': 'test'},
    ),
    AudioTrack(
      id: 'track-2',
      title: '第二章 风经过窗口',
      collectionTitle: title,
      creator: '讲述者',
      resource: Uri.parse('https://example.test/audio/2.mp3'),
    ),
  ],
);

AudioPlaylist _singleTrackPlaylist({required String title}) => AudioPlaylist(
  collectionId: 'book',
  title: title,
  tracks: <AudioTrack>[
    AudioTrack(
      id: 'track-1',
      title: '旧队列曲目',
      resource: Uri.parse('https://example.test/audio/old.mp3'),
    ),
  ],
);

final class _FakeAudioDataSource implements AudioPlayerDataSource {
  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async => _playlist();
}

final class _FailingAudioDataSource implements AudioPlayerDataSource {
  const _FailingAudioDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) =>
      throw const AudioPlayerLoadException(
        code: 'audio_selected_resource_unavailable',
        location: '所选章节的播放地址',
        message: '数据源未返回播放地址。',
      );
}

final class _SequencedDataSource implements AudioPlayerDataSource {
  _SequencedDataSource(this.firstLoad);

  final Completer<AudioPlaylist> firstLoad;
  int calls = 0;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) {
    calls++;
    if (calls == 1) return firstLoad.future;
    return Future<AudioPlaylist>.value(_playlist(title: '重试后的队列'));
  }
}

final class _ImmediateSequencedDataSource implements AudioPlayerDataSource {
  _ImmediateSequencedDataSource(this.playlists);

  final List<AudioPlaylist> playlists;
  int calls = 0;

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final index = calls.clamp(0, playlists.length - 1);
    calls++;
    return playlists[index];
  }
}

final class _FakeAudioStateStore implements AudioPlaybackStateStore {
  _FakeAudioStateStore({this.initial, this.saveGate});

  final AudioPlaybackProgress? initial;
  final Completer<void>? saveGate;
  final List<AudioPlaybackProgress> saved = <AudioPlaybackProgress>[];

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      initial;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {
    saved.add(progress);
    await saveGate?.future;
  }
}

final class _RecordingObserver extends AudioPlayerObserver {
  int exitCalls = 0;
  int failureCalls = 0;
  AudioPlaybackProgress? exitProgress;

  @override
  Future<void> onExitRequested(AudioPlaybackProgress? progress) async {
    exitCalls++;
    exitProgress = progress;
  }

  @override
  Future<void> onFailure(AudioPlayerFailure failure) async {
    failureCalls++;
  }
}

final class _PoppingObserver extends AudioPlayerObserver {
  _PoppingObserver(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;
  int exitCalls = 0;
  AudioPlaybackProgress? exitProgress;

  @override
  Future<void> onExitRequested(AudioPlaybackProgress? progress) async {
    exitCalls++;
    exitProgress = progress;
    final navigator = navigatorKey.currentState;
    if (navigator != null && navigator.canPop()) navigator.pop();
  }
}

final class _FakeAudioBackend implements AudioPlaybackBackend {
  _FakeAudioBackend({
    List<Completer<void>> openGates = const <Completer<void>>[],
  }) : _openGates = List<Completer<void>>.of(openGates);

  final List<Completer<void>> _openGates;
  final StreamController<AudioPlaybackBackendSnapshot> _controller =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 2),
  );

  List<AudioTrack> tracks = const <AudioTrack>[];
  int? openedInitialIndex;
  int openCalls = 0;
  int disposeCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;
  final List<Duration> seeks = <Duration>[];
  final List<double> rates = <double>[];
  final List<double> volumes = <double>[];

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _controller.stream;

  void _emit(AudioPlaybackBackendSnapshot value) {
    _snapshot = value;
    _controller.add(value);
  }

  void emitPosition(Duration position) {
    _emit(_snapshot.copyWith(position: position));
  }

  void emitError(String message) {
    _emit(_snapshot.copyWith(errorMessage: message));
  }

  void clearError() {
    _emit(_snapshot.copyWith(clearError: true));
  }

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    final callIndex = openCalls;
    openCalls++;
    this.tracks = List<AudioTrack>.of(tracks);
    openedInitialIndex = initialIndex;
    _emit(
      AudioPlaybackBackendSnapshot(
        currentIndex: initialIndex,
        duration: const Duration(minutes: 2),
        playing: play,
        buffering: true,
      ),
    );
    if (callIndex < _openGates.length) {
      await _openGates[callIndex].future;
    }
    _emit(
      AudioPlaybackBackendSnapshot(
        currentIndex: initialIndex,
        duration: const Duration(minutes: 2),
        playing: play,
      ),
    );
  }

  @override
  Future<void> play() async {
    playCalls++;
    _emit(_snapshot.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _emit(_snapshot.copyWith(playing: false));
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _emit(_snapshot.copyWith(position: position));
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    _emit(_snapshot.copyWith(rate: rate));
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    _emit(_snapshot.copyWith(volume: volume));
  }

  @override
  Future<void> previous() async {
    previousCalls++;
    final index = (_snapshot.currentIndex - 1).clamp(0, tracks.length - 1);
    _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));
  }

  @override
  Future<void> next() async {
    nextCalls++;
    final index = (_snapshot.currentIndex + 1).clamp(0, tracks.length - 1);
    _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));
  }

  @override
  Future<void> jump(int index) async {
    _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _controller.close();
  }
}
