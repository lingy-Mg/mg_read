import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

void main() {
  test(
    'prepares exact episode muted and transfers without reopening',
    () async {
      final backend = _Backend();
      final source = _Source();
      final prepared = VideoPreparedSession(
        backendFactory: () => backend,
        dataSource: source,
        contentId: 'movie',
        groupId: 'g2',
        episodeId: 'e2',
        initialPosition: const Duration(seconds: 42),
      );

      await prepared.prepare();

      expect(prepared.status, VideoPreparationStatus.ready);
      expect(prepared.isReady, isTrue);
      expect(source.loadedEpisode, ('movie', 'g2', 'e2'));
      expect(backend.openCalls, 1);
      expect(backend.openedEpisode?.id, 'e2');
      expect(backend.openedPosition, const Duration(seconds: 42));
      expect(backend.openedPlay, isTrue);
      expect(backend.state.value.volume, 0);
      expect(backend.state.value.firstFrameReady, isTrue);

      final adopted = prepared.takeForAdoption();
      expect(adopted.backend, same(backend));
      expect(adopted.group.id, 'g2');
      expect(adopted.episode.id, 'e2');
      expect(prepared.status, VideoPreparationStatus.adopted);
      expect(backend.openCalls, 1);
      prepared.dispose();
      expect(backend.disposeCalls, 0);
      await backend.dispose();
    },
  );

  test('does not fall back when the requested episode is absent', () async {
    final backend = _Backend();
    final prepared = VideoPreparedSession(
      backendFactory: () => backend,
      dataSource: _Source(),
      contentId: 'movie',
      groupId: 'g2',
      episodeId: 'missing',
      initialPosition: Duration.zero,
    );

    await prepared.prepare();

    expect(prepared.status, VideoPreparationStatus.failed);
    expect(prepared.failure?.code, 'prepared_episode_missing');
    expect(prepared.isReady, isFalse);
    expect(backend.openCalls, 0);
    prepared.dispose();
    expect(backend.disposeCalls, 1);
  });

  testWidgets('adoption reuses backend and skips progress loading', (
    tester,
  ) async {
    final backend = _Backend();
    final source = _Source();
    final store = _Store();
    final controller = VideoPlayerController();
    final prepared = VideoPreparedSession(
      backendFactory: () => backend,
      dataSource: source,
      contentId: 'movie',
      groupId: 'g2',
      episodeId: 'e2',
      initialPosition: const Duration(seconds: 42),
    );
    await prepared.prepare();
    expect(store.loadCalls, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerView(
          contentId: 'movie',
          dataSource: source,
          stateStore: store,
          controller: controller,
          tvMode: true,
          backendFactory: () => fail('adoption must not make a new backend'),
          preparedSession: prepared,
        ),
      ),
    );
    await tester.pump();

    expect(backend.openCalls, 1);
    expect(store.loadCalls, 0);
    expect(prepared.status, VideoPreparationStatus.adopted);
    expect(backend.state.value.volume, 100);
    prepared.dispose();
    expect(backend.disposeCalls, 0);
    var dialogAction = false;
    final focusNode = FocusNode();
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(VideoPlayerView)),
        builder: (context) => AlertDialog(
          actions: [
            TextButton(
              focusNode: focusNode,
              onPressed: () => dialogAction = true,
              child: const Text('Dialog action'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    focusNode.requestFocus();
    await tester.pump();
    await controller.handleRemoteKey(VideoRemoteKey.confirm);
    expect(dialogAction, isTrue);
    await controller.handleRemoteKey(VideoRemoteKey.back);
    await tester.pumpAndSettle();
    expect(find.text('Dialog action'), findsNothing);
    expect(find.byType(VideoPlayerView), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
    focusNode.dispose();
  });
}

final class _Source implements VideoEpisodeDataSource {
  (String, String, String)? loadedEpisode;
  int loadCalls = 0;

  @override
  Future<VideoContent> load(String contentId) async {
    loadCalls++;
    return VideoContent(
      id: contentId,
      title: 'Movie',
      groups: [
        VideoEpisodeGroup(
          id: 'g1',
          title: 'First',
          episodes: [VideoEpisode(id: 'e1', title: 'One', uri: 'https://one')],
        ),
        VideoEpisodeGroup(
          id: 'g2',
          title: 'Second',
          episodes: [VideoEpisode(id: 'e2', title: 'Two')],
        ),
      ],
    );
  }

  @override
  Future<VideoEpisode> loadEpisode(
    String contentId, {
    required String groupId,
    required String episodeId,
  }) async {
    loadedEpisode = (contentId, groupId, episodeId);
    return VideoEpisode(id: episodeId, title: 'Resolved', uri: 'https://two');
  }
}

final class _Store implements VideoPlaybackStateStore {
  int loadCalls = 0;
  int saveCalls = 0;

  @override
  Future<VideoPlaybackProgress?> load(String contentId) async {
    loadCalls++;
    return null;
  }

  @override
  Future<void> save(VideoPlaybackProgress progress) async {
    saveCalls++;
  }
}

final class _Backend implements VideoPlaybackBackend {
  final ValueNotifier<VideoPlaybackBackendState> _state = ValueNotifier(
    const VideoPlaybackBackendState(),
  );
  int openCalls = 0;
  int disposeCalls = 0;
  VideoEpisode? openedEpisode;
  Duration? openedPosition;
  bool? openedPlay;

  @override
  ValueListenable<VideoPlaybackBackendState> get state => _state;

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) => const SizedBox();

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) async {
    openCalls++;
    openedEpisode = episode;
    openedPosition = initialPosition;
    openedPlay = play;
    _state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      volume: _state.value.volume,
      firstFrameReady: true,
    );
  }

  @override
  Future<void> play() async =>
      _state.value = _state.value.copyWith(playing: true);

  @override
  Future<void> pause() async =>
      _state.value = _state.value.copyWith(playing: false);

  @override
  Future<void> seek(Duration position) async =>
      _state.value = _state.value.copyWith(position: position);

  @override
  Future<void> setRate(double rate) async =>
      _state.value = _state.value.copyWith(rate: rate);

  @override
  Future<void> setVolume(double volume) async =>
      _state.value = _state.value.copyWith(volume: volume);

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _state.dispose();
  }
}
