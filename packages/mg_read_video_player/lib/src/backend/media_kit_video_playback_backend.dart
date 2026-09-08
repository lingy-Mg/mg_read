/// Default MediaKit implementation of the video playback backend.
///
/// Responsibilities:
/// - Own one fresh MediaKit player/controller/surface session per episode open.
/// - Open resolved URIs with request headers and forward current-session state.
/// - Render a raw MediaKit video surface without MediaKit-owned controls.
///
/// Notes:
/// - Native library bundles are deliberately selected by the host application.
/// - Fullscreen, orientation, PiP and system-awake behavior are disabled here.
/// - MediaKit's first-frame future is controller-lifetime scoped, so players are
///   never reused across episode opens.
/// - Open completion does not clear errors already delivered by native streams.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api/contracts.dart';
import '../api/models.dart';

/// Creates the package default backend without exposing MediaKit publicly.
VideoPlaybackBackend createMediaKitVideoPlaybackBackend({Uri? proxyUri}) =>
    MediaKitVideoPlaybackBackend(proxyUri: proxyUri);

/// MediaKit-backed implementation used by default in production hosts.
final class MediaKitVideoPlaybackBackend implements VideoPlaybackBackend {
  /// Prepares MediaKit without choosing a host native-library bundle.
  MediaKitVideoPlaybackBackend({this.proxyUri}) {
    MediaKit.ensureInitialized();
    _preparedSession = _MediaKitEpisodeSession(proxyUri);
  }

  /// Optional HTTP proxy sampled for this backend session.
  final Uri? proxyUri;

  final ValueNotifier<VideoPlaybackBackendState> _state =
      ValueNotifier<VideoPlaybackBackendState>(
        const VideoPlaybackBackendState(),
      );
  Future<void> _openQueue = Future<void>.value();
  Future<void>? _disposeFuture;
  _MediaKitEpisodeSession? _preparedSession;
  _MediaKitEpisodeSession? _session;
  int _openGeneration = 0;
  int _surfaceGeneration = 0;
  double _rate = 1;
  double _volume = 100;
  bool _disposed = false;

  VideoPlaybackBackendState get _value => _state.value;

  @override
  ValueListenable<VideoPlaybackBackendState> get state => _state;

  @override
  Widget buildSurface({required BoxFit fit, Key? key}) {
    final session = _session ?? _preparedSession;
    return KeyedSubtree(
      key: key,
      child: session == null
          ? SizedBox.expand(key: ValueKey<int>(_surfaceGeneration))
          : Video(
              key: ValueKey<int>(_surfaceGeneration),
              controller: session.controller,
              fit: fit,
              fill: const Color(0xFF050607),
              controls: NoVideoControls,
              wakelock: false,
              pauseUponEnteringBackgroundMode: false,
              resumeUponEnteringForegroundMode: false,
              onEnterFullscreen: _noPlatformFullscreen,
              onExitFullscreen: _noPlatformFullscreen,
            ),
    );
  }

