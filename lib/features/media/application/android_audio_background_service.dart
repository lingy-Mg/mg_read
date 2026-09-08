/// Android foreground-media bridge for the app-global audio player.
///
/// Responsibilities:
/// - Mirror one active [AudioPlayerController] into Android's media session.
/// - Configure spoken-audio focus and pause for interruptions/noisy output.
/// - Keep the media foreground service alive for the active session so a
///   Bluetooth or lock-screen play command can resume while the app is hidden.
///
/// Notes:
/// - The player package continues to own the queue, HTTP resources and UI.
/// - This bridge coordinates the active media session with Android.
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
    AudioPlayerObserver? observer,
  }) async {
    if (!Platform.isAndroid) return observer;
    final handler = await (_handlerFuture ??= _initializeHandler());
    await _configureAudioSession();
    await handler.attach(
      controller,
      synchronizeFocus: _synchronizeFocus,
      onSystemStop: onSystemStop,
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
      if (call.method == 'screenTurnedOn') {
        await handler.recoverActiveController();
      }
    });
    return handler;
  }

  Future<void> _playSystemCommandTone() async {
    try {
      await _platformChannel.invokeMethod<void>('playCommandTone');
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
      if (event.begin) unawaited(_pauseActivePlayback());
    });
    _becomingNoisySubscription ??= session.becomingNoisyEventStream.listen((_) {
      unawaited(_pauseActivePlayback());
    });
  }

  Future<void> _synchronizeFocus(bool playing) async {
    _desiredAudioSessionActive = playing;
    final operation = _audioFocusTail.then((_) => _applyDesiredAudioFocus());
    _audioFocusTail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await operation;
  }

  Future<void> _applyDesiredAudioFocus() async {
    final session = _audioSession;
    if (session == null) return;
    while (_audioSessionActive != _desiredAudioSessionActive) {
      final desired = _desiredAudioSessionActive;
      if (desired == true) {
        final activated = await session.setActive(true);
        _audioSessionActive = activated;
        if (!activated) await _pauseActivePlayback();
      } else {
        _audioSessionActive = false;
        await session.setActive(false);
      }
    }
  }

  Future<void> _pauseActivePlayback() async {
    final handler = _handlerFuture == null ? null : await _handlerFuture;
    await handler?.pauseActiveController();
  }
}

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
  Future<void> Function()? _commandFeedback;

  Future<void> attach(
    AudioPlayerController controller, {
    required Future<void> Function(bool playing) synchronizeFocus,
    required Future<void> Function() onSystemStop,
    Future<void> Function()? commandFeedback,
  }) async {
    if (identical(_controller, controller)) return;
    await pauseActiveController();
    _controller?.removeListener(_publish);
    _controller = controller;
    _synchronizeFocus = synchronizeFocus;
    _onSystemStop = onSystemStop;
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
    _commandFeedback = null;
    mediaItem.add(null);
    queue.add(const <MediaItem>[]);
    playbackState.add(PlaybackState());
  }

  Future<void> pauseActiveController() async => _controller?.pause();

  Future<void> recoverActiveController() async => _controller?.recover();

  Future<void> _runSystemCommand({
    required bool Function(AudioPlayerSnapshot snapshot) canRun,
    required Future<void> Function(AudioPlayerController controller) action,
  }) async {
    final controller = _controller;
    if (controller == null || !canRun(controller.snapshot)) return;
    try {
      await _commandFeedback?.call();
    } on Object {
      // A cue is acknowledgement only and never blocks the media command.
    }
    await action(controller);
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
    final controls = <MediaControl>[
      if (snapshot.canGoPrevious) MediaControl.skipToPrevious,
      snapshot.playing ? MediaControl.pause : MediaControl.play,
      if (snapshot.canGoNext) MediaControl.skipToNext,
      MediaControl.stop,
    ];
    final compactControlCount = (controls.length - 1).clamp(1, 3);
    final processingState = switch (snapshot.status) {
      AudioPlayerStatus.loading => AudioProcessingState.loading,
      AudioPlayerStatus.ready when snapshot.buffering => AudioProcessingState.buffering,
      AudioPlayerStatus.ready => AudioProcessingState.ready,
      AudioPlayerStatus.error => AudioProcessingState.error,
    };
    playbackState.add(
      PlaybackState(
        controls: controls,
        systemActions: const <MediaAction>{MediaAction.seek, MediaAction.seekBackward, MediaAction.seekForward},
        androidCompactActionIndices: List<int>.generate(compactControlCount, (index) => index, growable: false),
        processingState: processingState,
        playing: snapshot.playing,
        updatePosition: snapshot.position,
        bufferedPosition: snapshot.position,
        speed: snapshot.rate,
        queueIndex: queueIndex < 0 ? null : queueIndex,
      ),
    );
    unawaited(_synchronizeFocus?.call(snapshot.playing));
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
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready && !snapshot.playing,
    action: (controller) => controller.play(),
  );

  @override
  Future<void> pause() => _runSystemCommand(
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready && snapshot.playing,
    action: (controller) => controller.pause(),
  );

  @override
  Future<void> stop() async {
    final controller = _controller;
    if (controller == null) return;
    await _runSystemCommand(canRun: (_) => identical(_controller, controller), action: (activeController) => activeController.pause());
    final onSystemStop = _onSystemStop;
    if (onSystemStop != null) await onSystemStop();
    if (identical(_controller, controller)) {
      await detach(controller);
    }
  }

  @override
  Future<void> seek(Duration position) => _controller?.seek(position) ?? Future<void>.value();

  @override
  Future<void> rewind() => _runSystemCommand(
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready,
    action: (controller) => controller.seekBy(const Duration(seconds: -15)),
  );

  @override
  Future<void> fastForward() => _runSystemCommand(
    canRun: (snapshot) => snapshot.status == AudioPlayerStatus.ready,
    action: (controller) => controller.seekBy(const Duration(seconds: 15)),
  );

  @override
  Future<void> skipToNext() => _runSystemCommand(canRun: (snapshot) => snapshot.canGoNext, action: (controller) => controller.next());

  @override
  Future<void> skipToPrevious() =>
      _runSystemCommand(canRun: (snapshot) => snapshot.canGoPrevious, action: (controller) => controller.previous());

  @override
  Future<void> skipToQueueItem(int index) => _selectQueueItem(index);

  Future<void> _selectQueueItem(int index) {
    final controller = _controller;
    final entries = controller?.snapshot.queueEntries.where((item) => !item.isLocked).toList(growable: false);
    if (controller == null || entries == null || index < 0 || index >= entries.length) {
      return Future<void>.value();
    }
    final trackId = entries[index].id;
    return _runSystemCommand(
      canRun: (snapshot) => snapshot.currentTrack?.id != trackId,
      action: (activeController) => activeController.selectQueueEntry(trackId),
    );
  }

  @override
  Future<void> setSpeed(double speed) => _controller?.setRate(speed) ?? Future<void>.value();
}
