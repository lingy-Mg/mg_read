/// Android foreground-media bridge for the app-global audio player.
///
/// Responsibilities:
/// - Mirror one active [AudioPlayerController] into Android's media session.
/// - Configure spoken-audio focus and pause for interruptions/noisy output.
/// - Keep the media foreground service alive for the active session so a
///   Bluetooth or lock-screen play command can resume while the app is hidden.
/// - Serialize system commands and distinguish accepted/failure/boundary cues.
///
/// Notes:
/// - The app playback service owns the engine, Runtime resources and progress.
/// - This bridge coordinates that active Dart session with Android.
/// - Screen-on and validated-network signals request intent-safe recovery.
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/services.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

/// One process-wide Android media-session host for the active audio route.
final class AndroidAudioBackgroundService {
  AndroidAudioBackgroundService._();

  static final AndroidAudioBackgroundService instance = AndroidAudioBackgroundService._();
  static const MethodChannel _platformChannel = MethodChannel('mgread/audio_background');

  Future<MgReadAudioHandler>? _handlerFuture;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  AudioSession? _audioSession;
  bool? _audioSessionActive;
  bool? _desiredAudioSessionActive;
  Future<void> _audioFocusTail = Future<void>.value();

  /// Attaches [controller] before its session begins loading.
  ///
  /// Non-Android hosts retain the supplied observer unchanged; the player is
  /// still fully usable but has no Android foreground-service capability.
  Future<AudioPlayerObserver?> attach({
    required AudioPlayerController controller,
    required Future<void> Function() onSystemStop,
    FutureOr<void> Function(String stage)? onPlatformEvent,
    AudioPlayerObserver? observer,
  }) async {
    if (!Platform.isAndroid) return observer;
    final handler = await (_handlerFuture ??= _initializeHandler());
    await _configureAudioSession();
    await handler.attach(
      controller,
      synchronizeFocus: _synchronizeFocus,
      onSystemStop: onSystemStop,
      onPlatformEvent: onPlatformEvent,
      commandFeedback: _playSystemCommandTone,
    );
    return _AndroidAudioObserver(handler: handler, controller: controller, delegate: observer);
  }

  /// Releases a route that was dismissed while Android attachment was still
  /// completing and therefore never mounted an audio session observer.
  Future<void> detach(AudioPlayerController controller) async {
    if (!Platform.isAndroid || _handlerFuture == null) return;
    final handler = await _handlerFuture;
    await handler?.detach(controller);
  }

  Future<MgReadAudioHandler> _initializeHandler() async {
    final handler = await AudioService.init(
      builder: MgReadAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.mgread.mg_read.audio',
        androidNotificationChannelName: '音频播放',
        // Android 12+ can reject a foreground-service restart initiated by a
        // Bluetooth/media-button command while the app is in the background.
        androidStopForegroundOnPause: false,
      ),
    );
    _platformChannel.setMethodCallHandler((call) async {
      if (call.method == 'screenTurnedOn' || call.method == 'networkAvailable') {
        await handler.recoverActiveController(reason: call.method);
      }
    });
    return handler;
  }

  Future<void> _playSystemCommandTone(AudioSystemCommandFeedback feedback) async {
    try {
      await _platformChannel.invokeMethod<void>('playCommandTone', <String, Object?>{'kind': feedback.name});
    } on PlatformException {
      // Media commands remain usable when the optional cue cannot be played.
    } on MissingPluginException {
      // The Android engine may still be attaching its app-level channel.
    }
  }

  Future<void> _configureAudioSession() async {
    final session = _audioSession ??= await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    _interruptionSubscription ??= session.interruptionEventStream.listen((event) {
      if (event.begin) {
        unawaited(_pauseActivePlayback('audioFocus:${event.type.name}'));
      }
    });
    _becomingNoisySubscription ??= session.becomingNoisyEventStream.listen((_) {
      unawaited(_pauseActivePlayback('becomingNoisy'));
    });
  }

  Future<void> _synchronizeFocus(bool playing) async {
    _desiredAudioSessionActive = playing;
    final focusOperation = _audioFocusTail.then((_) => _applyDesiredAudioFocus());
    _audioFocusTail = focusOperation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await focusOperation;
  }

  Future<void> _applyDesiredAudioFocus() async {
    final session = _audioSession;
    if (session == null) return;
    while (_audioSessionActive != _desiredAudioSessionActive) {
      final desired = _desiredAudioSessionActive;
      if (desired == true) {
        final activated = await session.setActive(true);
        _audioSessionActive = activated;
        if (!activated) await _pauseActivePlayback('audioFocusDenied');
      } else {
        _audioSessionActive = false;
        await session.setActive(false);
      }
    }
  }

  Future<void> _pauseActivePlayback(String reason) async {
    final handler = _handlerFuture == null ? null : await _handlerFuture;
    await handler?.pauseActiveController(reason: reason);
  }
}