  @override
  Future<void> open(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
  }) {
    _ensureActive();
    final generation = ++_openGeneration;
    _emit(
      VideoPlaybackBackendState(
        duration: episode.durationHint ?? Duration.zero,
        rate: _rate,
        volume: _volume,
        buffering: true,
      ),
    );

    final operation = _openQueue.then<void>(
      (_) => _openEpisode(
        episode,
        initialPosition: initialPosition,
        play: play,
        generation: generation,
      ),
    );
    _openQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _openEpisode(
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
    required int generation,
  }) async {
    if (!_isRequestedGeneration(generation)) return;
    final uri = episode.uri;
    if (uri == null) {
      throw StateError('The selected video episode has no playback resource.');
    }

    final prepared = _preparedSession;
    final session = prepared ?? _MediaKitEpisodeSession(proxyUri);
    _preparedSession = null;
    _bind(session, generation, episode);
    if (!_isRequestedGeneration(generation)) {
      await session.dispose();
      return;
    }

    final previous = _session;
    _session = session;
    if (prepared == null) _surfaceGeneration++;
    _emit(_value.copyWith(firstFrameReady: false, clearError: true));
    unawaited(_markFirstFrame(session, generation, episode));

    // VideoController initializes after a frame. This frame also detaches the
    // previous keyed Video subtree before its Player-owned notifiers are freed.
    await session.controllerReady;
    if (previous != null) await previous.dispose();
    if (!_isCurrent(session, generation)) return;

    try {
      await session.applyProxy();
      _debugPlaybackRequest('open', episode);
      await session.player.open(
        Media(
          uri,
          httpHeaders: episode.httpHeaders,
          start: initialPosition > Duration.zero ? initialPosition : null,
        ),
        // Let MediaKit leave its paused state as part of loading the media.
        // A separate play command can be lost while a newly attached native
        // video surface is still initializing.
        play: play,
      );
      if (!_isCurrent(session, generation)) return;

      await session.player.setRate(_rate);
      if (!_isCurrent(session, generation)) return;
      await session.player.setVolume(_volume);
      if (!_isCurrent(session, generation)) return;
      _emit(_value.copyWith(buffering: false));
    } on Object catch (error, stackTrace) {
      if (!_isCurrent(session, generation)) return;
      _debugPlaybackFailure('open-exception', episode, error);
      _emit(_value.copyWith(buffering: false));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  void _bind(
    _MediaKitEpisodeSession session,
    int generation,
    VideoEpisode episode,
  ) {
    session.subscriptions.addAll(<StreamSubscription<Object?>>[
      session.player.stream.playing.listen(
        (bool value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(playing: value),
        ),
      ),
      session.player.stream.position.listen(
        (Duration value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(position: value),
        ),
      ),
      session.player.stream.duration.listen(
        (Duration value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(duration: value),
        ),
      ),
      session.player.stream.buffering.listen(
        (bool value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(buffering: value),
        ),
      ),
      session.player.stream.buffer.listen(
        (Duration value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(bufferedPosition: value),
        ),
      ),
      session.player.stream.completed.listen(
        (bool value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(completed: value),
        ),
      ),
      session.player.stream.rate.listen(
        (double value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(rate: value),
        ),
      ),
      session.player.stream.volume.listen(
        (double value) => _updateFrom(
          session,
          generation,
          (state) => state.copyWith(volume: value),
        ),
      ),
      session.player.stream.error.listen((String value) {
        if (value.trim().isEmpty) return;
        final failure = _classifyStreamFailure(value, episode);
        _debugPlaybackFailure(
          'stream-error',
          episode,
          value,
          kind: failure.kind,
        );
        _updateFrom(
          session,
          generation,
          (state) => state.copyWith(
            errorMessage: failure.message,
            errorKind: failure.kind,
            buffering: false,
          ),
        );
      }),
    ]);
  }

  Future<void> _markFirstFrame(
    _MediaKitEpisodeSession session,
    int generation,
    VideoEpisode episode,
  ) async {
    try {
      final rendered = await session.waitForFirstFrame();
      if (!rendered || !_isCurrent(session, generation)) return;
      _emit(_value.copyWith(firstFrameReady: true));
    } on Object catch (error) {
      if (!_isCurrent(session, generation)) return;
      _debugPlaybackFailure('first-frame-exception', episode, error);
      _emit(
        _value.copyWith(
          errorMessage: 'The video engine could not render a frame.',
          errorKind: VideoPlaybackBackendErrorKind.unknown,
          buffering: false,
        ),
      );
    }
  }

  void _debugPlaybackRequest(String event, VideoEpisode episode) {
    if (!kDebugMode) return;
    debugPrint(
      'MgRead video backend [$event] '
      '${_debugResourceSummary(episode)}',
    );
  }

  _BackendStreamFailure _classifyStreamFailure(
    String error,
    VideoEpisode episode,
  ) {
    final proxy = proxyUri;
    final endpoint = proxy == null ? null : 'tcp://${proxy.host}:${proxy.port}';
    if (endpoint != null &&
        error.toLowerCase().contains(
          'connection to ${endpoint.toLowerCase()} failed',
        )) {
      return const _BackendStreamFailure(
        VideoPlaybackBackendErrorKind.proxyUnavailable,
        'The configured video proxy could not be reached.',
      );
    }
    final uri = Uri.tryParse(episode.uri ?? '');
    if (uri != null &&
        (uri.host.toLowerCase() == 'localhost' ||
            uri.host == '127.0.0.1' ||
            uri.host == '::1')) {
      return const _BackendStreamFailure(
        VideoPlaybackBackendErrorKind.runtimeResourceUnavailable,
        'The Runtime media resource could not be retrieved.',
      );
    }
    return const _BackendStreamFailure(
      VideoPlaybackBackendErrorKind.unknown,
      'The video playback engine could not open the media.',
    );
  }

  void _debugPlaybackFailure(
    String event,
    VideoEpisode episode,
    Object error, {
    VideoPlaybackBackendErrorKind? kind,
  }) {
    if (!kDebugMode) return;
    final detail = error.toString().replaceAll(RegExp(r'[\r\n]+'), ' ');
    final boundedDetail = detail.length <= 600
        ? detail
        : '${detail.substring(0, 600)}…';
    debugPrint(
      'MgRead video backend [$event] '
      '${_debugResourceSummary(episode)} '
      'errorType=${error.runtimeType}'
      '${kind == null ? '' : ' failure=${kind.name}'} '
      'error=$boundedDetail',
    );
  }

  String _debugResourceSummary(VideoEpisode episode) {
    final uri = Uri.tryParse(episode.uri ?? '');
    final host = uri?.host.toLowerCase();
    final resource = uri == null
        ? 'invalid'
        : host == 'localhost' || host == '127.0.0.1' || host == '::1'
        ? 'runtime-loopback'
        : uri.scheme == 'file'
        ? 'local-file'
        : 'remote-${uri.scheme.isEmpty ? 'unknown' : uri.scheme}';
    return 'resource=$resource headerCount=${episode.httpHeaders.length}';
  }

  void _updateFrom(
    _MediaKitEpisodeSession session,
    int generation,
    VideoPlaybackBackendState Function(VideoPlaybackBackendState) update,
  ) {
    if (!_isCurrent(session, generation)) return;
    _emit(update(_value));
  }

  bool _isRequestedGeneration(int generation) =>
      !_disposed && generation == _openGeneration;

  bool _isCurrent(_MediaKitEpisodeSession session, int generation) =>
      _isRequestedGeneration(generation) && identical(_session, session);

  _MediaKitEpisodeSession _activeSession() {
    _ensureActive();
    final session = _session;
    if (session == null) throw StateError('No video episode is open.');
    return session;
  }

  @override
  Future<void> play() => _activeSession().player.play();

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await _session?.player.pause();
  }

  @override
  Future<void> seek(Duration position) =>
      _activeSession().player.seek(position);

  @override
  Future<void> setRate(double rate) async {
    final session = _activeSession();
    await session.player.setRate(rate);
    if (_disposed || !identical(_session, session)) return;
    _rate = rate;
    _emit(_value.copyWith(rate: rate));
  }

  @override
  Future<void> setVolume(double volume) async {
    final session = _activeSession();
    await session.player.setVolume(volume);
    if (_disposed || !identical(_session, session)) return;
    _volume = volume;
    _emit(_value.copyWith(volume: volume));
  }

  @override
  Future<void> dispose() {
    final pending = _disposeFuture;
    if (pending != null) return pending;
    _disposed = true;
    _openGeneration++;
    final operation = _dispose();
    _disposeFuture = operation;
    return operation;
  }

  Future<void> _dispose() async {
    final session = _session;
    final prepared = _preparedSession;
    _preparedSession = null;
    _session = null;
    _surfaceGeneration++;
    try {
      if (session != null) await session.dispose();
      if (prepared != null && !identical(prepared, session)) {
        await prepared.dispose();
      }
    } finally {
      final lateSession = _session;
      _session = null;
      if (lateSession != null && !identical(lateSession, session)) {
        await lateSession.dispose();
      }
      _state.dispose();
    }
  }

  void _emit(VideoPlaybackBackendState value) {
    if (_disposed) return;
    _state.value = value;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Video playback backend is disposed.');
  }

  static Future<void> _noPlatformFullscreen() async {}
}

