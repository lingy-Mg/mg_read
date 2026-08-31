/// Lazy resource and stable host-port regression tests.
///
/// Responsibilities:
/// - Resolve only the restored metadata episode before opening the backend.
/// - Keep one session when a first-frame callback rebuilds the parent.
///
/// Notes:
/// - Fakes never initialize MediaKit or native platform libraries.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  testWidgets('resolves only the restored metadata episode for playback', (
    tester,
  ) async {
    final backend = _Backend();
    final source = _LazySource();
    final store = _Store(
      restored: const VideoPlaybackProgress(
        contentId: 'lazy-show',
        groupId: 'route-a',
        episodeId: 'episode-2',
        position: Duration(seconds: 12),
        duration: Duration(minutes: 2),
      ),
    );

    await tester.pumpWidget(
      _app(
        contentId: 'lazy-show',
        backend: backend,
        source: source,
        store: store,
      ),
    );
    await tester.pumpAndSettle();

    expect(source.loadedEpisodes, <String>['route-a/episode-2']);
    expect(backend.opened, hasLength(1));
    expect(backend.opened.single.id, 'episode-2');
    expect(
      backend.opened.single.uri,
      'https://media.example.test/episode-2.m3u8',
    );
  });

  testWidgets('parent first-frame rebuild keeps stable ports and one session', (
    tester,
  ) async {
    final backend = _Backend();
    final source = _CountingSource();
    final store = _Store();
    var parentRebuilds = 0;
    late StateSetter rebuildParent;
    final observer = _Observer(() {
      rebuildParent(() => parentRebuilds++);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuildParent = setState;
            return Column(
              children: <Widget>[
                Text('$parentRebuilds'),
                Expanded(
                  child: VideoPlayerView(
                    contentId: 'show',
                    dataSource: source,
                    stateStore: store,
                    observer: observer,
                    backendFactory: () => backend,
                    controlsAutoHideDelay: const Duration(hours: 1),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(parentRebuilds, 1);
    expect(source.loadCount, 1);
    expect(backend.opened, hasLength(1));
  });
}

Widget _app({
  required String contentId,
  required _Backend backend,
  required VideoDataSource source,
  required _Store store,
}) => MaterialApp(
  home: VideoPlayerView(
    contentId: contentId,
    dataSource: source,
    stateStore: store,
    backendFactory: () => backend,
    controlsAutoHideDelay: const Duration(hours: 1),
  ),
);

VideoContent _content(String contentId) => VideoContent(
  id: contentId,
  title: '测试视频',
  groups: <VideoEpisodeGroup>[
    VideoEpisodeGroup(
      id: 'route-a',
      title: '线路 A',
      episodes: <VideoEpisode>[
        VideoEpisode(
          id: 'episode-1',
          title: '第 1 集',
          uri: 'https://media.example.test/episode-1.m3u8',
        ),
      ],
    ),
  ],
);

final class _CountingSource implements VideoDataSource {
  int loadCount = 0;

  @override
  Future<VideoContent> load(String contentId) async {
    loadCount++;
    return _content(contentId);
  }
}

final class _LazySource implements VideoEpisodeDataSource {
  final List<String> loadedEpisodes = <String>[];

  @override
  Future<VideoContent> load(String contentId) async => VideoContent(
    id: contentId,
    title: '按需视频',
    groups: <VideoEpisodeGroup>[
      VideoEpisodeGroup(
        id: 'route-a',
        title: '线路 A',
        episodes: <VideoEpisode>[
          VideoEpisode(id: 'episode-1', title: '第 1 集'),
          VideoEpisode(id: 'episode-2', title: '第 2 集'),
        ],
      ),
    ],
  );

  @override
  Future<VideoEpisode> loadEpisode(
    String contentId, {
    required String groupId,
    required String episodeId,
  }) async {
    loadedEpisodes.add('$groupId/$episodeId');
    return VideoEpisode(
      id: episodeId,
      title: episodeId == 'episode-1' ? '第 1 集' : '第 2 集',
      uri: 'https://media.example.test/$episodeId.m3u8',
    );
  }
}

final class _Store implements VideoPlaybackStateStore {
  _Store({this.restored});

  final VideoPlaybackProgress? restored;

  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => restored;

  @override
  Future<void> save(VideoPlaybackProgress progress) async {}
}

final class _Observer extends VideoPlayerObserver {
  const _Observer(this.callback);

  final VoidCallback callback;

  @override
  void onFirstFrame(VideoPlayerSnapshot snapshot) => callback();
}

final class _Backend implements VideoPlaybackBackend {
  @override
  final ValueNotifier<VideoPlaybackBackendState> state =
      ValueNotifier<VideoPlaybackBackendState>(
        const VideoPlaybackBackendState(),
      );
  final List<VideoEpisode> opened = <VideoEpisode>[];

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) =>
      ColoredBox(key: key, color: Colors.black);

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) async {
    opened.add(episode);
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: const Duration(minutes: 2),
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
  Future<void> seek(Duration position) async =>
      state.value = state.value.copyWith(position: position);

  @override
  Future<void> setRate(double rate) async =>
      state.value = state.value.copyWith(rate: rate);

  @override
  Future<void> setVolume(double volume) async =>
      state.value = state.value.copyWith(volume: volume);

  @override
  Future<void> dispose() async => state.dispose();
}
