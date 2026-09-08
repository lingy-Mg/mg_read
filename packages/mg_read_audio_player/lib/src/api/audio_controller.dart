/// Safe imperative command surface for an attached audio player view.
///
/// Responsibilities:
/// - Publish the latest immutable snapshot.
/// - Forward commands only to the currently attached session.
///
/// Notes:
/// - Commands complete safely when unattached or disposed.
/// - Binding methods are package-internal despite being visible to Dart tools.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_models.dart';

typedef AudioPlayerCommand = Future<void> Function();
typedef AudioSeekCommand = Future<void> Function(Duration position);
typedef AudioDoubleCommand = Future<void> Function(double value);
typedef AudioIndexCommand = Future<void> Function(int index);
typedef AudioTrackIdCommand = Future<void> Function(String trackId);
typedef AudioSleepTimerCommand = Future<void> Function(Duration? duration);

/// Optional controller for [AudioPlayerView] commands and state observation.
class AudioPlayerController extends ChangeNotifier {
  AudioPlayerController();

  AudioPlayerSnapshot _snapshot = AudioPlayerSnapshot.initial();
  Object? _owner;
  AudioPlayerCommand? _play;
  AudioPlayerCommand? _pause;
  AudioPlayerCommand? _toggle;
  AudioSeekCommand? _seek;
  AudioSeekCommand? _seekBy;
  AudioPlayerCommand? _previous;
  AudioPlayerCommand? _next;
  AudioIndexCommand? _jump;
  AudioTrackIdCommand? _selectQueueEntry;
  AudioDoubleCommand? _setRate;
  AudioDoubleCommand? _setVolume;
  AudioSleepTimerCommand? _setSleepTimer;
  AudioPlayerCommand? _retry;
  AudioPlayerCommand? _recover;
  AudioPlayerCommand? _requestExit;
  bool _disposed = false;

  AudioPlayerSnapshot get snapshot => _snapshot;
  bool get isAttached => !_disposed && _play != null;

  Future<void> play() => _invoke(_play);
  Future<void> pause() => _invoke(_pause);
  Future<void> toggle() => _invoke(_toggle);
  Future<void> seek(Duration position) => _invokeArg(_seek, position);
  Future<void> seekBy(Duration offset) => _invokeArg(_seekBy, offset);
  Future<void> previous() => _invoke(_previous);
  Future<void> next() => _invoke(_next);
  Future<void> jump(int index) => _invokeArg(_jump, index);
  Future<void> selectQueueEntry(String trackId) =>
      _invokeArg(_selectQueueEntry, trackId);
  Future<void> setRate(double rate) => _invokeArg(_setRate, rate);
  Future<void> setVolume(double volume) => _invokeArg(_setVolume, volume);
  Future<void> setSleepTimer(Duration? duration) =>
      _invokeArg(_setSleepTimer, duration);
  Future<void> retry() => _invoke(_retry);

  /// Retries only playback work that was interrupted while the session was
  /// already active. Unlike [retry], this is a no-op for healthy playback.
  Future<void> recover() => _invoke(_recover);
  Future<void> requestExit() => _invoke(_requestExit);

  Future<void> _invoke(AudioPlayerCommand? command) {
    if (_disposed || command == null) return Future<void>.value();
    return command();
  }

  Future<void> _invokeArg<T>(Future<void> Function(T value)? command, T value) {
    if (_disposed || command == null) return Future<void>.value();
    return command(value);
  }

  @internal
  void bind({
    required Object owner,
    required AudioPlayerCommand play,
    required AudioPlayerCommand pause,
    required AudioPlayerCommand toggle,
    required AudioSeekCommand seek,
    required AudioSeekCommand seekBy,
    required AudioPlayerCommand previous,
    required AudioPlayerCommand next,
    required AudioIndexCommand jump,
    required AudioTrackIdCommand selectQueueEntry,
    required AudioDoubleCommand setRate,
    required AudioDoubleCommand setVolume,
    required AudioSleepTimerCommand setSleepTimer,
    required AudioPlayerCommand retry,
    required AudioPlayerCommand recover,
    required AudioPlayerCommand requestExit,
  }) {
    if (_disposed) return;
    _owner = owner;
    _play = play;
    _pause = pause;
    _toggle = toggle;
    _seek = seek;
    _seekBy = seekBy;
    _previous = previous;
    _next = next;
    _jump = jump;
    _selectQueueEntry = selectQueueEntry;
    _setRate = setRate;
    _setVolume = setVolume;
    _setSleepTimer = setSleepTimer;
    _retry = retry;
    _recover = recover;
    _requestExit = requestExit;
  }

  @internal
  void updateSnapshot(AudioPlayerSnapshot value, {required Object owner}) {
    if (_disposed || !identical(owner, _owner)) return;
    _snapshot = value;
    notifyListeners();
  }

  @internal
  void unbind(Object owner) {
    if (_disposed || !identical(owner, _owner)) return;
    _clearBindings();
  }

  void _clearBindings() {
    _owner = null;
    _play = null;
    _pause = null;
    _toggle = null;
    _seek = null;
    _seekBy = null;
    _previous = null;
    _next = null;
    _jump = null;
    _selectQueueEntry = null;
    _setRate = null;
    _setVolume = null;
    _setSleepTimer = null;
    _retry = null;
    _recover = null;
    _requestExit = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _clearBindings();
    super.dispose();
  }
}