enum AudioSystemCommandFeedback { accepted, failed, boundary }

final class _AndroidAudioObserver extends AudioPlayerObserver {
  const _AndroidAudioObserver({required this.handler, required this.controller, required this.delegate});

  final MgReadAudioHandler handler;
  final AudioPlayerController controller;
  final AudioPlayerObserver? delegate;

  @override
  FutureOr<void> onSessionStarted(String collectionId) => delegate?.onSessionStarted(collectionId);

  @override
  FutureOr<void> onSessionEnded(String collectionId, AudioPlaybackProgress? progress) async {
    await handler.detach(controller);
    await delegate?.onSessionEnded(collectionId, progress);
  }

  @override
  FutureOr<void> onTrackChanged(AudioTrack track) => delegate?.onTrackChanged(track);

  @override
  FutureOr<void> onLifecycleChanged(AudioPlayerLifecycleState state, AudioPlaybackProgress? progress) =>
      delegate?.onLifecycleChanged(state, progress);

  @override
  FutureOr<void> onFailure(AudioPlayerFailure failure) => delegate?.onFailure(failure);

  @override
  FutureOr<void> onOperation(AudioPlayerOperationEvent event) => delegate?.onOperation(event);

  @override
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) => delegate?.onExitRequested(progress);
}

/// Projects the active controller into Android's MediaSession command surface.
///
/// This class is app-internal but intentionally testable without Android. The
/// platform service is still created only by [AndroidAudioBackgroundService].
final class MgReadAudioHandler extends BaseAudioHandler {
  AudioPlayerController? _controller;
  Future<void> Function(bool playing)? _synchronizeFocus;
  Future<void> Function()? _onSystemStop;
  FutureOr<void> Function(String stage)? _onPlatformEvent;
  Future<void> Function(AudioSystemCommandFeedback feedback)? _commandFeedback;
  Future<void> _systemCommandTail = Future<void>.value();
  final Set<String> _queuedSystemCommands = <String>{};

  Future<void> attach(
    AudioPlayerController controller, {
    required Future<void> Function(bool playing) synchronizeFocus,
    required Future<void> Function() onSystemStop,
    FutureOr<void> Function(String stage)? onPlatformEvent,
    Future<void> Function(AudioSystemCommandFeedback feedback)? commandFeedback,
  }) async {
    if (identical(_controller, controller)) return;
    await pauseActiveController();
    _controller?.removeListener(_publish);
    _controller = controller;
    _synchronizeFocus = synchronizeFocus;
    _onSystemStop = onSystemStop;
    _onPlatformEvent = onPlatformEvent;
    _commandFeedback = commandFeedback;
    controller.addListener(_publish);
    _publish();
  }

  Future<void> detach(AudioPlayerController controller) async {
    if (!identical(_controller, controller)) return;
    controller.removeListener(_publish);
    _controller = null;
    await _synchronizeFocus?.call(false);
    _synchronizeFocus = null;
    _onSystemStop = null;
    _onPlatformEvent = null;
    _commandFeedback = null;
    mediaItem.add(null);
    queue.add(const <MediaItem>[]);
    playbackState.add(PlaybackState());
  }

  Future<void> pauseActiveController({String? reason}) async {
    if (reason != null) await _notifyPlatformEvent(reason);
    await _controller?.pause();
  }

  Future<void> recoverActiveController({String? reason}) async {
    if (reason != null) await _notifyPlatformEvent(reason);
    await _controller?.recover();
  }

