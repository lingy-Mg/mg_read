/// Android foreground-media bridge for the route-owned audio player.
///
/// Responsibilities:
/// - Mirror one active [AudioPlayerController] into Android's media session.
/// - Configure spoken-audio focus, pause for interruptions/noisy output and
///   keep the app alive only while user-visible audio is playing.
///
/// Notes:
/// - The player package continues to own the queue, HTTP resources and UI.
/// - This bridge never persists a media URL, header, cookie or source state.
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

/// One process-wide Android media-session host for the active audio route.
final class AndroidAudioBackgroundService {
  AndroidAudioBackgroundService._();

  static final AndroidAudioBackgroundService instance =
      AndroidAudioBackgroundService._();

  Future<_MgReadAudioHandler>? _handlerFuture;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;
  AudioSession? _audioSession;
  bool? _audioSessionActive;

  /// Attaches [controller] before its session begins loading.
  ///
  /// Non-Android hosts retain the supplied observer unchanged; the player is
  /// still fully usable but has no Android foreground-service capability.
  Future<AudioPlayerObserver?> attach({
    required AudioPlayerController controller,
    AudioPlayerObserver? observer,
  }) async {
    if (!Platform.isAndroid) return observer;
    final handler = await (_handlerFuture ??= _initializeHandler());
    await _configureAudioSession();
    await handler.attach(controller, synchronizeFocus: _synchronizeFocus);
    return _AndroidAudioObserver(
      handler: handler,
      controller: controller,
      delegate: observer,
    );
  }

  Future<_MgReadAudioHandler> _initializeHandler() async {
    final handler = await AudioService.init(
      builder: _MgReadAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.mgread.mg_read.audio',
        androidNotificationChannelName: '音频播放',
        androidStopForegroundOnPause: true,
      ),
    );
    return handler as _MgReadAudioHandler;
  }

  Future<void> _configureAudioSession() async {
    final session = _audioSession ??= await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());
    _interruptionSubscription ??= session.interruptionEventStream.listen((
      event,
    ) {
      if (event.begin) unawaited(_pauseActivePlayback());
    });
    _becomingNoisySubscription ??= session.becomingNoisyEventStream.listen((_) {
      unawaited(_pauseActivePlayback());
    });
  }

  Future<void> _synchronizeFocus(bool playing) async {
    final session = _audioSession;
    if (session == null || _audioSessionActive == playing) return;
    if (playing) {
      final activated = await session.setActive(true);
      _audioSessionActive = activated;
      if (!activated) await _pauseActivePlayback();
      return;
    }
    _audioSessionActive = false;
    await session.setActive(false);
  }

  Future<void> _pauseActivePlayback() async {
    final handler = _handlerFuture == null ? null : await _handlerFuture;
    await handler?.pauseActiveController();
  }
}

final class _AndroidAudioObserver extends AudioPlayerObserver {
  const _AndroidAudioObserver({
    required this.handler,
    required this.controller,
    required this.delegate,
  });

  final _MgReadAudioHandler handler;
  final AudioPlayerController controller;
  final AudioPlayerObserver? delegate;

  @override
  FutureOr<void> onSessionStarted(String collectionId) =>
      delegate?.onSessionStarted(collectionId);

  @override
  FutureOr<void> onSessionEnded(
    String collectionId,
    AudioPlaybackProgress? progress,
  ) async {
    await handler.detach(controller);
    await delegate?.onSessionEnded(collectionId, progress);
  }

  @override
  FutureOr<void> onTrackChanged(AudioTrack track) =>
      delegate?.onTrackChanged(track);

  @override
  FutureOr<void> onLifecycleChanged(
    AudioPlayerLifecycleState state,
    AudioPlaybackProgress? progress,
  ) =>
      delegate?.onLifecycleChanged(state, progress);

  @override
  FutureOr<void> onFailure(AudioPlayerFailure failure) =>
      delegate?.onFailure(failure);

  @override
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) =>
      delegate?.onExitRequested(progress);
}

final class _MgReadAudioHandler extends BaseAudioHandler {
  AudioPlayerController? _controller;
  Future<void> Function(bool playing)? _synchronizeFocus;

  Future<void> attach(
    AudioPlayerController controller, {
    required Future<void> Function(bool playing) synchronizeFocus,
  }) async {
    if (identical(_controller, controller)) return;
    await pauseActiveController();
    _controller?.removeListener(_publish);
    _controller = controller;
    _synchronizeFocus = synchronizeFocus;
    controller.addListener(_publish);
    _publish();
  }

  Future<void> detach(AudioPlayerController controller) async {
    if (!identical(_controller, controller)) return;
    controller.removeListener(_publish);
    _controller = null;
    await _synchronizeFocus?.call(false);
    _synchronizeFocus = null;
    mediaItem.add(null);
    queue.add(const <MediaItem>[]);
    playbackState.add(PlaybackState());
  }

  Future<void> pauseActiveController() async => _controller?.pause();

  void _publish() {
    final snapshot = _controller?.snapshot;
    if (snapshot == null) return;
    final items = snapshot.queue.map(_mediaItemFor).toList(growable: false);
    queue.add(items);
    final track = snapshot.currentTrack;
    mediaItem.add(track == null ? null : _mediaItemFor(track));
    final processingState = switch (snapshot.status) {
      AudioPlayerStatus.loading => AudioProcessingState.loading,
      AudioPlayerStatus.ready when snapshot.buffering =>
        AudioProcessingState.buffering,
      AudioPlayerStatus.ready => AudioProcessingState.ready,
      AudioPlayerStatus.error => AudioProcessingState.error,
    };
    playbackState.add(
      PlaybackState(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          snapshot.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const <MediaAction>{
          MediaAction.seek,
          MediaAction.seekBackward,
          MediaAction.seekForward,
        },
        androidCompactActionIndices: const <int>[0, 1, 2],
        processingState: processingState,
        playing: snapshot.playing,
        updatePosition: snapshot.position,
        bufferedPosition: snapshot.position,
        speed: snapshot.rate,
        queueIndex: snapshot.currentTrack == null ? null : snapshot.currentIndex,
      ),
    );
    unawaited(_synchronizeFocus?.call(snapshot.playing));
  }

  MediaItem _mediaItemFor(AudioTrack track) => MediaItem(
    id: track.id,
    album: track.collectionTitle,
    title: track.title,
    artist: track.creator,
    artUri: track.artwork,
  );

  @override
  Future<void> play() => _controller?.play() ?? Future<void>.value();

  @override
  Future<void> pause() => _controller?.pause() ?? Future<void>.value();

  @override
  Future<void> stop() async {
    await pause();
    final controller = _controller;
    if (controller != null) await detach(controller);
  }

  @override
  Future<void> seek(Duration position) =>
      _controller?.seek(position) ?? Future<void>.value();

  @override
  Future<void> rewind() =>
      _controller?.seekBy(const Duration(seconds: -15)) ?? Future<void>.value();

  @override
  Future<void> fastForward() =>
      _controller?.seekBy(const Duration(seconds: 15)) ?? Future<void>.value();

  @override
  Future<void> skipToNext() => _controller?.next() ?? Future<void>.value();

  @override
  Future<void> skipToPrevious() =>
      _controller?.previous() ?? Future<void>.value();

  @override
  Future<void> skipToQueueItem(int index) =>
      _controller?.jump(index) ?? Future<void>.value();

  @override
  Future<void> setSpeed(double speed) =>
      _controller?.setRate(speed) ?? Future<void>.value();
}
