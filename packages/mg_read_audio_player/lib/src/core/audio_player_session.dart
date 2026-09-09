/// Route-independent state machine for one audio playback session.
///
/// Responsibilities:
/// - Load, autoplay and extend a queue, restore semantic position and bind commands.
/// - Preserve explicit play/pause intent across bounded recovery and cancellation.
/// - Reject stale async results and serialize backend initialization and saves.
/// - Flush progress on pause, track change, lifecycle, exit and close.
///
/// Notes:
/// - Background audio services are host-owned and are not started here.
/// - Backend playing/buffering/completed state never replaces user intent.
/// - Position streams are throttled before persistence; UI remains immediate.
/// - Route teardown releases transport resources before awaiting slow storage.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/audio_contracts.dart';
import '../api/audio_controller.dart';
import '../api/audio_models.dart';

part 'audio_player_session_recovery.dart';
part 'audio_player_session_playback.dart';
part 'audio_player_session_selection.dart';

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
    this.recoveryStallTimeout = const Duration(seconds: 8),
    this.recoveryBackoff = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 3),
      Duration(seconds: 8),
      Duration(seconds: 20),
    ],
    DateTime Function()? clock,
  }) : assert(prefetchThreshold >= 0),
       assert(prefetchBatchSize > 0),
       assert(recoveryStallTimeout > Duration.zero),
       assert(recoveryBackoff.isNotEmpty),
       _clock = clock ?? DateTime.now,
       _playbackDesired = autoplay,
       _snapshot = AudioPlayerSnapshot.initial().copyWith(
         playbackDesired: autoplay,
       ) {
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
      retry: retry,
      recover: recover,
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
  final Duration recoveryStallTimeout;
  final List<Duration> recoveryBackoff;
  final DateTime Function() _clock;

  AudioPlayerSnapshot _snapshot;
  AudioPlaylist? _playlist;
  late final StreamSubscription<AudioPlaybackBackendSnapshot>
  _backendSubscription;
  Timer? _saveTimer;
  Timer? _sleepTimer;
  Timer? _stallTimer;
  Timer? _recoveryTimer;
  Future<void> _backendInitializationTail = Future<void>.value();
  Future<void> _saveTail = Future<void>.value();
  Future<void>? _closeFuture;
  Future<void>? _exitRequest;
  Future<void>? _prefetchRequest;
  Future<void>? _recoveryRequest;
  String? _lastPrefetchTriggerTrackId;
  String? _lastBackendErrorMessage;
  bool _continuationRecoveryPending = false;
  bool _playbackDesired;
  int _playbackIntentRevision = 0;
  int _continuationRequestRevision = 0;
  int _recoveryAttempt = 0;
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
    _cancelContinuationLoad(retry: false);
    _cancelRecoveryTimers(resetAttempts: true);
    _playlist = null;
    _emit(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.loading,
        queue: _snapshot.queue,
        queueEntries: _snapshot.queueEntries,
        collectionId: collectionId,
        collectionTitle: _snapshot.collectionTitle,
        creator: _snapshot.creator,
        playbackDesired: _playbackDesired,
      ),
    );
    try {
      final results = await Future.wait<Object?>(<Future<Object?>>[
        dataSource.loadPlaylist(collectionId),
        _loadSavedProgress(),
      ]);
      if (!_isCurrent(generation)) return;
      var playlist = results[0]! as AudioPlaylist;
      final loadedProgress = results[1] as AudioPlaybackProgress?;
      final progress = loadedProgress?.collectionId == collectionId
          ? loadedProgress
          : null;
      _validatePlaylist(playlist);
      if (progress != null &&
          !playlist.tracks.any((track) => track.id == progress.trackId) &&
          dataSource is AudioPlaylistQueueDataSource &&
          playlist.queueEntries.any(
            (entry) => entry.id == progress.trackId && !entry.isLocked,
          )) {
        final restoredTrack = await (dataSource as AudioPlaylistQueueDataSource)
            .loadTrackById(collectionId, trackId: progress.trackId);
        if (!_isCurrent(generation)) return;
        playlist = AudioPlaylist(
          collectionId: playlist.collectionId,
          title: playlist.title,
          creator: playlist.creator,
          tracks: <AudioTrack>[restoredTrack],
          queueEntries: playlist.queueEntries,
        );
        _validatePlaylist(playlist);
      }
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
          playbackDesired: _playbackDesired,
        ),
      );
      final backendInitialization = _backendInitializationTail.then<void>((
        _,
      ) async {
        if (!_isCurrent(generation)) return;
        final restoredPosition =
            progress != null &&
                progress.trackId == playlist.tracks[restoredIndex].id &&
                progress.position > Duration.zero
            ? progress.position
            : Duration.zero;
        await backend.open(
          playlist.tracks,
          initialIndex: restoredIndex,
          // A restored timestamp must be applied before playback starts.
          // Otherwise the backend can publish an early zero position and the
          // first persistence tick may overwrite the durable timestamp.
          play: _playbackDesired && restoredPosition == Duration.zero,
        );
        if (!_isCurrent(generation)) return;
        if (restoredPosition > Duration.zero) {
          await backend.seek(restoredPosition);
          if (!_isCurrent(generation)) return;
          if (_playbackDesired) await backend.play();
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
    return _failureFrom(
      error,
      code: 'audio_initialization_failed',
      location: '播放器初始化',
      message: '播放准备失败。请重试；若仍失败，请在运行日志中查看音频资源事件。',
    );
  }

  Future<AudioPlaybackProgress?> _loadSavedProgress() async {
    try {
      return await stateStore.loadProgress(collectionId);
    } on Object catch (error) {
      throw AudioPlayerLoadException(
        code: 'audio_progress_load_failed',
        location: '播放进度读取',
        message: '无法读取上次播放进度。',
        debugDetail: _boundedDebugDetail(error),
      );
    }
  }

  AudioPlayerFailure _failureFrom(
    Object error, {
    required String code,
    required String location,
    required String message,
  }) {
    if (error is AudioPlayerLoadException) {
      return AudioPlayerFailure(
        code: error.code,
        message: error.message,
        location: error.location,
        debugDetail: error.debugDetail,
      );
    }
    return AudioPlayerFailure(
      code: code,
      location: location,
      message: message,
      debugDetail: _boundedDebugDetail(error),
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
    _observeRecoveryState(value);
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
    final failure = AudioPlayerFailure(
      code: 'audio_backend_error',
      location: '播放器读取音频资源',
      message: '播放遇到错误，请稍后重试。',
      debugDetail: _boundedDebugDetail(message),
    );
    _emit(_snapshot.copyWith(failure: failure));
    unawaited(_notify(() => observer?.onFailure(failure)));
  }

  void _applyReadySnapshot(
    AudioPlaybackBackendSnapshot value, {
    bool? resourceLoading,
  }) {
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
        playbackDesired: _playbackDesired,
        playing: value.playing,
        buffering: value.buffering,
        // Backend position/completion events can arrive while Runtime is
        // resolving the next resource. They must not end that independent
        // operation or let the Android media session release audio focus.
        resourceLoading: resourceLoading ?? _snapshot.resourceLoading,
        completed: value.completed,
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

  void _recordOperation(String stage, {String? targetTrackId}) {
    final snapshot = _snapshot;
    unawaited(
      _notify(
        () => observer?.onOperation(
          AudioPlayerOperationEvent(
            stage: stage,
            currentTrackId: snapshot.currentTrack?.id,
            targetTrackId: targetTrackId,
            playbackDesired: snapshot.playbackDesired,
            playing: snapshot.playing,
            buffering: snapshot.buffering,
            resourceLoading: snapshot.resourceLoading,
            completed: snapshot.completed,
          ),
        ),
      ),
    );
  }

  Future<void> retry() {
    _recordPlaybackIntent(true);
    _cancelRecoveryTimers(resetAttempts: true);
    return initialize();
  }

  Future<void> play() async {
    _recordPlaybackIntent(true);
    _cancelRecoveryTimers(resetAttempts: true);
    if (_closing || _closed || _snapshot.status != AudioPlayerStatus.ready) {
      return;
    }
    _recordOperation('playRequested');
    final generation = _generation;
    final intentRevision = _playbackIntentRevision;
    final track = _snapshot.currentTrack;
    try {
      final started = await _playBackendAndConfirm(
        generation: generation,
        intentRevision: intentRevision,
        targetTrackId: track?.id,
        failureCode: 'audio_playback_start_failed',
        failureLocation: '当前章节开始播放',
        failureMessage: '播放器已收到播放请求，但当前章节没有开始播放。',
      );
      if (!started) return;
      _recordOperation('playReturned');
    } on Object catch (error) {
      if (!_isCurrent(generation) ||
          !_playbackDesired ||
          intentRevision != _playbackIntentRevision) {
        return;
      }
      final failure = _failureFrom(
        error,
        code: 'audio_playback_start_failed',
        location: '当前章节开始播放',
        message: '播放器已收到播放请求，但当前章节没有开始播放。',
      );
      _emit(_snapshot.copyWith(resourceLoading: false, failure: failure));
      _recordOperation('playFailed', targetTrackId: track?.id);
      await _notify(() => observer?.onFailure(failure));
      _scheduleRecoveryRetry();
    }
  }

  Future<void> pause() async {
    _recordPlaybackIntent(false);
    _recordOperation('pauseRequested');
    _cancelContinuationLoad(retry: false);
    _cancelRecoveryTimers(resetAttempts: true);
    if (_snapshot.resourceLoading) {
      _emit(_snapshot.copyWith(resourceLoading: false));
    }
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

  Future<void> previous() => dataSource is AudioPlaylistQueueDataSource
      ? _selectAdjacentQueueEntry(-1)
      : _switchTrack(
          canSwitch: _snapshot.canGoPrevious,
          command: backend.previous,
        );

  Future<void> next() => dataSource is AudioPlaylistQueueDataSource
      ? _selectAdjacentQueueEntry(1)
      : _switchTrack(canSwitch: _snapshot.canGoNext, command: backend.next);

  Future<void> selectQueueEntry(String trackId) => _selectQueueEntry(trackId);

  Future<void> jump(int index) => _switchTrack(
    canSwitch:
        index >= 0 &&
        index < _snapshot.queue.length &&
        index != _snapshot.currentIndex,
    command: () => backend.jump(index),
  );

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
    } on Object catch (error) {
      final failure = _failureFrom(
        error,
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
      } on Object catch (error) {
        final failure = AudioPlayerFailure(
          code: 'audio_progress_save_failed',
          location: '播放进度保存',
          message: '播放进度暂未保存。',
          debugDetail: _boundedDebugDetail(error),
        );
        _emit(_snapshot.copyWith(failure: failure));
        await _notify(() => observer?.onFailure(failure));
      }
    });
  }

  Future<void> handleLifecycle(AudioPlayerLifecycleState state) async {
    final progress = _progressFor(_snapshot);
    await _notify(() => observer?.onLifecycleChanged(state, progress));
    if (state == AudioPlayerLifecycleState.resumed) {
      await recover();
    } else {
      await flushProgress();
    }
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
    _recordPlaybackIntent(false);
    _backendSnapshotsEnabled = false;
    _lastBackendErrorMessage = null;
    _cancelContinuationLoad(retry: false);
    _cancelRecoveryTimers(resetAttempts: true);
    _sleepTimer?.cancel();
    _saveTimer?.cancel();
    _sleepTimer = null;
    _saveTimer = null;
    final progress = _progressFor(_snapshot);
    if (progress != null) _enqueueSave(progress);
    controller.unbind(this);
    final backendShutdown = () async {
      // Cancel delivery synchronously, but do not let a custom stream's
      // asynchronous onCancel hook retain the backend forever.
      _backendSubscription.cancel().ignore();
      try {
        await backend.dispose();
      } on Object {
        // Shutdown remains best-effort after playback intent is invalidated.
      }
    }();
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

  String _boundedDebugDetail(Object error) {
    final value = error.toString().trim();
    return value.length <= 512 ? value : value.substring(0, 512);
  }
}
