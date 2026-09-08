/// Playback-intent, EOF and current-resource recovery regressions.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mg_read_audio_player/src/core/audio_player_session.dart';

void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'manual pause near the tail remains authoritative on recovery',
    () async {
      final harness = _Harness()..source.failFollowing = true;
      addTearDown(harness.close);
      await harness.session.initialize();
      harness.backend.emit(
        harness.backend.snapshot.copyWith(
          playing: true,
          position: const Duration(seconds: 95),
        ),
      );
      await settle();

      await harness.controller.pause();
      harness.source.failFollowing = false;
      await harness.controller.recover();

      expect(harness.controller.snapshot.playing, isFalse);
      expect(harness.controller.snapshot.playbackDesired, isFalse);
      expect(harness.backend.playCalls, 0);
    },
  );

  test('backend recovery retains the current chapter and progress', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.session.initialize();
    await harness.controller.selectQueueEntry('b');
    await harness.controller.seek(const Duration(seconds: 40));
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: false,
        errorMessage: 'network error',
      ),
    );

    await harness.controller.recover();

    expect(harness.controller.snapshot.currentTrack?.id, 'b');
    expect(harness.controller.snapshot.position, const Duration(seconds: 40));
    expect(harness.backend.openedTrackIds.last, <String>['b']);
    expect(harness.source.selectedTrackIds.last, 'b');
  });

  test(
    'initial recovery resolves a saved chapter absent from loaded URLs',
    () async {
      final harness = _Harness();
      harness.store.progress = AudioPlaybackProgress(
        collectionId: 'book',
        trackId: 'b',
        position: const Duration(seconds: 37),
        updatedAt: DateTime.utc(2030),
      );
      addTearDown(harness.close);

      await harness.session.initialize();

      expect(harness.controller.snapshot.currentTrack?.id, 'b');
      expect(harness.controller.snapshot.position, const Duration(seconds: 37));
      expect(harness.source.selectedTrackIds, <String>['b']);
    },
  );

  test(
    'prefetch completing after EOF advances and resumes immediately',
    () async {
      final harness = _Harness();
      final pending = Completer<List<AudioTrack>>();
      harness.source.pendingFollowing = pending;
      addTearDown(harness.close);
      await harness.session.initialize();
      harness.backend.emit(
        harness.backend.snapshot.copyWith(
          playing: true,
          position: const Duration(seconds: 95),
        ),
      );
      await settle();
      harness.backend.emit(
        harness.backend.snapshot.copyWith(
          playing: false,
          completed: true,
          position: const Duration(seconds: 100),
        ),
      );

      pending.complete(<AudioTrack>[_track('b')]);
      await settle();
      await settle();

      expect(harness.controller.snapshot.currentTrack?.id, 'b');
      expect(harness.controller.snapshot.playing, isTrue);
      expect(harness.backend.nextCalls, 1);
    },
  );

  test('pause during recovery cancels a later automatic resume', () async {
    final harness = _Harness()..source.failFollowing = true;
    addTearDown(harness.close);
    await harness.session.initialize();
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: true,
        position: const Duration(seconds: 95),
      ),
    );
    await settle();
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: false,
        completed: true,
        position: const Duration(seconds: 100),
      ),
    );
    final pending = Completer<List<AudioTrack>>();
    harness.source
      ..failFollowing = false
      ..pendingFollowing = pending;

    final recovery = harness.controller.recover();
    await settle();
    expect(harness.controller.snapshot.resourceLoading, isTrue);
    await harness.controller.pause();
    expect(harness.controller.snapshot.resourceLoading, isFalse);
    pending.complete(<AudioTrack>[_track('b')]);
    await recovery;

    expect(harness.controller.snapshot.currentTrack?.id, 'a');
    expect(harness.controller.snapshot.playing, isFalse);
  });

  test('prefetch lead time is wall-clock aware at faster rates', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.session.initialize();
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: true,
        rate: 3,
        position: const Duration(seconds: 60),
      ),
    );
    await settle();

    expect(harness.source.followingCalls, 1);
  });

  test('unknown duration still primes one following track', () async {
    final harness = _Harness(duration: Duration.zero);
    addTearDown(harness.close);

    await harness.session.initialize();
    await settle();

    expect(harness.source.followingCalls, 1);
    expect(harness.backend.appendedTrackIds, <String>['b']);
  });

  test('automatic continuation retries stop at the configured bound', () async {
    final harness = _Harness()..source.failFollowing = true;
    addTearDown(harness.close);
    await harness.session.initialize();
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: true,
        position: const Duration(seconds: 95),
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 180));

    expect(harness.source.followingCalls, 2);
  });

  test('an expired loaded URL is re-resolved before selection', () async {
    final harness = _Harness(
      initialTracks: <AudioTrack>[
        _track('a'),
        AudioTrack(
          id: 'b',
          title: 'b',
          resource: Uri.parse('https://expired.test/b.mp3'),
          resourcePolicy: AudioResourcePolicy.refreshable,
          expiresAt: DateTime.utc(2020),
        ),
      ],
    );
    addTearDown(harness.close);
    await harness.session.initialize();

    await harness.controller.selectQueueEntry('b');

    expect(harness.source.selectedTrackIds, <String>['b']);
    expect(
      harness.backend.openedResources.last.single,
      Uri.parse('https://example.test/b.mp3'),
    );
  });

  test('a selection supersedes an older continuation request', () async {
    final harness = _Harness();
    final pending = Completer<List<AudioTrack>>();
    harness.source.pendingFollowing = pending;
    addTearDown(harness.close);
    await harness.session.initialize();
    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: true,
        position: const Duration(seconds: 95),
      ),
    );
    await settle();

    await harness.controller.selectQueueEntry('b');
    pending.complete(<AudioTrack>[_track('b')]);
    await settle();

    expect(harness.controller.snapshot.currentTrack?.id, 'b');
    expect(harness.backend.appendedTrackIds, isEmpty);
  });

  test('a failed selection restores backend snapshot observation', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.session.initialize();
    harness.backend.failNextOpen = true;

    await harness.controller.selectQueueEntry('b');
    expect(
      harness.controller.snapshot.failure?.code,
      'audio_selected_resource_unavailable',
    );

    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        playing: true,
        position: const Duration(seconds: 12),
      ),
    );
    await settle();

    expect(harness.controller.snapshot.position, const Duration(seconds: 12));
    expect(harness.controller.snapshot.playing, isTrue);
  });

  test('backend diagnostics retain a bounded original error', () async {
    final harness = _Harness();
    addTearDown(harness.close);
    await harness.session.initialize();

    harness.backend.emit(
      harness.backend.snapshot.copyWith(
        errorMessage: List<String>.filled(700, 'x').join(),
      ),
    );
    await settle();

    final failure = harness.observer.failures.last;
    expect(failure.code, 'audio_backend_error');
    expect(failure.location, '播放器读取音频资源');
    expect(failure.debugDetail, hasLength(512));
  });
}

