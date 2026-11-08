/// Shared artwork, playlist and fake transport fixtures for real-player UI tests.
/// No network, native audio or durable host state is created.
part of '../audio_player_presentation_test.dart';

Widget _goldenArtworkBuilder(BuildContext context, AudioTrack track) {
  return const CustomPaint(painter: _GoldenArtworkPainter());
}

class _GoldenArtworkPainter extends CustomPainter {
  const _GoldenArtworkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF7A3F2A), Color(0xFF17212E)],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      Offset(size.width * 0.14, size.height * 0.18),
      size.shortestSide * 0.27,
      Paint()..color = const Color(0xFFE99B61),
    );
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.42),
      size.shortestSide * 0.32,
      Paint()..color = const Color(0xFF6687A7),
    );
    canvas.drawRect(
      Rect.fromLTWH(
        size.width * 0.22,
        size.height * 0.68,
        size.width * 0.62,
        size.height * 0.18,
      ),
      Paint()..color = const Color(0xFFA95838),
    );
  }

  @override
  bool shouldRepaint(_GoldenArtworkPainter oldDelegate) => false;
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
  AudioResourceUrlDecoder? resourceUrlDecoder,
  Size size = const Size(390, 844),
  double textScale = 1.15,
  bool disableAnimations = true,
  EdgeInsets safePadding = EdgeInsets.zero,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.light(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: const MediaQueryData().copyWith(
        size: size,
        padding: safePadding,
        textScaler: TextScaler.linear(textScale),
        disableAnimations: disableAnimations,
      ),
      child: child!,
    ),
    home: AudioPlayerView(
      collectionId: 'book',
      dataSource: dataSource,
      stateStore: const _PresentationStateStore(),
      observer: const AudioPlayerObserver(),
      controller: controller,
      backend: backend,
      artworkBuilder: artworkBuilder,
      resourceUrlDecoder: resourceUrlDecoder,
      autoplay: false,
      saveInterval: const Duration(hours: 1),
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
      sourceUrl: Uri.parse(
        'https://example.test/books/book-1/chapters/chapter-1',
      ),
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