  Future<void> _notifyPlatformEvent(String stage) async {
    try {
      await _onPlatformEvent?.call(stage);
    } on Object {
      // Diagnostic callbacks never change media-session behavior.
    }
  }

  Future<void> _runSystemCommand({
    required String commandKey,
    required bool Function(AudioPlayerSnapshot snapshot) canRun,
    required Future<void> Function(AudioPlayerController controller) action,
    AudioSystemCommandFeedback rejectedFeedback = AudioSystemCommandFeedback.failed,
  }) async {
    final controller = _controller;
    if (controller == null) return;
    if (!_queuedSystemCommands.add(commandKey)) {
      await _sendCommandFeedback(AudioSystemCommandFeedback.failed);
      return;
    }
    final operation = _systemCommandTail.then<void>((_) async {
      if (!identical(_controller, controller) || !canRun(controller.snapshot)) {
        await _notifyPlatformEvent('systemCommand:$commandKey:rejected');
        await _sendCommandFeedback(rejectedFeedback);
        return;
      }
      await _notifyPlatformEvent('systemCommand:$commandKey:started');
      await _sendCommandFeedback(AudioSystemCommandFeedback.accepted);
      if (!identical(_controller, controller) || !canRun(controller.snapshot)) {
        await _notifyPlatformEvent('systemCommand:$commandKey:invalidated');
        await _sendCommandFeedback(rejectedFeedback);
        return;
      }
      final failureBefore = controller.snapshot.failure;
      try {
        await action(controller);
      } on Object {
        await _notifyPlatformEvent('systemCommand:$commandKey:failed');
        await _sendCommandFeedback(AudioSystemCommandFeedback.failed);
        return;
      }
      await _notifyPlatformEvent('systemCommand:$commandKey:returned');
      final failureAfter = controller.snapshot.failure;
      if (!_sameFailure(failureBefore, failureAfter) && failureAfter != null) {
        await _sendCommandFeedback(AudioSystemCommandFeedback.failed);
      }
    });
    _systemCommandTail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    try {
      await operation;
    } finally {
      _queuedSystemCommands.remove(commandKey);
    }
  }

  Future<void> _sendCommandFeedback(AudioSystemCommandFeedback feedback) async {
    try {
      await _commandFeedback?.call(feedback);
    } on Object {
      // Optional audio cues never block or fail a media command.
    }
  }

  bool _sameFailure(AudioPlayerFailure? left, AudioPlayerFailure? right) {
    if (identical(left, right)) return true;
    return left?.code == right?.code &&
        left?.location == right?.location &&
        left?.message == right?.message &&
        left?.debugDetail == right?.debugDetail;
  }

