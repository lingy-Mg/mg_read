/// A muted, off-route video session prepared for a first-frame handoff.
///
/// Responsibilities:
/// - Resolve one exact content/group/episode selection and prime a backend.
/// - Keep the backend surface mountable until a host adopts the session.
///
/// Notes:
/// - Preparation performs no progress reads or writes and owns no host focus.
/// - The host must mount [buildSurface] while preparation is pending.
/// - A ready backend is transferred once to [VideoPlayerView].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'contracts.dart';
import 'models.dart';

/// Lifecycle of a staged video backend.
enum VideoPreparationStatus {
  /// No preparation has started.
  idle,

  /// Metadata, resource, open or first-frame work is in progress.
  preparing,

  /// The exact selection has produced a real first frame.
  ready,

  /// Preparation failed with [VideoPreparedSession.failure].
  failed,

  /// The backend was transferred to a player view.
  adopted,

  /// The staged session was closed by its owner.
  disposed,
}

/// One staged backend that can be adopted without reopening its media.
final class VideoPreparedSession extends ChangeNotifier {
  /// Creates a staged session for one exact selection.
  VideoPreparedSession({
    required VideoPlaybackBackendFactory backendFactory,
    required this.dataSource,
    required this.contentId,
    required this.groupId,
    required this.episodeId,
    required this.initialPosition,
    this.timeout = const Duration(seconds: 25),
  }) : _backend = backendFactory();

  /// Host-owned resolver used for metadata and transient episode resource.
  final VideoDataSource dataSource;

  /// Exact content identity requested by the host.
  final String contentId;

  /// Exact group identity requested by the host.
  final String groupId;

  /// Exact episode identity requested by the host.
  final String episodeId;

  /// Requested playback position.
  final Duration initialPosition;

  /// Maximum time allowed for metadata, resource, open, and first frame.
  final Duration timeout;

  final VideoPlaybackBackend _backend;
  VideoContent? _content;
  VideoEpisodeGroup? _group;
  VideoEpisode? _episode;
  VideoPlayerFailure? _failure;
  VideoPreparationStatus _status = VideoPreparationStatus.idle;
  bool _closed = false;
  bool _transferred = false;
  int _generation = 0;
  Completer<void>? _frameWaiter;

  /// Whether asynchronous preparation has started.
  bool get preparing => _status == VideoPreparationStatus.preparing;

  /// Whether a decoded first frame is available for handoff.
  bool get ready => isReady;

  /// Current lifecycle status.
  VideoPreparationStatus get status => _status;

  /// Whether preparation completed and this session can be adopted.
  bool get isReady => _status == VideoPreparationStatus.ready && !_closed;

  /// A safe failure description when preparation cannot be adopted.
  VideoPlayerFailure? get failure => _failure;

  /// Builds the backend's real video surface; mount it during preparation.
  Widget buildSurface({Key? key}) =>
      _backend.buildSurface(fit: BoxFit.contain, key: key);

