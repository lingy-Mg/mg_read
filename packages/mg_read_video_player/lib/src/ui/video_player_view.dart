/// Embeddable video session and package-owned presentation.
///
/// Resolves content/progress and owns controls, lifecycle and persistence.
/// Platform state remains host-owned; generations reject stale async results.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/contracts.dart';
import '../api/controller.dart';
import '../api/models.dart';
import '../api/prepared_session.dart';
import '../backend/media_kit_video_playback_backend.dart';
import 'video_backend_command_queue.dart';
import 'video_episode_resolution.dart';
import 'video_episode_selection.dart';
import 'video_episode_sheet.dart';
import 'video_player_host_bridge.dart';
import 'video_player_shutdown.dart';
import 'video_player_keyboard.dart';
import 'video_player_stage.dart';
import 'video_tv_seek_gesture.dart';

part 'video_player_view_actions.dart';
part 'video_player_tv_actions.dart';
part 'video_player_view_delegate.dart';

/// A complete video player backed by host content and persistence ports.
final class VideoPlayerView extends StatefulWidget {
  /// Creates one independently owned video session.
  const VideoPlayerView({
    required this.contentId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.startupSession,
    this.preparedSession,
    this.controller,
    this.backendFactory = createMediaKitVideoPlaybackBackend,
    this.autoPlay = true,
    this.tvMode = false,
    this.autoAdvance = true,
    this.progressSaveThrottle = const Duration(seconds: 2),
    this.controlsAutoHideDelay = const Duration(seconds: 3),
    this.firstFrameTimeout = const Duration(seconds: 25),
    this.topRightAction,
    super.key,
  });

  /// Stable host-owned content identifier.
  final String contentId;

  /// Host-owned content resolver.
  final VideoDataSource dataSource;

  /// Host-owned durable playback state store.
  final VideoPlaybackStateStore stateStore;

  /// Optional event and platform-intent observer.
  ///
  /// When omitted, an exit request calls the nearest [Navigator.maybePop].
  /// When supplied, route exit is entirely host-owned.
  final VideoPlayerObserver? observer;

  /// Optional host-created clock that includes pre-route startup stages.
  final VideoStartupSession? startupSession;

  /// Optional already-opened backend to adopt without reopening its media.
  final VideoPreparedSession? preparedSession;

  /// Optional externally owned imperative controller.
  final VideoPlayerController? controller;

  /// Playback backend factory sampled at mount; tests may inject a fake.
  final VideoPlaybackBackendFactory backendFactory;

  /// Whether the restored episode should start automatically.
  final bool autoPlay;

  /// Enables remote-first controls without changing content or persistence.
  final bool tvMode;

  /// Whether natural completion should continue with the next ordered episode.
  final bool autoAdvance;

  /// Delay used to coalesce frequent position saves.
  final Duration progressSaveThrottle;

  /// Delay before playing chrome hides after interaction.
  final Duration controlsAutoHideDelay;

  /// Maximum wait after backend open before a missing first frame can retry.
  final Duration firstFrameTimeout;