final class _BackendStreamFailure {
  const _BackendStreamFailure(this.kind, this.message);

  final VideoPlaybackBackendErrorKind kind;
  final String message;
}

final class _MediaKitEpisodeSession {
  _MediaKitEpisodeSession(this.proxyUri) {
    player = Player();
    controller = VideoController(player);
    controllerReady = WidgetsBinding.instance.endOfFrame;
  }

  late final Player player;
  final Uri? proxyUri;
  late final VideoController controller;
  late final Future<void> controllerReady;
  final List<StreamSubscription<Object?>> subscriptions =
      <StreamSubscription<Object?>>[];
  final Completer<void> _closed = Completer<void>();
  Future<void>? _disposeFuture;

  Future<bool> waitForFirstFrame() => Future.any<bool>(<Future<bool>>[
    controller.waitUntilFirstFrameRendered.then((_) => true),
    _closed.future.then((_) => false),
  ]);

  Future<void> applyProxy() async {
    final proxy = proxyUri;
    final platform = player.platform;
    if (proxy == null || platform is! NativePlayer) return;
    await platform.setProperty('http-proxy', proxy.toString());
    await platform.setProperty('demuxer-lavf-o', 'http_proxy=$proxy');
  }

  Future<void> dispose() {
    final pending = _disposeFuture;
    if (pending != null) return pending;
    final operation = _dispose();
    _disposeFuture = operation;
    return operation;
  }

  Future<void> _dispose() async {
    if (!_closed.isCompleted) _closed.complete();
    try {
      await controllerReady;
      await Future.wait<void>(
        subscriptions.map((subscription) => subscription.cancel()),
        eagerError: false,
      );
    } finally {
      subscriptions.clear();
      await player.dispose();
    }
  }
}
