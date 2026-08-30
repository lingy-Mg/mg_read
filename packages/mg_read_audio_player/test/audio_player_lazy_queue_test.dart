/// Lazy full-catalog chapter navigation regressions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

void main() {
  testWidgets(
    'full catalog enables adjacent navigation and skips locked chapters',
    (tester) async {
      final backend = _LazyQueueBackend();
      final dataSource = _LazyCatalogAudioDataSource();

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: AudioPlayerView(
              collectionId: 'book',
              dataSource: dataSource,
              stateStore: const _MemoryStateStore(),
              backend: backend,
              autoplay: false,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('第二章 当前章节'), findsOneWidget);
      expect(find.text('第 2 集  ·  共 4 集'), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio-previous')));
      await tester.pumpAndSettle();
      expect(dataSource.loadedTrackIds, <String>['track-1']);
      expect(find.text('第一章 上一章'), findsOneWidget);

      await tester.tap(find.byKey(const Key('audio-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio-next')));
      await tester.pumpAndSettle();

      expect(dataSource.loadedTrackIds, <String>[
        'track-1',
        'track-2',
        'track-4',
      ]);
      expect(find.text('第四章 下一章'), findsOneWidget);
      expect(find.text('第 4 集  ·  共 4 集'), findsOneWidget);
      expect(backend.previousCalls, 0);
      expect(backend.nextCalls, 0);
    },
  );
}

final class _LazyCatalogAudioDataSource
    implements AudioPlaylistQueueDataSource {
  final List<String> loadedTrackIds = <String>[];

  static const _entries = <AudioQueueEntry>[
    AudioQueueEntry(id: 'track-1', title: '第一章 上一章'),
    AudioQueueEntry(id: 'track-2', title: '第二章 当前章节'),
    AudioQueueEntry(id: 'track-3', title: '第三章 已锁定', isLocked: true),
    AudioQueueEntry(id: 'track-4', title: '第四章 下一章'),
  ];

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: collectionId,
        title: '懒加载章节',
        tracks: <AudioTrack>[_track('track-2', '第二章 当前章节')],
        queueEntries: _entries,
      );

  @override
  Future<AudioTrack> loadTrackById(
    String collectionId, {
    required String trackId,
  }) async {
    loadedTrackIds.add(trackId);
    final entry = _entries.singleWhere((candidate) => candidate.id == trackId);
    if (entry.isLocked) throw StateError('Locked tracks must not be loaded.');
    return _track(entry.id, entry.title);
  }

  @override
  Future<List<AudioTrack>> loadFollowingTracks(
    String collectionId, {
    required String afterTrackId,
    required int limit,
  }) async => const <AudioTrack>[];

  static AudioTrack _track(String id, String title) => AudioTrack(
    id: id,
    title: title,
    resource: Uri.parse('https://example.test/audio/$id.mp3'),
  );
}

final class _MemoryStateStore implements AudioPlaybackStateStore {
  const _MemoryStateStore();

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      null;

  @override
  Future<void> saveProgress(AudioPlaybackProgress progress) async {}
}

final class _LazyQueueBackend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _controller =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot(
    duration: Duration(minutes: 2),
  );
  List<AudioTrack> _tracks = const <AudioTrack>[];
  int previousCalls = 0;
  int nextCalls = 0;

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
    _tracks = List<AudioTrack>.of(tracks);
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
    _tracks = <AudioTrack>[..._tracks, ...tracks];
  }

  @override
  Future<void> play() async => _emit(_snapshot.copyWith(playing: true));

  @override
  Future<void> pause() async => _emit(_snapshot.copyWith(playing: false));

  @override
  Future<void> seek(Duration position) async =>
      _emit(_snapshot.copyWith(position: position));

  @override
  Future<void> setRate(double rate) async =>
      _emit(_snapshot.copyWith(rate: rate));

  @override
  Future<void> setVolume(double volume) async =>
      _emit(_snapshot.copyWith(volume: volume));

  @override
  Future<void> previous() async {
    previousCalls++;
  }

  @override
  Future<void> next() async {
    nextCalls++;
  }

  @override
  Future<void> jump(int index) async =>
      _emit(_snapshot.copyWith(currentIndex: index, position: Duration.zero));

  @override
  Future<void> dispose() async => _controller.close();
}