  /// Optional compact host action placed in the pointer/touch top toolbar.
  ///
  /// Use an icon button. It shares chrome visibility and gesture locking, and
  /// is omitted in TV mode.
  final Widget? topRightAction;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

final class _VideoPlayerViewState extends State<VideoPlayerView>
    with _VideoPlayerViewDelegate
    implements VideoPlayerControllerDelegate {
  late VideoPlaybackBackend _backend;
  late VideoPlaybackBackendState _backendState;
  late VideoPlayerController _controller;
  late bool _ownsController;
  late AppLifecycleListener _lifecycleListener;
  late VideoStartupSession _startupSession;
  late VideoPlayerHostBridge _hostBridge;
  final FocusNode _focusNode = FocusNode(debugLabel: 'mg-read-video-player');
  final FocusNode _tvPlayFocus = FocusNode(debugLabel: 'video-tv-play');
  late final _tvSeekGesture = VideoTvSeekGesture(
    readPosition: () => _backendState.position,
    readDuration: () => _backendState.duration,
    onSeek: seek,
    onActivity: _showControls,
  );

  VideoContent? _content;
  VideoEpisodeGroup? _group;
  VideoEpisode? _episode;
  // Backend timestamps belong to the selection only after its open succeeds.
  bool _episodeOpened = false;
  String? _activeContentId;
  VideoPlaybackStateStore? _activeStateStore;
  VideoPlayerStatus _status = VideoPlayerStatus.loading;
  VideoPlayerFailure? _failure;
  VideoFitMode _fitMode = VideoFitMode.contain;
  bool _controlsVisible = true;
  bool _pointerOverControls = false;
  bool _fullscreenRequested = false;
  bool _controlsLocked = false;
  late bool _autoAdvance;
  late bool _playbackDesired;
  AppLifecycleState? _lifecycleState;
  bool _exitAuthorized = false;
  bool _exitRequested = false;
  bool _disposed = false;
  bool _progressDirty = false;
  double _volumeBeforeMute = 100;
  int _loadGeneration = 0;
  int _episodeGeneration = 0;
  int _reloadGeneration = 0;
  int _completionGeneration = 0;
  String? _reportedFirstFrameSelection;
  String? _reportedBackendError;
  Timer? _saveTimer;
  Timer? _controlsTimer;
  Timer? _firstFrameTimer;
  final VideoBackendCommandQueue _backendCommands = VideoBackendCommandQueue();
  Future<void> _saveQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleTvSeekFocus);
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? VideoPlayerController();
    _controller.attach(this, this);
    _startupSession = widget.startupSession ?? VideoStartupSession.create();
    _autoAdvance = widget.autoAdvance;
    _playbackDesired = widget.autoPlay;
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    _hostBridge = VideoPlayerHostBridge(widget.observer);
    if (widget.preparedSession case final prepared?) {
      final adopted = prepared.takeForAdoption();
      _backend = adopted.backend;
      _backendState = _backend.state.value;
      _backend.state.addListener(_handleBackendState);
      _content = adopted.content;
      _group = adopted.group;
      _episode = adopted.episode;
      _activeContentId = widget.contentId;
      _activeStateStore = widget.stateStore;
      _episodeOpened = true;
      _playbackDesired = widget.autoPlay;
      _status = VideoPlayerStatus.ready;
      _reportedFirstFrameSelection =
          '${adopted.group.id}\u0000${adopted.episode.id}';
    } else {
      _createBackend();
    }
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    if (widget.preparedSession == null) {
      unawaited(_loadSession());
    } else {
      unawaited(_resumeAdoptedBackend());
    }
  }

  @override
  void didUpdateWidget(covariant VideoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hostBridge.observer = widget.observer;
    if (oldWidget.tvMode != widget.tvMode) {
      _tvSeekGesture.cancel();
      _pointerOverControls = false;
    }
    if (oldWidget.controller != widget.controller) {
      _controller.detach(this);
      if (_ownsController) _controller.dispose();
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? VideoPlayerController();
      _controller.attach(this, this);
      _publish();
    }
    if (oldWidget.contentId != widget.contentId ||
        !identical(oldWidget.dataSource, widget.dataSource) ||
        !identical(oldWidget.stateStore, widget.stateStore)) {
      unawaited(_reloadSession());
    }
    if (oldWidget.autoAdvance != widget.autoAdvance) {
      _autoAdvance = widget.autoAdvance;
    }
  }

  void _createBackend() {
    _backend = widget.backendFactory();
    _backendState = _backend.state.value;
    _backend.state.addListener(_handleBackendState);
  }

  Future<void> _resumeAdoptedBackend() async {
    await _actionSetVolume(100);
    if (widget.autoPlay && !_disposed) await _actionPlay();
  }

  Future<void> _reloadSession() async {
    _tvSeekGesture.cancel();
    final generation = ++_reloadGeneration;
    _loadGeneration++;
    _episodeGeneration++;
    await _pauseBackend(reportFailure: false);
    await _flushProgress(force: true);
    if (_disposed || generation != _reloadGeneration) return;
    _startupSession = VideoStartupSession.create();
    await _loadSession();
  }

  Future<void> _loadSession() async {
    final generation = ++_loadGeneration;
    final contentId = widget.contentId;
    final dataSource = widget.dataSource;
    final stateStore = widget.stateStore;
    _episodeGeneration++;
    _saveTimer?.cancel();
    _saveTimer = null;
    _progressDirty = false;
    _playbackDesired = widget.autoPlay;
    _reportedFirstFrameSelection = null;
    _update(() {
      _status = VideoPlayerStatus.loading;
      _failure = null;
      _content = null;
      _episodeOpened = false;
      _group = null;
      _episode = null;
      _controlsVisible = !widget.tvMode;
      _exitAuthorized = false;
      _exitRequested = false;
      _controlsLocked = false;
    });

    _notifyStartup(
      VideoStartupPhase.sessionLoadStarted,
      state: VideoStartupState.started,
    );

    final progressFuture = _loadProgress(stateStore, contentId, generation);

    VideoContent content;
    try {
      content = await dataSource.load(contentId);
      _notifyStartup(
        VideoStartupPhase.contentReady,
        state: VideoStartupState.ready,
        resourceRole: VideoStartupResourceRole.content,
      );
    } on VideoPlayerLoadException catch (error) {
      _notifyStartup(
        VideoStartupPhase.contentReady,
        state: VideoStartupState.failed,
        resourceRole: VideoStartupResourceRole.content,
      );
      if (!_isCurrentLoad(generation)) return;
      _setFailure(
        VideoPlayerFailure(
          VideoPlayerFailureKind.data,
          error.message,
          code: error.code,
          location: error.location,
        ),
      );
      return;
    } on Object {
      _notifyStartup(
        VideoStartupPhase.contentReady,
        state: VideoStartupState.failed,
        resourceRole: VideoStartupResourceRole.content,
      );
      if (!_isCurrentLoad(generation)) return;
      _setFailure(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.data,
          '视频内容暂时无法打开',
          code: 'content_load_failed',
          location: '加载视频信息和选集',
        ),
      );
      return;
    }
    if (!_isCurrentLoad(generation)) return;
    if (content.id != contentId) {
      _setFailure(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.data,
          '视频内容标识不匹配',
          code: 'content_identity_mismatch',
          location: '校验视频内容标识',
        ),
      );
      return;
    }

    final progress = await progressFuture;
    if (!_isCurrentLoad(generation)) return;
    _activeContentId = contentId;
    _activeStateStore = stateStore;
    final restoredProgress = progress?.contentId == contentId ? progress : null;
    final restoredContent = await _actionRestoreGroup(
      content,
      dataSource,
      restoredProgress,
      generation,
    );
    if (restoredContent == null || !_isCurrentLoad(generation)) return;
    content = restoredContent;
    final selection =
        restoredVideoSelection(content.groups, restoredProgress) ??
        firstPlayableVideoSelection(content.groups);
    if (selection == null) {
      _update(() {
        _content = content;
        _status = VideoPlayerStatus.empty;
      });
      return;
    }

    final Duration initialPosition =
        restoredProgress?.groupId == selection.group.id &&
            restoredProgress?.episodeId == selection.episode.id
        ? restorableVideoPosition(restoredProgress)
        : Duration.zero;
    _content = content;
    await _openEpisode(
      selection.group,
      selection.episode,
      initialPosition: initialPosition,
      play: widget.autoPlay,
      flushCurrent: false,
      loadGeneration: generation,
    );
  }

  Future<void> _openEpisode(
    VideoEpisodeGroup group,
    VideoEpisode episode, {
    required Duration initialPosition,
    required bool play,
    required bool flushCurrent,
    int? loadGeneration,
  }) async {
    final int? generation = _actionBeginEpisodeOpening(loadGeneration);
    if (generation == null) return;
    if (flushCurrent) {
      await _pauseBackend(reportFailure: false);
      await _flushProgress(force: true);
    }
    if (!_isCurrentEpisode(generation) ||
        (loadGeneration != null && !_isCurrentLoad(loadGeneration))) {
      return;
    }
    _update(() {
      _episodeOpened = false;
      _group = group;
      _episode = episode;
    });

    _notifyStartup(
      VideoStartupPhase.episodeResolutionStarted,
      state: VideoStartupState.started,
      resourceRole: VideoStartupResourceRole.episode,
    );

    final resolution = await resolveVideoEpisode(
      dataSource: widget.dataSource,
      contentId: widget.contentId,
      group: group,
      episode: episode,
    );
    if (!_isCurrentEpisode(generation)) return;
    final failure = resolution.failure;
    if (failure != null) {
      _setFailure(failure);
      return;
    }
    final playableEpisode = resolution.episode!;
    _notifyStartup(
      VideoStartupPhase.episodeReady,
      state: VideoStartupState.ready,
      resourceRole: VideoStartupResourceRole.episode,
    );

    final backend = _backend;
    final Future<void> operation = _backendCommands.enqueue(() async {
      if (!_isCurrentEpisode(generation) || !identical(backend, _backend)) {
        return;
      }
      _notifyStartup(
        VideoStartupPhase.backendOpenStarted,
        state: VideoStartupState.started,
        resourceRole: VideoStartupResourceRole.backend,
      );
      await backend.open(
        playableEpisode,
        initialPosition: _clampPosition(
          initialPosition,
          playableEpisode.durationHint,
        ),
        play: play && _playbackDesired && _lifecycleAllowsPlayback,
      );
      if (_isCurrentEpisode(generation) && identical(backend, _backend)) {
        _notifyStartup(
          VideoStartupPhase.backendOpenCompleted,
          state: VideoStartupState.completed,
          resourceRole: VideoStartupResourceRole.backend,
        );
      }
    });
    try {
      await operation;
      if (!_isCurrentEpisode(generation) || !identical(backend, _backend)) {
        return;
      }
      if (_status == VideoPlayerStatus.failure) return;
      _episodeOpened = true;
      _update(() => _status = VideoPlayerStatus.ready);
      _scheduleFirstFrameTimeout(generation);
      _scheduleControlsHide();
    } on Object {
      if (!_isCurrentEpisode(generation) || !identical(backend, _backend)) {
        return;
      }
      _setFailure(
        const VideoPlayerFailure(
          VideoPlayerFailureKind.playback,
          '视频播放失败，请重试',
          code: 'episode_open_failed',
          location: '打开所选视频资源',
        ),
      );
    }
  }

  void _handleBackendState() {
    if (_disposed) return;
    final previous = _backendState;
    final next = _backend.state.value;
    _backendState = next;
    if (next.position != previous.position) {
      _progressDirty = true;
      _scheduleProgressSave();
    }
    if (previous.playing && !next.playing) {
      unawaited(_flushProgress(force: true));
    }
    if (next.playing != previous.playing) _scheduleControlsHide();
    final error = next.errorMessage?.trim();
    final errorId = next.errorKind?.name ?? error;
    if (error != null && error.isNotEmpty && errorId != _reportedBackendError) {
      _reportedBackendError = errorId;
      _setFailure(switch (next.errorKind) {
        VideoPlaybackBackendErrorKind.proxyUnavailable =>
          const VideoPlayerFailure(
            VideoPlayerFailureKind.playback,
            '视频代理无法连接，请启动代理服务；若已关闭视频代理，请退出播放器后重新打开。',
            code: 'video_proxy_unreachable',
            location: '连接视频代理',
          ),
        VideoPlaybackBackendErrorKind.runtimeResourceUnavailable =>
          const VideoPlayerFailure(
            VideoPlayerFailureKind.playback,
            '播放资源服务未能打开视频。请检查“来源 HTTP 代理”或更换视频线路；关闭代理后需退出播放器再重新打开。',
            code: 'runtime_resource_unavailable',
            location: '请求播放资源服务',
          ),
        _ => const VideoPlayerFailure(
          VideoPlayerFailureKind.playback,
          '播放引擎发生错误',
          code: 'backend_error',
          location: '视频播放引擎',
        ),
      });
      return;
    }
    _hostBridge.reportPlaybackActive(
      next.playing && _status != VideoPlayerStatus.failure,
    );
    if (_episodeOpened &&
        _status == VideoPlayerStatus.ready &&
        !previous.completed &&
        next.completed) {
      unawaited(_handlePlaybackCompleted());
    }
    final groupId = _group?.id;
    final episodeId = _episode?.id;
    final selectionId = groupId == null || episodeId == null
        ? null
        : '$groupId\u0000$episodeId';
    if (!previous.firstFrameReady &&
        next.firstFrameReady &&
        selectionId != null &&
        _reportedFirstFrameSelection != selectionId) {
      _reportedFirstFrameSelection = selectionId;
      _cancelFirstFrameTimeout();
      _notifyStartup(
        VideoStartupPhase.firstFrame,
        state: VideoStartupState.completed,
        resourceRole: VideoStartupResourceRole.surface,
      );
      _status = VideoPlayerStatus.ready;
      _rebuildAndPublish();
      final observer = widget.observer;
      if (observer != null) {
        _notify(() => observer.onFirstFrame(_snapshot));
      }
      return;
    }
    _rebuildAndPublish();
  }

  void _notifyStartup(
    VideoStartupPhase phase, {
    required VideoStartupState state,
    VideoStartupResourceRole? resourceRole,
  }) => _actionNotifyStartup(phase, state: state, resourceRole: resourceRole);

  void _scheduleFirstFrameTimeout(int generation) =>
      _actionScheduleFirstFrameTimeout(generation);

  void _cancelFirstFrameTimeout() => _actionCancelFirstFrameTimeout();

  Future<void> _selectAdjacentEpisode(int direction) =>
      _VideoPlayerViewActions(this)._selectAdjacentEpisode(direction);

  Future<void> _handlePlaybackCompleted() => _actionHandlePlaybackCompleted();

  Future<void> _pauseBackend({
    String code = 'transition_pause_failed',
    bool reportFailure = true,
  }) => _actionPauseBackend(code: code, reportFailure: reportFailure);

  void _scheduleProgressSave() => _actionScheduleProgressSave();

  Future<void> _flushProgress({bool force = false}) =>
      _actionFlushProgress(force: force);

  VideoPlaybackProgress? get _currentProgress => _actionCurrentProgress;

  void _showControls() => _actionShowControls();

  void _scheduleControlsHide() => _actionScheduleControlsHide();

  Future<void> _showEpisodes() => _actionShowEpisodes();

  Future<void> _retry() async {
    final group = _group;
    final episode = _episode;
    if (_content != null && group != null && episode != null) {
      final position = _currentProgress?.position ?? Duration.zero;
      _playbackDesired = widget.autoPlay;
      _startupSession = VideoStartupSession.create();
      await _openEpisode(
        group,
        episode,
        initialPosition: position,
        play: widget.autoPlay,
        flushCurrent: true,
      );
      return;
    }
    await _reloadSession();
  }

  void _setFailure(VideoPlayerFailure failure) {
    if (_disposed) return;
    _tvSeekGesture.cancel();
    _playbackDesired = false;
    _hostBridge.reportPlaybackActive(false);
    _cancelFirstFrameTimeout();
    unawaited(_pauseBackend(reportFailure: false));
    _update(() {
      _failure = failure;
      _status = VideoPlayerStatus.failure;
      _controlsVisible = true;
    });
    _notifyFailure(failure);
  }

  void _notifyFailure(VideoPlayerFailure failure) {
    final observer = widget.observer;
    if (observer != null) {
      unawaited(_notify(() => observer.onFailure(failure)));
    }
  }

  Future<void> _notify(FutureOr<void> Function() callback) async {
    try {
      await Future<void>.sync(callback);
    } on Object {
      // Host observers are optional telemetry/navigation sinks and must not
      // replace otherwise valid playback state.
    }
  }

  bool _isCurrentLoad(int generation) =>
      !_disposed && generation == _loadGeneration;

  bool _isCurrentEpisode(int generation) =>
      !_disposed && generation == _episodeGeneration;

  VideoPlayerSnapshot get _snapshot => VideoPlayerSnapshot(
    status: _status,
    contentId: widget.contentId,
    title: _content?.title ?? '',
    groups: _content?.groups ?? const <VideoEpisodeGroup>[],
    activeGroupId: _group?.id,
    activeEpisodeId: _episode?.id,
    position: _backendState.position,
    duration: _backendState.duration,
    playing: _backendState.playing,
    buffering: _backendState.buffering,
    bufferedPosition: _backendState.bufferedPosition,
    completed: _backendState.completed,
    firstFrameReady: _backendState.firstFrameReady,
    controlsVisible: _controlsVisible,
    rate: _backendState.rate,
    volume: _backendState.volume,
    fitMode: _fitMode,
    fullscreenRequested: _fullscreenRequested,
    hasPreviousEpisode:
        adjacentVideoSelection(
          _content?.groups ?? const <VideoEpisodeGroup>[],
          _group?.id,
          _episode?.id,
          direction: -1,
        ) !=
        null,
    hasNextEpisode:
        adjacentVideoSelection(
          _content?.groups ?? const <VideoEpisodeGroup>[],
          _group?.id,
          _episode?.id,
          direction: 1,
        ) !=
        null,
    autoAdvance: _autoAdvance,
    controlsLocked: _controlsLocked,
    enhancementMode: _backendState.enhancementMode,
    failure: _failure,
  );

  void _update(VoidCallback mutation) {
    if (_disposed || !mounted) return;
    setState(mutation);
    _publish();
  }

  void _rebuildAndPublish() {
    if (_disposed || !mounted) return;
    setState(() {});
    _publish();
  }

  void _publish() => _controller.publish(this, _snapshot);

  @override
  void dispose() {
    _hostBridge.dispose();
    _tvSeekGesture.dispose();
    _disposed = true;
    _loadGeneration++;
    _episodeGeneration++;
    _saveTimer?.cancel();
    _controlsTimer?.cancel();
    _firstFrameTimer?.cancel();
    _lifecycleListener.dispose();
    _focusNode.removeListener(_handleTvSeekFocus);
    _focusNode.dispose();
    _tvPlayFocus.dispose();
    _controller.detach(this);
    if (_ownsController) _controller.dispose();
    _backend.state.removeListener(_handleBackendState);
    final progress = _currentProgress;
    final backend = _backend;
    final saveTail = _saveQueue;
    final store = _activeStateStore ?? widget.stateStore;
    unawaited(
      shutdownVideoSession(
        backend: backend,
        store: store,
        saveTail: saveTail,
        progress: progress,
      ),
    );
    super.dispose();
  }
}

Duration _clampPosition(Duration position, Duration? duration) {
  if (position < Duration.zero) return Duration.zero;
  if (duration != null && duration > Duration.zero && position > duration) {
    return duration;
  }
  return position;
}
