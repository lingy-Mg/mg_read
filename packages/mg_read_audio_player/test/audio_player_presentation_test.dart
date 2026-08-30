/// Portrait presentation, settings, queue and golden tests for the audio UI.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  testWidgets('shows a dedicated empty queue recovery state', (tester) async {
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _EmptyDataSource(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('暂无可播放内容'), findsOneWidget);
    expect(find.text('当前内容暂无可播放章节。'), findsOneWidget);
    expect(find.byKey(const Key('audio-retry')), findsOneWidget);
  });

  testWidgets('settings sheet controls rate volume mute and sleep timer', (
    tester,
  ) async {
    final backend = _PresentationBackend();
    final controller = AudioPlayerController();

    await tester.pumpWidget(_host(backend: backend, controller: controller));
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.byKey(const Key('audio-settings')));
    await tester.tap(find.byKey(const Key('audio-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-rate')), findsOneWidget);
    expect(find.byKey(const Key('audio-volume')), findsOneWidget);
    expect(find.byKey(const Key('audio-timer')), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-rate-175')));
    await tester.pump();
    expect(backend.rates.last, 1.75);

    await tester.drag(
      find.byKey(const Key('audio-volume-slider')),
      const Offset(-90, 0),
    );
    await tester.pump();
    expect(backend.volumes.last, lessThan(1));
    expect(backend.volumes.last, greaterThan(0));

    await tester.tap(find.byKey(const Key('audio-volume-mute')));
    await tester.pump();
    expect(backend.volumes.last, 0);

    await tester.tap(find.byKey(const Key('audio-timer-45')));
    await tester.pump();
    expect(controller.snapshot.sleepTimerDuration, const Duration(minutes: 45));
    await tester.tap(find.byKey(const Key('audio-timer-off')));
    await tester.pump();
    expect(controller.snapshot.sleepTimerDuration, isNull);

    controller.dispose();
  });

  testWidgets('queue sheet highlights current and protects locked chapters', (
    tester,
  ) async {
    final backend = _PresentationBackend();

    await tester.pumpWidget(
      _host(backend: backend, dataSource: const _QueueDataSource()),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-queue-list')), findsOneWidget);
    expect(find.text('正在播放'), findsAtLeastNWidgets(2));
    expect(find.text('需解锁后播放'), findsOneWidget);

    await tester.tap(find.byKey(const Key('audio-queue-track-locked')));
    await tester.pump();
    expect(find.byKey(const Key('audio-queue-list')), findsOneWidget);
    expect(backend.snapshot.currentIndex, 0);

    await tester.tap(find.byKey(const Key('audio-queue-track-track-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio-queue-list')), findsNothing);
    expect(backend.snapshot.currentIndex, 1);
  });

  testWidgets(
    'large catalog uses a subtle indicator instead of a giant badge',
    (tester) async {
      await tester.pumpWidget(
        _host(
          backend: _PresentationBackend(),
          dataSource: const _LargeQueueDataSource(),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('audio-queue-indicator')), findsOneWidget);
      expect(find.text('999+'), findsNothing);
      expect(find.text('第 1 集  ·  共 2008 集'), findsOneWidget);
    },
  );

  testWidgets('host artwork is reused by the eased blurred backdrop', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        artworkBuilder: (_, _) => const ColoredBox(
          key: Key('presentation-artwork'),
          color: Color(0xFF8A4B36),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final backdrop = find.byKey(const Key('audio-artwork-backdrop'));
    expect(backdrop, findsOneWidget);
    expect(
      find.descendant(of: backdrop, matching: find.byType(ImageFiltered)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('presentation-artwork')), findsNWidgets(2));
  });

  testWidgets('short portrait keeps the complete control area on first view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _LargeQueueDataSource(),
        size: const Size(400, 700),
        textScale: 1,
      ),
    );
    await tester.pump();
    await tester.pump();

    final settings = find.byKey(const Key('audio-settings'));
    expect(settings, findsOneWidget);
    expect(tester.getBottomRight(settings).dy, lessThanOrEqualTo(700));
    expect(find.byType(Scrollbar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact portrait and large text remain overflow free', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _LongLabelDataSource(),
        size: const Size(360, 640),
        textScale: 1.35,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('audio-play-pause')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready player matches the portrait visual baseline', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(backend: _PresentationBackend(), textScale: 1),
    );
    await tester.pump();
    await tester.pump();

    await expectLater(
      find.byType(AudioPlayerView),
      matchesGoldenFile('goldens/audio_player_ready_390x844.png'),
    );
  });

  testWidgets('settings and queue match portrait visual baselines', (
    tester,
  ) async {
    _setPortraitView(tester);
    await tester.pumpWidget(
      _host(
        backend: _PresentationBackend(),
        dataSource: const _QueueDataSource(),
        textScale: 1,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('audio-settings')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/audio_player_settings_390x844.png'),
    );

    await tester.tap(find.byKey(const Key('audio-settings-close')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('audio-queue')));
    await tester.tap(find.byKey(const Key('audio-queue')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(Overlay),
      matchesGoldenFile('goldens/audio_player_queue_390x844.png'),
    );
  });
}

void _setPortraitView(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _host({
  required _PresentationBackend backend,
  AudioPlayerDataSource dataSource = const _PresentationDataSource(),
  AudioPlayerController? controller,
  AudioArtworkBuilder? artworkBuilder,
  Size size = const Size(390, 844),
  double textScale = 1.15,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.light(useMaterial3: true),
    home: MediaQuery(
      data: const MediaQueryData(
        disableAnimations: true,
      ).copyWith(size: size, textScaler: TextScaler.linear(textScale)),
      child: AudioPlayerView(
        collectionId: 'book',
        dataSource: dataSource,
        stateStore: const _PresentationStateStore(),
        observer: const AudioPlayerObserver(),
        controller: controller,
        backend: backend,
        artworkBuilder: artworkBuilder,
        autoplay: false,
        saveInterval: const Duration(hours: 1),
      ),
    ),
  );
}

AudioPlaylist _presentationPlaylist() => AudioPlaylist(
  collectionId: 'book',
  title: '风声书场',
  creator: '讲述者',
  tracks: <AudioTrack>[
    AudioTrack(
      id: 'track-1',
      title: '第一章 从这里开始',
      collectionTitle: '风声书场',
      creator: '讲述者',
      resource: Uri.parse('https://example.test/audio/1.mp3'),
    ),
    AudioTrack(
      id: 'track-2',
      title: '第二章 风经过窗口',
      collectionTitle: '风声书场',
      creator: '讲述者',
      resource: Uri.parse('https://example.test/audio/2.mp3'),
    ),
  ],
);

final class _PresentationDataSource implements AudioPlayerDataSource {
  const _PresentationDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      _presentationPlaylist();
}

final class _EmptyDataSource implements AudioPlayerDataSource {
  const _EmptyDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(collectionId: collectionId, title: '空队列', tracks: []);
}

final class _QueueDataSource implements AudioPlayerDataSource {
  const _QueueDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final playlist = _presentationPlaylist();
    return AudioPlaylist(
      collectionId: playlist.collectionId,
      title: playlist.title,
      creator: playlist.creator,
      tracks: playlist.tracks,
      queueEntries: const <AudioQueueEntry>[
        AudioQueueEntry(id: 'track-1', title: '第一章 从这里开始', creator: '讲述者'),
        AudioQueueEntry(id: 'track-2', title: '第二章 风经过窗口', creator: '讲述者'),
        AudioQueueEntry(id: 'locked', title: '第三章 尚未解锁', isLocked: true),
      ],
    );
  }
}

final class _LargeQueueDataSource implements AudioPlayerDataSource {
  const _LargeQueueDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async {
    final playlist = _presentationPlaylist();
    return AudioPlaylist(
      collectionId: playlist.collectionId,
      title: playlist.title,
      creator: playlist.creator,
      tracks: playlist.tracks,
      queueEntries: List<AudioQueueEntry>.generate(
        2008,
        (index) => AudioQueueEntry(
          id: index < playlist.tracks.length
              ? playlist.tracks[index].id
              : 'locked-$index',
          title: '第 ${index + 1} 集',
          creator: '讲述者',
          isLocked: index >= playlist.tracks.length,
        ),
        growable: false,
      ),
    );
  }
}

final class _LongLabelDataSource implements AudioPlayerDataSource {
  const _LongLabelDataSource();

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: 'book',
        title: '这是一段用于验证紧凑手机顶栏截断行为的超长有声书合集名称',
        creator: '一位拥有很长展示名称的专业有声书讲述者',
        tracks: <AudioTrack>[
          AudioTrack(
            id: 'track-long',
            title: '第三十章 这是一段用于验证两行截断与大字号适配行为的超长章节标题',
            collectionTitle: '这是一段用于验证紧凑手机顶栏截断行为的超长有声书合集名称',
            creator: '一位拥有很长展示名称的专业有声书讲述者',
            resource: Uri.parse('https://example.test/audio/long.mp3'),
          ),
        ],
      );
}

final class _PresentationStateStore implements AudioPlaybackStateStore {
  const _PresentationStateStore();

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      null;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {}
}

final class _PresentationBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _controller =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 2),
  );
  List<AudioTrack> tracks = const <AudioTrack>[];
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

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    this.tracks = List<AudioTrack>.of(tracks);
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
    this.tracks = <AudioTrack>[...this.tracks, ...tracks];
  }

  @override
  Future<void> play() async => _emit(_snapshot.copyWith(playing: true));

  @override
  Future<void> pause() async => _emit(_snapshot.copyWith(playing: false));

  @override
  Future<void> seek(Duration position) async =>
      _emit(_snapshot.copyWith(position: position));

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
  Future<void> previous() =>
      jump((_snapshot.currentIndex - 1).clamp(0, tracks.length - 1));

  @override
  Future<void> next() =>
      jump((_snapshot.currentIndex + 1).clamp(0, tracks.length - 1));

  @override
  Future<void> jump(int index) async =>
      _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));

  @override
  Future<void> dispose() => _controller.close();
}