  /// Resolves and opens the requested episode, then waits for a real frame.
  Future<void> prepare() async {
    if (_closed) throw StateError('Prepared session is closed.');
    if (preparing || isReady) return;
    if (_status == VideoPreparationStatus.failed) return;
    _status = VideoPreparationStatus.preparing;
    final generation = ++_generation;
    notifyListeners();
    try {
      await _prepare(generation).timeout(timeout);
    } on TimeoutException {
      _fail(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.playback,
          '预加载视频首帧超时',
          code: 'prepared_first_frame_timeout',
          location: '预加载视频',
        ),
      );
    } on VideoPlayerLoadException catch (error) {
      _fail(
        VideoPlayerFailure(
          VideoPlayerFailureKind.data,
          error.message,
          code: error.code,
          location: error.location,
        ),
      );
    } on Object {
      _fail(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.data,
          '预加载所选视频失败',
          code: 'prepared_session_failed',
          location: '预加载视频',
        ),
      );
    } finally {
      if (!_closed && _status == VideoPreparationStatus.preparing) {
        _status = VideoPreparationStatus.idle;
        notifyListeners();
      }
    }
  }

  Future<void> _prepare(int generation) async {
    var content = await dataSource.load(contentId);
    if (!_current(generation)) return;
    if (content.id != contentId) {
      throw const VideoPlayerLoadException(
        message: '视频内容标识不匹配',
        code: 'content_identity_mismatch',
        location: '校验视频内容标识',
      );
    }
    var group = _findGroup(content, groupId);
    if (group == null) {
      throw const VideoPlayerLoadException(
        message: '找不到请求的视频分组',
        code: 'prepared_group_missing',
        location: '校验视频分组',
      );
    }
    if (group.deferred) {
      if (dataSource is! VideoGroupDataSource) {
        throw const VideoPlayerLoadException(
          message: '数据源无法加载请求的视频分组',
          code: 'prepared_group_unavailable',
          location: '加载视频分组',
        );
      }
      group = await (dataSource as VideoGroupDataSource).loadGroup(
        contentId,
        groupId,
      );
      if (!_current(generation)) return;
      if (group.id != groupId) {
        throw const VideoPlayerLoadException(
          message: '数据源返回的视频分组不匹配',
          code: 'prepared_group_identity_mismatch',
          location: '校验视频分组',
        );
      }
      content = VideoContent(
        id: content.id,
        title: content.title,
        groups: [
          for (final item in content.groups) item.id == groupId ? group : item,
        ],
      );
    }
    final episode = _findEpisode(group, episodeId);
    if (episode == null) {
      throw const VideoPlayerLoadException(
        message: '找不到请求的视频选集',
        code: 'prepared_episode_missing',
        location: '校验视频选集',
      );
    }
    VideoEpisode playable = episode;
    if (!episode.hasPlaybackResource) {
      if (dataSource is! VideoEpisodeDataSource) {
        throw const VideoPlayerLoadException(
          message: '数据源没有提供所选视频的播放资源',
          code: 'episode_resource_missing',
          location: '解析所选视频资源',
        );
      }
      final resolved = await (dataSource as VideoEpisodeDataSource).loadEpisode(
        contentId,
        groupId: groupId,
        episodeId: episodeId,
      );
      if (!_current(generation)) return;
      if (resolved.id != episodeId || !resolved.hasPlaybackResource) {
        throw const VideoPlayerLoadException(
          message: '数据源返回的播放资源与所选视频不匹配',
          code: 'episode_resource_identity_mismatch',
          location: '校验所选视频资源',
        );
      }
      playable = VideoEpisode(
        id: episode.id,
        title: episode.title,
        uri: resolved.uri,
        httpHeaders: resolved.httpHeaders,
        durationHint: resolved.durationHint ?? episode.durationHint,
      );
    }
    if (!_current(generation)) return;
    _content = content;
    _group = group;
    _episode = playable;
    try {
      await _backend.setVolume(0);
      await _backend.open(
        playable,
        initialPosition: _clampPosition(initialPosition, playable.durationHint),
        play: true,
      );
    } on Object {
      _fail(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.playback,
          '预加载视频引擎无法打开所选资源',
          code: 'prepared_backend_open_failed',
          location: '预加载视频',
        ),
      );
      return;
    }
    if (!_current(generation)) return;
    await _waitForFirstFrame(generation);
    if (!_current(generation)) return;
    try {
      await _backend.pause();
    } on Object {
      _fail(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.playback,
          '预加载视频暂停失败',
          code: 'prepared_backend_pause_failed',
          location: '暂停预加载视频',
        ),
      );
      return;
    }
    if (!_current(generation)) return;
    _status = VideoPreparationStatus.ready;
  }

  Future<void> _waitForFirstFrame(int generation) async {
    if (_backend.state.value.firstFrameReady) return;
    final completer = Completer<void>();
    _frameWaiter = completer;
    void listener() {
      if (!_current(generation)) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('closed'));
        }
      } else if (_backend.state.value.firstFrameReady &&
          !completer.isCompleted) {
        completer.complete();
      }
    }

    _backend.state.addListener(listener);
    try {
      listener();
      await completer.future;
    } finally {
      _backend.state.removeListener(listener);
      if (identical(_frameWaiter, completer)) _frameWaiter = null;
    }
  }

  static VideoEpisodeGroup? _findGroup(VideoContent content, String id) {
    for (final group in content.groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  static VideoEpisode? _findEpisode(VideoEpisodeGroup group, String id) {
    for (final episode in group.episodes) {
      if (episode.id == id) return episode;
    }
    return null;
  }

  static Duration _clampPosition(Duration position, Duration? duration) {
    if (position < Duration.zero) return Duration.zero;
    if (duration != null && duration > Duration.zero && position > duration) {
      return duration;
    }
    return position;
  }

  bool _current(int generation) => !_closed && generation == _generation;

  void _fail(VideoPlayerFailure failure) {
    if (_closed) return;
    _generation++;
    final waiter = _frameWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _frameWaiter = null;
    _failure = failure;
    _status = VideoPreparationStatus.failed;
    notifyListeners();
  }

  /// Transfers the ready backend and selection to a newly keyed player view.
  @internal
  ({
    VideoPlaybackBackend backend,
    VideoContent content,
    VideoEpisodeGroup group,
    VideoEpisode episode,
  })
  takeForAdoption() {
    if (!ready || _content == null || _group == null || _episode == null) {
      throw StateError('Prepared session is not ready for adoption.');
    }
    if (_transferred) throw StateError('Prepared session was already adopted.');
    _transferred = true;
    _closed = true;
    _status = VideoPreparationStatus.adopted;
    notifyListeners();
    return (
      backend: _backend,
      content: _content!,
      group: _group!,
      episode: _episode!,
    );
  }

  @override
  void dispose() {
    if (_status == VideoPreparationStatus.disposed) return;
    if (!_closed) {
      _closed = true;
      _generation++;
    }
    final waiter = _frameWaiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _frameWaiter = null;
    _status = VideoPreparationStatus.disposed;
    if (!_transferred) unawaited(_backend.dispose());
    super.dispose();
  }
}