  void _publish() {
    final snapshot = _controller?.snapshot;
    if (snapshot == null) return;
    final systemQueueEntries = snapshot.queueEntries.where((item) => !item.isLocked).toList(growable: false);
    final items = systemQueueEntries.map(_mediaItemForQueueEntry).toList(growable: false);
    queue.add(items);
    final track = snapshot.currentTrack;
    mediaItem.add(track == null ? null : _mediaItemForTrack(track, duration: snapshot.duration));
    final queueIndex = track == null ? -1 : systemQueueEntries.indexWhere((item) => item.id == track.id);
    final systemPlaybackActive =
        snapshot.playbackDesired &&
        (snapshot.status == AudioPlayerStatus.loading || snapshot.playing || snapshot.buffering || snapshot.resourceLoading);
    final controls = <MediaControl>[
      if (snapshot.status == AudioPlayerStatus.ready && snapshot.canGoPrevious) MediaControl.skipToPrevious,
      snapshot.playbackDesired ? MediaControl.pause : MediaControl.play,
      if (snapshot.status == AudioPlayerStatus.ready && snapshot.canGoNext) MediaControl.skipToNext,
      MediaControl.stop,
    ];
    final compactControlCount = (controls.length - 1).clamp(1, 3);
    final processingState = switch (snapshot.status) {
      AudioPlayerStatus.loading => AudioProcessingState.loading,
      AudioPlayerStatus.ready when snapshot.buffering || snapshot.resourceLoading => AudioProcessingState.buffering,
      AudioPlayerStatus.ready when snapshot.completed => AudioProcessingState.completed,
      AudioPlayerStatus.ready => AudioProcessingState.ready,
      AudioPlayerStatus.error => AudioProcessingState.error,
    };
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: snapshot.status == AudioPlayerStatus.ready
            ? const <MediaAction>{MediaAction.seek, MediaAction.seekBackward, MediaAction.seekForward}
            : const <MediaAction>{},
        androidCompactActionIndices: List<int>.generate(compactControlCount, (index) => index, growable: false),
        processingState: processingState,
        playing: systemPlaybackActive,
        updatePosition: snapshot.position,
        bufferedPosition: snapshot.position,
        speed: snapshot.rate,
        queueIndex: queueIndex < 0 ? null : queueIndex,
      ),
    );
    unawaited(_synchronizeFocus?.call(systemPlaybackActive));
  }

  MediaItem _mediaItemForTrack(AudioTrack track, {required Duration duration}) => MediaItem(
    id: track.id,
    album: track.collectionTitle,
    title: track.title,
    artist: track.creator,
    artUri: track.artwork,
    duration: duration > Duration.zero ? duration : null,
  );

  MediaItem _mediaItemForQueueEntry(AudioQueueEntry entry) =>
      MediaItem(id: entry.id, title: entry.title, artist: entry.creator, artUri: entry.artwork);

  @override
  Future<void> play() => _runSystemCommand(
    commandKey: 'play',
    canRun: (snapshot) => !snapshot.playbackDesired,
    action: (controller) => controller.snapshot.status == AudioPlayerStatus.error ? controller.retry() : controller.play(),
  );

  @override
  Future<void> pause() =>
      _runSystemCommand(commandKey: 'pause', canRun: (snapshot) => snapshot.playbackDesired, action: (controller) => controller.pause());

  @override
  Future<void> stop() async {
    final controller = _controller;
    if (controller == null) return;
    await _runSystemCommand(
      commandKey: 'stop',
      canRun: (_) => identical(_controller, controller),
      action: (activeController) => activeController.pause(),
    );
    final onSystemStop = _onSystemStop;
    if (onSystemStop != null) await onSystemStop();
    if (identical(_controller, controller)) {
      await detach(controller);
    }
  }

  @override
  Future<void> seek(Duration position) => _runSystemCommand(
    commandKey: 'seek',
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready,
    action: (controller) => controller.seek(position),
  );

  @override
  Future<void> rewind() => _runSystemCommand(
    commandKey: 'rewind',
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready,
    action: (controller) => controller.seekBy(const Duration(seconds: -15)),
  );

  @override
  Future<void> fastForward() => _runSystemCommand(
    commandKey: 'fastForward',
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready,
    action: (controller) => controller.seekBy(const Duration(seconds: 15)),
  );

  @override
  Future<void> skipToNext() => _runSystemCommand(
    commandKey: 'next',
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready && snapshot.canGoNext,
    action: (controller) => controller.next(),
    rejectedFeedback: AudioSystemCommandFeedback.boundary,
  );

  @override
  Future<void> skipToPrevious() => _runSystemCommand(
    commandKey: 'previous',
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready && snapshot.canGoPrevious,
    action: (controller) => controller.previous(),
    rejectedFeedback: AudioSystemCommandFeedback.boundary,
  );

  @override
  Future<void> skipToQueueItem(int index) => _selectQueueItem(index);

  Future<void> _selectQueueItem(int index) {
    final controller = _controller;
    final entries = controller?.snapshot.queueEntries.where((item) => !item.isLocked).toList(growable: false);
    if (controller == null || entries == null || index < 0 || index >= entries.length) {
      return _sendCommandFeedback(AudioSystemCommandFeedback.boundary);
    }
    final trackId = entries[index].id;
    return _runSystemCommand(
      commandKey: 'queue:$trackId',
      canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready && snapshot.currentTrack?.id != trackId,
      action: (activeController) => activeController.selectQueueEntry(trackId),
    );
  }

  @override
  Future<void> setSpeed(double speed) => _controller?.setRate(speed) ?? Future<void>.value();
}
