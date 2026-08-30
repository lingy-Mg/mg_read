/// Route-independent state machine for one audio playback session.
///
/// Responsibilities:
/// - Load, autoplay and extend a queue, restore semantic position and bind commands.
/// - Reject stale async results and serialize backend initialization and saves.
/// - Flush progress on pause, track change, lifecycle, exit and close.
///
/// Notes:
/// - Background audio services are host-owned and are not started here.
/// - Position streams are throttled before persistence; UI remains immediate.
/// - Route teardown releases transport resources before awaiting slow storage.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/audio_contracts.dart';
import '../api/audio_controller.dart';
import '../api/audio_models.dart';

final class AudioPlayerSession extends ChangeNotifier {
  AudioPlayerSession({
    required this.collectionId,
    required this.dataSource,
    required this.stateStore,
    required this.backend,
    required this.controller,
    this.observer,
    this.saveInterval = const Duration(milliseconds: 800),
    this.autoplay = true,
    this.prefetchThreshold = 1,
    this.prefetchBatchSize = 3,
    this.prefetchLeadTime,
    DateTime Function()? clock,
  }) : assert(prefetchThreshold >= 0),
       assert(prefetchBatchSize > 0),
       _clock = clock ?? DateTime.now,
       _snapshot = AudioPlayerSnapshot.initial() {
    controller.bind(
      owner: this,
      play: play,
      pause: pause,
      toggle: toggle,
      seek: seek,
      seekBy: seekBy,
      previous: previous,
      next: next,
      jump: jump,
      selectQueueEntry: selectQueueEntry,
      setRate: setRate,
      setVolume: setVolume,
      setSleepTimer: setSleepTimer,
      retry: initialize,
      requestExit: requestExit,
    );
    _backendSubscription = backend.snapshots.listen(_acceptBackendSnapshot);
  }

  final String collectionId;
  final AudioPlayerDataSource dataSource;
  final AudioPlaybackStateStore stateStore;
  final AudioPlaybackBackend backend;
  final AudioPlayerController controller;
  final AudioPlayerObserver? observer;
  final Duration saveInterval;

  /// Starts the selected track after its resource and restored position load.
  final bool autoplay;
  final int prefetchThreshold;
  final int prefetchBatchSize;

  /// When set, source URLs are resolved only shortly before the current track
  /// ends instead of merely because it is near a loaded queue boundary.
  final Duration? prefetchLeadTime;
  final DateTime Function() _clock;

  AudioPlayerSnapshot _snapshot;
  AudioPlaylist? _playlist;
  late final StreamSubscription<AudioPlaybackBackendSnapshot>
  _backendSubscription;
  Timer? _saveTimer;
  Timer? _sleepTimer;
  Future<void> _backendInitializationTail = Future<void>.value();
  Future<void> _saveTail = Future<void>.value();
  Future<void>? _closeFuture;
  Future<void>? _exitRequest;
  Future<void>? _prefetchRequest;
  String? _lastPrefetchTriggerTrackId;
  String? _lastBackendErrorMessage;
  int _generation = 0;
  bool _backendSnapshotsEnabled = false;
  bool _closing = false;
  bool _closed = false;

  AudioPlayerSnapshot get snapshot => _snapshot;

