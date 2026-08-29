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

final class _FakeAudioDataSource implements AudioPlayerDataSource {
  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async => _playlist();
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

final class _FakeAudioStateStore implements AudioPlaybackStateStore {
  _FakeAudioStateStore({this.initial});

  final AudioPlaybackProgress? initial;
  final List<AudioPlaybackProgress> saved = <AudioPlaybackProgress>[];

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      initial;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {
    saved.add(progress);
  }
}

final class _RecordingObserver extends AudioPlayerObserver {
  int exitCalls = 0;
  AudioPlaybackProgress? exitProgress;

  @override
  Future<void> onExitRequested(AudioPlaybackProgress? progress) async {
    exitCalls++;
    exitProgress = progress;
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
  final StreamController<AudioPlaybackBackendSnapshot> _controller =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 2),
  );

  List<AudioTrack> tracks = const <AudioTrack>[];
  int? openedInitialIndex;
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

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    this.tracks = List<AudioTrack>.of(tracks);
    openedInitialIndex = initialIndex;
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
    await _controller.close();
  }
}