AudioTrack _track(String id) => AudioTrack(
  id: id,
  title: id,
  resource: Uri.parse('https://example.test/$id.mp3'),
);

final class _Harness {
  _Harness({
    this.duration = const Duration(seconds: 100),
    List<AudioTrack>? initialTracks,
  }) {
    source.initialTracks = initialTracks ?? <AudioTrack>[_track('a')];
    backend.duration = duration;
    session = AudioPlayerSession(
      collectionId: 'book',
      dataSource: source,
      stateStore: store,
      backend: backend,
      controller: controller,
      observer: observer,
      prefetchBatchSize: 1,
      prefetchLeadTime: const Duration(seconds: 30),
      recoveryBackoff: const <Duration>[Duration(milliseconds: 50)],
    );
  }

  final Duration duration;
  final AudioPlayerController controller = AudioPlayerController();
  final _Source source = _Source();
  final _Backend backend = _Backend();
  final _Store store = _Store();
  final _Observer observer = _Observer();
  late final AudioPlayerSession session;

  Future<void> close() async {
    source.pendingFollowing?.complete(const <AudioTrack>[]);
    await session.close();
    controller.dispose();
  }
}

final class _Observer extends AudioPlayerObserver {
  final List<AudioPlayerFailure> failures = <AudioPlayerFailure>[];

  @override
  void onFailure(AudioPlayerFailure failure) {
    failures.add(failure);
  }
}

