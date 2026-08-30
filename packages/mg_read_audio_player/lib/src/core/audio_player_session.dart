/// Route-independent state machine for one audio playback session.
///
/// Responsibilities:
/// - Load and validate a queue, restore semantic position and bind commands.
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
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
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
    _playlist = null;
    _emit(
      AudioPlayerSnapshot(
        status: AudioPlayerStatus.loading,
        queue: _snapshot.queue,
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
          play: false,
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
    if (playlist.collectionId != collectionId || playlist.tracks.isEmpty) {
      throw const FormatException('Invalid audio playlist identity or size.');
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
    if (value.playing) _scheduleThrottledSave();
    _handleBackendError(value.errorMessage);
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