  Future<void> initialize() async {
    if (_closing || _closed) return;
    final generation = ++_generation;
    _backendSnapshotsEnabled = false;
    _lastBackendErrorMessage = null;
    _lastPrefetchTriggerTrackId = null;
    _playlist = null;
    _emit(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.loading,
        queue: _snapshot.queue,
        queueEntries: _snapshot.queueEntries,
        collectionId: collectionId,
        collectionTitle: _snapshot.collectionTitle,
        creator: _snapshot.creator,
      ),
    );
    try {
      final results = await Future.wait<Object?>(<Future<Object?>>[
        dataSource.loadPlaylist(collectionId),
        stateStore.loadProgress(collectionId),
      ]);
      if (!_isCurrent(generation)) return;
      final playlist = results[0]! as AudioPlaylist;
      final loadedProgress = results[1] as AudioPlaybackProgress?;
      final progress = loadedProgress?.collectionId == collectionId
          ? loadedProgress
          : null;
      _validatePlaylist(playlist);
      final initialIndex = progress == null
          ? 0
          : playlist.tracks.indexWhere((track) => track.id == progress.trackId);
      final restoredIndex = initialIndex < 0 ? 0 : initialIndex;
      _emit(
        AudioPlayerSnapshot(
          status: AudioPlayerStatus.loading,
          collectionId: collectionId,
          collectionTitle: playlist.title,
          creator: playlist.creator,
          queue: playlist.tracks,
          queueEntries: playlist.queueEntries,
          currentIndex: restoredIndex,
        ),
      );
      final backendInitialization = _backendInitializationTail.then<void>((
        _,
      ) async {
        if (!_isCurrent(generation)) return;
        await backend.open(
          playlist.tracks,
          initialIndex: restoredIndex,
          play: autoplay,
        );
        if (!_isCurrent(generation)) return;
        if (progress != null &&
            progress.trackId == playlist.tracks[restoredIndex].id &&
            progress.position > Duration.zero) {
          await backend.seek(progress.position);
        }
      });
      _backendInitializationTail = backendInitialization.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await backendInitialization;
      if (!_isCurrent(generation)) return;
      _playlist = playlist;
      _backendSnapshotsEnabled = true;
      _applyReadySnapshot(backend.snapshot);
      _prefetchIfNeeded(restoredIndex, snapshot: _snapshot);
      _handleBackendError(backend.snapshot.errorMessage);
      await _notify(() => observer?.onSessionStarted(collectionId));
      if (!_isCurrent(generation)) return;
      await _notify(
        () => observer?.onTrackChanged(playlist.tracks[restoredIndex]),
      );
    } on Object catch (error) {
      if (!_isCurrent(generation)) return;
      final failure = _initializationFailure(error);
      _emit(
        _snapshot.copyWith(status: AudioPlayerStatus.error, failure: failure),
      );
      await _notify(() => observer?.onFailure(failure));
    }
  }

  AudioPlayerFailure _initializationFailure(Object error) {
    if (error is AudioPlayerLoadException) {
      return AudioPlayerFailure(
        code: error.code,
        message: error.message,
        location: error.location,
      );
    }
    return const AudioPlayerFailure(
      code: 'audio_initialization_failed',
      location: '播放器初始化',
      message: '播放准备失败。请重试；若仍失败，请在运行日志中查看音频资源事件。',
    );
  }

  bool _isCurrent(int generation) =>
      !_closing && !_closed && generation == _generation;

  void _validatePlaylist(AudioPlaylist playlist) {
    if (playlist.collectionId != collectionId) {
      throw const FormatException('Invalid audio playlist identity.');
    }
    if (playlist.tracks.isEmpty) {
      throw const AudioPlayerLoadException(
        code: 'audio_queue_empty',
        location: '播放队列',
        message: '当前内容暂无可播放章节。',
      );
    }
    final ids = <String>{};
    for (final track in playlist.tracks) {
      if (track.id.trim().isEmpty ||
          track.title.trim().isEmpty ||
          !track.resource.hasScheme ||
          !ids.add(track.id)) {
        throw const FormatException('Invalid or duplicate audio track.');
      }
    }
  }

  void _acceptBackendSnapshot(AudioPlaybackBackendSnapshot value) {
    if (_closing || _closed || !_backendSnapshotsEnabled || _playlist == null) {
      return;
    }
    final queue = _playlist!.tracks;
    if (value.currentIndex < 0 || value.currentIndex >= queue.length) return;
    final previousIndex = _snapshot.currentIndex;
    if (_snapshot.status == AudioPlayerStatus.ready &&
        previousIndex != value.currentIndex) {
      final previousProgress = _progressFor(_snapshot);
      if (previousProgress != null) _enqueueSave(previousProgress);
    }
    _applyReadySnapshot(value);
    if (previousIndex != value.currentIndex) {
      unawaited(
        _notify(() => observer?.onTrackChanged(queue[value.currentIndex])),
      );
    }
    _prefetchIfNeeded(value.currentIndex, snapshot: _snapshot);
    if (value.playing) _scheduleThrottledSave();
    _handleBackendError(value.errorMessage);
  }

  void _prefetchIfNeeded(
    int currentIndex, {
    required AudioPlayerSnapshot snapshot,
  }) {
    final playlist = _playlist;
    final dataSource = this.dataSource;
    final leadTime = prefetchLeadTime;
    final isPrefetchWindow = switch (leadTime) {
      null =>
        playlist != null &&
            currentIndex + prefetchThreshold >= playlist.tracks.length - 1,
      final Duration lead =>
        playlist != null &&
            currentIndex == playlist.tracks.length - 1 &&
            snapshot.duration > Duration.zero &&
            snapshot.duration - snapshot.position <= lead,
    };
    if (playlist == null ||
        dataSource is! AudioPlaylistContinuationDataSource ||
        !isPrefetchWindow ||
        _prefetchRequest != null ||
        _closing ||
        _closed) {
      return;
    }
    final triggerTrackId = playlist.tracks[currentIndex].id;
    if (_lastPrefetchTriggerTrackId == triggerTrackId) return;
    _lastPrefetchTriggerTrackId = triggerTrackId;
    final generation = _generation;
    final afterTrackId = playlist.tracks.last.id;
    _prefetchRequest =
        _loadFollowingTracks(
          dataSource,
          generation: generation,
          afterTrackId: afterTrackId,
        ).whenComplete(() {
          _prefetchRequest = null;
        });
  }

  Future<void> _loadFollowingTracks(
    AudioPlaylistContinuationDataSource dataSource, {
    required int generation,
    required String afterTrackId,
  }) async {
    try {
      final loaded = await dataSource.loadFollowingTracks(
        collectionId,
        afterTrackId: afterTrackId,
        limit: prefetchBatchSize,
      );
      if (!_isCurrent(generation) || loaded.isEmpty) return;
      final playlist = _playlist;
      if (playlist == null || playlist.tracks.last.id != afterTrackId) return;
      final knownIds = playlist.tracks.map((track) => track.id).toSet();
      final additions = loaded
          .where(
            (track) =>
                track.id.trim().isNotEmpty &&
                track.resource.hasScheme &&
                knownIds.add(track.id),
          )
          .toList(growable: false);
      if (additions.isEmpty || !_isCurrent(generation)) return;
      await backend.append(additions);
      if (!_isCurrent(generation)) return;
      _playlist = AudioPlaylist(
        collectionId: playlist.collectionId,
        title: playlist.title,
        creator: playlist.creator,
        tracks: <AudioTrack>[...playlist.tracks, ...additions],
        queueEntries: playlist.queueEntries,
      );
      _applyReadySnapshot(backend.snapshot);
    } catch (_) {
      // The already buffered chapter remains playable. A later track change
      // retries the bounded prefetch instead of interrupting current audio.
    }
  }

  void _handleBackendError(String? rawMessage) {
    final message = rawMessage?.trim();
    if (message == null || message.isEmpty) {
      final shouldClearFailure =
          _lastBackendErrorMessage != null &&
          _snapshot.failure?.code == 'audio_backend_error';
      _lastBackendErrorMessage = null;
      if (shouldClearFailure) _emit(_snapshot.copyWith(clearFailure: true));
      return;
    }
    if (message == _lastBackendErrorMessage) return;
    _lastBackendErrorMessage = message;
    const failure = AudioPlayerFailure(
      code: 'audio_backend_error',
      location: '播放器读取音频资源',
      message: '播放遇到错误，请稍后重试。',
    );
    _emit(_snapshot.copyWith(failure: failure));
    unawaited(_notify(() => observer?.onFailure(failure)));
  }

  void _applyReadySnapshot(AudioPlaybackBackendSnapshot value) {
    final playlist = _playlist;
    if (playlist == null) return;
    final index = value.currentIndex.clamp(0, playlist.tracks.length - 1);
    _emit(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.ready,
        collectionId: collectionId,
        collectionTitle: playlist.title,
        creator: playlist.creator,
        queue: playlist.tracks,
        queueEntries: playlist.queueEntries,
        currentIndex: index,
        playing: value.playing,
        buffering: value.buffering,
        position: _clampPosition(value.position, value.duration),
        duration: value.duration,
        rate: value.rate,
        volume: value.volume,
        sleepTimerDuration: _snapshot.sleepTimerDuration,
        failure: _snapshot.failure,
      ),
    );
  }

  void _emit(AudioPlayerSnapshot value) {
    if (_closed) return;
    _snapshot = value;
    controller.updateSnapshot(value, owner: this);
    notifyListeners();
  }

  Future<void> play() => _runTransport(backend.play);

  Future<void> pause() async {
    await _runTransport(backend.pause);
    await flushProgress();
  }

  Future<void> toggle() => _snapshot.playing ? pause() : play();

  Future<void> seek(Duration position) async {
    if (_snapshot.status != AudioPlayerStatus.ready) return;
    await _runTransport(
      () => backend.seek(_clampPosition(position, _snapshot.duration)),
    );
    await flushProgress();
  }

  Future<void> seekBy(Duration offset) => seek(_snapshot.position + offset);

  Future<void> previous() => _switchTrack(
    canSwitch: _snapshot.canGoPrevious,
    command: backend.previous,
  );

  Future<void> next() =>
      _switchTrack(canSwitch: _snapshot.canGoNext, command: backend.next);

  Future<void> jump(int index) => _switchTrack(
    canSwitch:
        index >= 0 &&
        index < _snapshot.queue.length &&
        index != _snapshot.currentIndex,
    command: () => backend.jump(index),
  );

  /// Resolves a visible catalog entry only when the listener selects it.
  Future<void> selectQueueEntry(String trackId) async {
    final playlist = _playlist;
    if (playlist == null ||
        _snapshot.status != AudioPlayerStatus.ready ||
        trackId.isEmpty ||
        trackId == _snapshot.currentTrack?.id) {
      return;
    }
    final source = dataSource;
    if (source is! AudioPlaylistQueueDataSource) {
      final loadedIndex = playlist.tracks.indexWhere(
        (track) => track.id == trackId,
      );
      if (loadedIndex >= 0) await jump(loadedIndex);
      return;
    }
    final generation = ++_generation;
    await flushProgress();
    try {
      final track = await source.loadTrackById(collectionId, trackId: trackId);
      if (!_isCurrent(generation)) return;
      _backendSnapshotsEnabled = false;
      final opening = _backendInitializationTail.then<void>((_) async {
        if (!_isCurrent(generation)) return;
        await backend.open(<AudioTrack>[track], initialIndex: 0, play: true);
      });
      _backendInitializationTail = opening.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      await opening;
      if (!_isCurrent(generation)) return;
      _playlist = AudioPlaylist(
        collectionId: playlist.collectionId,
        title: playlist.title,
        creator: playlist.creator,
        tracks: <AudioTrack>[track],
        queueEntries: playlist.queueEntries,
      );
      _backendSnapshotsEnabled = true;
      _applyReadySnapshot(backend.snapshot);
      _prefetchIfNeeded(0, snapshot: _snapshot);
      await _notify(() => observer?.onTrackChanged(track));
    } on Object {
      if (!_isCurrent(generation)) return;
      const failure = AudioPlayerFailure(
        code: 'audio_selected_resource_unavailable',
        location: '所选章节的播放地址',
        message: '当前章节暂时无法播放，请稍后重试。',
      );
      _emit(_snapshot.copyWith(failure: failure));
      await _notify(() => observer?.onFailure(failure));
    }
  }

  Future<void> _switchTrack({
    required bool canSwitch,
    required Future<void> Function() command,
  }) async {
    if (!canSwitch || _snapshot.status != AudioPlayerStatus.ready) return;
    await flushProgress();
    await _runTransport(command);
  }

  Future<void> setRate(double rate) =>
      _runTransport(() => backend.setRate(rate.clamp(0.5, 3)));

  Future<void> setVolume(double volume) =>
      _runTransport(() => backend.setVolume(volume.clamp(0, 1)));

  Future<void> _runTransport(Future<void> Function() action) async {
    if (_closing || _closed || _snapshot.status != AudioPlayerStatus.ready) {
      return;
    }
    try {
      await action();
    } catch (_) {
      const failure = AudioPlayerFailure(
        code: 'audio_transport_failed',
        location: '播放控制',
        message: '播放操作失败，请重试。',
      );
      _emit(_snapshot.copyWith(failure: failure));
      await _notify(() => observer?.onFailure(failure));
    }
  }

  Future<void> setSleepTimer(Duration? duration) async {
    if (_closing || _closed) return;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (duration == null || duration <= Duration.zero) {
      _emit(_snapshot.copyWith(clearSleepTimer: true));
      return;
    }
    _emit(_snapshot.copyWith(sleepTimerDuration: duration));
    _sleepTimer = Timer(duration, () {
      _sleepTimer = null;
      if (_closing || _closed) return;
      _emit(_snapshot.copyWith(clearSleepTimer: true));
      unawaited(pause());
    });
  }

  void _scheduleThrottledSave() {
    if (_saveTimer != null || _closing || _closed) return;
    _saveTimer = Timer(saveInterval, () {
      _saveTimer = null;
      final progress = _progressFor(_snapshot);
      if (progress != null) _enqueueSave(progress);
    });
  }

  Future<void> flushProgress() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final progress = _progressFor(_snapshot);
    if (progress != null) _enqueueSave(progress);
    return _saveTail;
  }

  AudioPlaybackProgress? _progressFor(AudioPlayerSnapshot snapshot) {
    final track = snapshot.currentTrack;
    if (track == null || snapshot.status != AudioPlayerStatus.ready) {
      return null;
    }
    return AudioPlaybackProgress(
      collectionId: collectionId,
      trackId: track.id,
      position: snapshot.position,
      updatedAt: _clock().toUtc(),
    );
  }

  void _enqueueSave(AudioPlaybackProgress progress) {
    _saveTail = _saveTail.then((_) async {
      try {
        await stateStore.saveProgress(progress);
      } catch (_) {
        const failure = AudioPlayerFailure(
          code: 'audio_progress_save_failed',
          location: '播放进度保存',
          message: '播放进度暂未保存。',
        );
        await _notify(() => observer?.onFailure(failure));
      }
    });
  }

  Future<void> handleLifecycle(AudioPlayerLifecycleState state) async {
    final progress = _progressFor(_snapshot);
    await _notify(() => observer?.onLifecycleChanged(state, progress));
    if (state != AudioPlayerLifecycleState.resumed) await flushProgress();
  }

  Future<void> requestExit() => _exitRequest ??= _beginExitRequest();

  Future<void> _beginExitRequest() async {
    if (_closing || _closed) return;
    try {
      await flushProgress();
      if (_closing || _closed) return;
      await _notify(() => observer?.onExitRequested(_progressFor(_snapshot)));
    } finally {
      if (!_closing && !_closed) _exitRequest = null;
    }
  }

  Future<void> close() => _closeFuture ??= _beginClose();

  Future<void> _beginClose() async {
    if (_closed) return;
    _closing = true;
    _generation++;
    _backendSnapshotsEnabled = false;
    _lastBackendErrorMessage = null;
    _sleepTimer?.cancel();
    _saveTimer?.cancel();
    _sleepTimer = null;
    _saveTimer = null;
    final progress = _progressFor(_snapshot);
    if (progress != null) _enqueueSave(progress);
    controller.unbind(this);
    final backendShutdown = Future.wait<void>(<Future<void>>[
      _backendSubscription.cancel(),
      backend.dispose(),
    ]).then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await _saveTail;
    await _notify(() => observer?.onSessionEnded(collectionId, progress));
    await backendShutdown;
    _closed = true;
    _closing = false;
    super.dispose();
  }

  Future<void> _notify(FutureOr<void> Function() callback) async {
    try {
      await callback();
    } catch (_) {
      // Observer failures never change playback or persistence results.
    }
  }

  Duration _clampPosition(Duration value, Duration duration) {
    if (value < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && value > duration) return duration;
    return value;
  }
}