final class _Source implements AudioPlaylistQueueDataSource {
  late List<AudioTrack> initialTracks;
  bool failFollowing = false;
  Completer<List<AudioTrack>>? pendingFollowing;
  int followingCalls = 0;
  final List<String> selectedTrackIds = <String>[];

  @override
  Future<AudioPlaylist> loadPlaylist(String collectionId) async =>
      AudioPlaylist(
        collectionId: collectionId,
        title: collectionId,
        tracks: initialTracks,
        queueEntries: const <AudioQueueEntry>[
          AudioQueueEntry(id: 'a', title: 'a'),
          AudioQueueEntry(id: 'b', title: 'b'),
        ],
      );

  @override
  Future<AudioTrack> loadTrackById(
    String collectionId, {
    required String trackId,
  }) async {
    selectedTrackIds.add(trackId);
    return _track(trackId);
  }

  @override
  Future<List<AudioTrack>> loadFollowingTracks(
    String collectionId, {
    required String afterTrackId,
    required int limit,
  }) async {
    followingCalls++;
    if (failFollowing) throw StateError('offline');
    final pending = pendingFollowing;
    if (pending != null) {
      pendingFollowing = null;
      return pending.future;
    }
    return afterTrackId == 'a'
        ? <AudioTrack>[_track('b')]
        : const <AudioTrack>[];
  }
}

final class _Store implements AudioPlaybackStateStore {
  AudioPlaybackProgress? progress;

  @override
  Future<AudioPlaybackProgress?> loadProgress(String collectionId) async =>
      progress;

  @override
  Future<void> saveProgress(AudioPlaybackProgress value) async {
    progress = value;
  }
}

final class _Backend implements AudioPlaybackBackend {
  final StreamController<AudioPlaybackBackendSnapshot> _events =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  AudioPlaybackBackendSnapshot _snapshot = const AudioPlaybackBackendSnapshot();
  Duration duration = const Duration(seconds: 100);
  List<AudioTrack> _tracks = const <AudioTrack>[];
  final List<List<String>> openedTrackIds = <List<String>>[];
  final List<List<Uri>> openedResources = <List<Uri>>[];
  final List<String> appendedTrackIds = <String>[];
  int playCalls = 0;
  int nextCalls = 0;
  bool failNextOpen = false;

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _events.stream;

  void emit(AudioPlaybackBackendSnapshot value) {
    _snapshot = value;
    _events.add(value);
  }

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('open failed');
    }
    _tracks = List<AudioTrack>.of(tracks);
    openedTrackIds.add(tracks.map((track) => track.id).toList());
    openedResources.add(tracks.map((track) => track.resource).toList());
    emit(
      AudioPlaybackBackendSnapshot(
        currentIndex: initialIndex,
        playing: play,
        duration: duration,
      ),
    );
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {
    _tracks = <AudioTrack>[..._tracks, ...tracks];
    appendedTrackIds.addAll(tracks.map((track) => track.id));
  }

  @override
  Future<void> play() async {
    playCalls++;
    emit(_snapshot.copyWith(playing: true, completed: false));
  }

  @override
  Future<void> pause() async => emit(_snapshot.copyWith(playing: false));

  @override
  Future<void> seek(Duration position) async =>
      emit(_snapshot.copyWith(position: position));

  @override
  Future<void> next() async {
    nextCalls++;
    emit(
      _snapshot.copyWith(
        currentIndex: (_snapshot.currentIndex + 1).clamp(0, _tracks.length - 1),
        position: Duration.zero,
        completed: false,
      ),
    );
  }

  @override
  Future<void> previous() async => emit(
    _snapshot.copyWith(
      currentIndex: (_snapshot.currentIndex - 1).clamp(0, _tracks.length - 1),
      position: Duration.zero,
      completed: false,
    ),
  );

  @override
  Future<void> jump(int index) async => emit(
    _snapshot.copyWith(
      currentIndex: index,
      position: Duration.zero,
      completed: false,
    ),
  );

  @override
  Future<void> setRate(double rate) async =>
      emit(_snapshot.copyWith(rate: rate));

  @override
  Future<void> setVolume(double volume) async =>
      emit(_snapshot.copyWith(volume: volume));

  @override
  Future<void> dispose() async => _events.close();
}
