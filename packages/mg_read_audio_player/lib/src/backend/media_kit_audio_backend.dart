/// Default MediaKit transport for the MgRead audio player package.
///
/// Responsibilities:
/// - Translate typed audio queues into MediaKit playlists with HTTP headers.
/// - Normalize MediaKit streams, including real completion, into one snapshot.
/// - Preserve active position and errors across append/open stream races.
/// - Wait for media readiness and observed position before completing a seek.
///
/// Notes:
/// - Native library selection remains the host application's responsibility.
/// - This file never imports video rendering or native library packages.
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart' hide AudioTrack;

import '../api/audio_contracts.dart';
import '../api/audio_models.dart';

/// MediaKit 1.2.6 implementation used when no fake backend is supplied.
final class AudioMediaKitPlaybackBackend implements AudioPlaybackBackend {
  AudioMediaKitPlaybackBackend({this.proxyUri}) {
    MediaKit.ensureInitialized();
    _player = Player();
    _snapshot = _fromPlayerState(_player.state);
    _listen();
  }

  late final Player _player;
  final Uri? proxyUri;
  late AudioPlaybackBackendSnapshot _snapshot;
  final StreamController<AudioPlaybackBackendSnapshot> _snapshots =
      StreamController<AudioPlaybackBackendSnapshot>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  int _errorRevision = 0;
  bool _disposed = false;

  @override
  AudioPlaybackBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<AudioPlaybackBackendSnapshot> get snapshots => _snapshots.stream;

  void _listen() {
    _subscriptions
      ..add(
        _player.stream.playing.listen(
          (value) => _emit(_snapshot.copyWith(playing: value)),
        ),
      )
      ..add(
        _player.stream.buffering.listen(
          (value) => _emit(_snapshot.copyWith(buffering: value)),
        ),
      )
      ..add(
        _player.stream.position.listen(
          (value) => _emit(_snapshot.copyWith(position: value)),
        ),
      )
      ..add(
        _player.stream.duration.listen(
          (value) => _emit(_snapshot.copyWith(duration: value)),
        ),
      )
      ..add(
        _player.stream.rate.listen(
          (value) => _emit(_snapshot.copyWith(rate: value)),
        ),
      )
      ..add(
        _player.stream.volume.listen(
          (value) =>
              _emit(_snapshot.copyWith(volume: (value / 100).clamp(0, 1))),
        ),
      )
      ..add(
        _player.stream.playlist.listen((value) {
          final changedTrack = value.index != _snapshot.currentIndex;
          _emit(
            _snapshot.copyWith(
              currentIndex: value.index,
              position: changedTrack ? Duration.zero : null,
              duration: changedTrack ? Duration.zero : null,
              completed: changedTrack ? false : null,
            ),
          );
        }),
      )
      ..add(
        _player.stream.completed.listen(
          (value) => _emit(_snapshot.copyWith(completed: value)),
        ),
      )
      ..add(
        _player.stream.error.listen((value) {
          _errorRevision++;
          _emit(_snapshot.copyWith(errorMessage: value));
        }),
      );
  }

  AudioPlaybackBackendSnapshot _fromPlayerState(PlayerState state) =>
      AudioPlaybackBackendSnapshot(
        playing: state.playing,
        buffering: state.buffering,
        position: state.position,
        duration: state.duration,
        rate: state.rate,
        volume: (state.volume / 100).clamp(0, 1),
        currentIndex: state.playlist.index,
        completed: state.completed,
      );

  void _emit(AudioPlaybackBackendSnapshot value) {
    if (_disposed) return;
    _snapshot = value;
    _snapshots.add(value);
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('Audio backend is disposed.');
  }

  @override
  Future<void> open(
    List<AudioTrack> tracks, {
    required int initialIndex,
    bool play = false,
  }) async {
    _ensureUsable();
    if (tracks.isEmpty || initialIndex < 0 || initialIndex >= tracks.length) {
      throw ArgumentError(
        'A non-empty queue and valid initialIndex are required.',
      );
    }
    final media = <Media>[
      for (final track in tracks)
        Media(
          track.resource.toString(),
          httpHeaders: track.httpHeaders,
          extras: <String, dynamic>{'audioTrackId': track.id},
        ),
    ];
    _emit(
      _snapshot.copyWith(
        currentIndex: initialIndex,
        position: Duration.zero,
        duration: Duration.zero,
        playing: false,
        buffering: true,
        completed: false,
        clearError: true,
      ),
    );
    final errorRevisionBeforeOpen = _errorRevision;
    await _applyProxy();
    await _player.open(Playlist(media, index: initialIndex), play: play);
    final opened = _fromPlayerState(_player.state);
    _emit(
      _errorRevision == errorRevisionBeforeOpen
          ? opened.copyWith(clearError: true)
          : opened.copyWith(errorMessage: _snapshot.errorMessage),
    );
  }

  Future<void> _applyProxy() async {
    final proxy = proxyUri;
    final platform = _player.platform;
    if (proxy == null || platform is! NativePlayer) return;
    await platform.setProperty('http-proxy', proxy.toString());
    await platform.setProperty('demuxer-lavf-o', 'http_proxy=$proxy');
  }

  @override
  Future<void> append(List<AudioTrack> tracks) async {
    _ensureUsable();
    for (final track in tracks) {
      await _player.add(
        Media(
          track.resource.toString(),
          httpHeaders: track.httpHeaders,
          extras: <String, dynamic>{'audioTrackId': track.id},
        ),
      );
    }
  }

  @override
  Future<void> play() {
    _ensureUsable();
    return _player.play();
  }

  @override
  Future<void> pause() {
    _ensureUsable();
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureUsable();
    // open() returns after submitting the playlist, before mpv loads the file.
    // A seek submitted in that gap is silently ignored by the native player.
    await _waitForSnapshot((value) => value.duration > Duration.zero);
    _ensureUsable();
    final target = position < Duration.zero
        ? Duration.zero
        : position > _snapshot.duration
        ? _snapshot.duration
        : position;
    // Subscribe before submitting the command: position events can arrive
    // either before or after its Future returns. Persistence must see the new
    // timestamp when the caller flushes immediately after dragging or exit.
    final observed = _waitForSnapshot(
      (value) => (value.position - target).abs() <= const Duration(seconds: 1),
    );
    // Attach an error handler immediately even if the command itself fails.
    observed.ignore();
    await _player.seek(target);
    await observed;
  }

  Future<void> _waitForSnapshot(
    bool Function(AudioPlaybackBackendSnapshot) accepts,
  ) async {
    _ensureUsable();
    if (accepts(_snapshot)) return;
    final ready = Completer<void>();
    final subscription = _snapshots.stream.listen(
      (value) {
        if (ready.isCompleted) return;
        try {
          if (value.errorMessage?.isNotEmpty ?? false) {
            throw StateError(value.errorMessage!);
          }
          if (accepts(value)) ready.complete();
        } on Object catch (error, stack) {
          ready.completeError(error, stack);
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(StateError('Audio backend closed during seek.'));
        }
      },
    );
    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> setRate(double rate) {
    _ensureUsable();
    return _player.setRate(rate.clamp(0.5, 3));
  }

  @override
  Future<void> setVolume(double volume) {
    _ensureUsable();
    return _player.setVolume(volume.clamp(0, 1) * 100);
  }

  @override
  Future<void> previous() {
    _ensureUsable();
    return _player.previous();
  }

  @override
  Future<void> next() {
    _ensureUsable();
    return _player.next();
  }

  @override
  Future<void> jump(int index) {
    _ensureUsable();
    return _player.jump(index);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player.dispose();
    await _snapshots.close();
  }
}
