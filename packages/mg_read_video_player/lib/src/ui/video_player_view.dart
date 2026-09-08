/// Embeddable video session and package-owned presentation.
///
/// Resolves content/progress and owns controls, lifecycle and persistence.
/// Platform state remains host-owned; generations reject stale async results.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/contracts.dart';
import '../api/controller.dart';
import '../api/models.dart';
import '../backend/media_kit_video_playback_backend.dart';
import 'video_backend_command_queue.dart';
import 'video_episode_resolution.dart';
import 'video_episode_selection.dart';
import 'video_episode_sheet.dart';
import 'video_player_host_bridge.dart';
import 'video_player_shutdown.dart';
import 'video_player_keyboard.dart';
import 'video_player_stage.dart';

part 'video_player_view_actions.dart';

/// A complete video player backed by host content and persistence ports.
final class VideoPlayerView extends StatefulWidget {
  /// Creates one independently owned video session.
  const VideoPlayerView({
    required this.contentId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.startupSession,
    this.controller,
    this.backendFactory = createMediaKitVideoPlaybackBackend,
    this.autoPlay = true,
    this.autoAdvance = true,
    this.progressSaveThrottle = const Duration(seconds: 2),
    this.controlsAutoHideDelay = const Duration(seconds: 3),
    this.firstFrameTimeout = const Duration(seconds: 25),
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

  /// Optional externally owned imperative controller.
  final VideoPlayerController? controller;

  /// Playback backend factory sampled when the view is first mounted.
  ///
  /// Tests should inject a deterministic fake and remount to replace it.
  final VideoPlaybackBackendFactory backendFactory;

  /// Whether the restored episode should start automatically.
  final bool autoPlay;

  /// Whether natural completion should continue with the next ordered episode.
  final bool autoAdvance;

  /// Delay used to coalesce frequent position saves.
  final Duration progressSaveThrottle;

  /// Delay before playing chrome hides after interaction.
  final Duration controlsAutoHideDelay;

  /// Maximum wait after backend open before a missing first frame can retry.
  final Duration firstFrameTimeout;

  @override
  State<VideoPlayerView> createState() => _VideoPlayerViewState();
}

final class _VideoPlayerViewState extends State<VideoPlayerView>
    implements VideoPlayerControllerDelegate {
  late VideoPlaybackBackend _backend;
  late VideoPlaybackBackendState _backendState;
  late VideoPlayerController _controller;
  late bool _ownsController;
  late AppLifecycleListener _lifecycleListener;
  late VideoStartupSession _startupSession;
  late VideoPlayerHostBridge _hostBridge;
  final FocusNode _focusNode = FocusNode(debugLabel: 'mg-read-video-player');

  VideoContent? _content;
  VideoEpisodeGroup? _group;
  VideoEpisode? _episode;
  String? _activeContentId;
  VideoPlaybackStateStore? _activeStateStore;
  VideoPlayerStatus _status = VideoPlayerStatus.loading;
  VideoPlayerFailure? _failure;
  VideoFitMode _fitMode = VideoFitMode.contain;
  bool _controlsVisible = true;
  bool _fullscreenRequested = false;
  bool _controlsLocked = false;
  late bool _autoAdvance;
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
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? VideoPlayerController();
    _controller.attach(this, this);
    _startupSession = widget.startupSession ?? VideoStartupSession.create();
    _autoAdvance = widget.autoAdvance;
    _hostBridge = VideoPlayerHostBridge(widget.observer);
    _createBackend();
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    unawaited(_loadSession());
  }

  @override
  void didUpdateWidget(covariant VideoPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hostBridge.observer = widget.observer;
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

  Future<void> _reloadSession() async {
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
    _reportedFirstFrameSelection = null;
    _update(() {
      _status = VideoPlayerStatus.loading;
      _failure = null;
      _content = null;
      _group = null;
      _episode = null;
      _controlsVisible = true;
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
    if (flushCurrent) {
      await _pauseBackend(reportFailure: false);
      await _flushProgress(force: true);
    }
    if (_disposed ||
        (loadGeneration != null && !_isCurrentLoad(loadGeneration))) {
      return;
    }
    final generation = ++_episodeGeneration;
    _cancelFirstFrameTimeout();
    _completionGeneration = 0;
    _reportedFirstFrameSelection = null;
    _reportedBackendError = null;
    _update(() {
      _group = group;
      _episode = episode;
      _status = VideoPlayerStatus.loading;
      _failure = null;
      _controlsVisible = true;
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
        play: play,
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
    if (!previous.completed && next.completed) {
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

  Future<VideoPlaybackProgress?> _loadProgress(
    VideoPlaybackStateStore stateStore,
    String contentId,
    int generation,
  ) async {
    try {
      final progress = await stateStore.load(contentId);
      if (_isCurrentLoad(generation)) {
        _notifyStartup(
          VideoStartupPhase.progressReady,
          state: VideoStartupState.ready,
          resourceRole: VideoStartupResourceRole.progress,
        );
      }
      return progress;
    } on Object {
      if (_isCurrentLoad(generation)) {
        _notifyStartup(
          VideoStartupPhase.progressReady,
          state: VideoStartupState.failed,
          resourceRole: VideoStartupResourceRole.progress,
        );
        _notifyFailure(
          const VideoPlayerFailure(
            VideoPlayerFailureKind.persistence,
            '播放进度恢复失败，将从头开始',
            code: 'progress_load_failed',
            location: '恢复播放进度',
          ),
        );
      }
      return null;
    }
  }

  void _notifyStartup(
    VideoStartupPhase phase, {
    required VideoStartupState state,
    VideoStartupResourceRole? resourceRole,
  }) => _actionNotifyStartup(phase, state: state, resourceRole: resourceRole);

  void _scheduleFirstFrameTimeout(int generation) =>
      _actionScheduleFirstFrameTimeout(generation);

  void _cancelFirstFrameTimeout() => _actionCancelFirstFrameTimeout();

  @override
  Future<void> play() => _actionPlay();

  @override
  Future<void> pause() => _actionPause();

  @override
  Future<void> playOrPause() => _actionPlayOrPause();

  @override
  Future<void> seek(Duration position) => _actionSeek(position);

  @override
  Future<void> skip(Duration delta) =>
      _actionSeek(_backendState.position + delta);

  @override
  Future<void> setRate(double rate) => _actionSetRate(rate);

  @override
  Future<void> setVolume(double volume) => _actionSetVolume(volume);

  @override
  Future<void> toggleMute() => setVolume(
    _backendState.volume > 0 ? 0 : _volumeBeforeMute.clamp(1, 100).toDouble(),
  );

  @override
  Future<void> replay() => _actionReplay();

  @override
  Future<void> playPreviousEpisode() => _actionPlayPreviousEpisode();

  @override
  Future<void> playNextEpisode() => _selectAdjacentEpisode(1);

  @override
  Future<void> setAutoAdvance(bool enabled) => _actionSetAutoAdvance(enabled);

  @override
  Future<void> setControlsLocked(bool locked) =>
      _actionSetControlsLocked(locked);

  @override
  Future<void> selectEpisode(String groupId, String episodeId) =>
      _actionSelectEpisode(groupId, episodeId);

  Future<void> _selectAdjacentEpisode(int direction) =>
      _VideoPlayerViewActions(this)._selectAdjacentEpisode(direction);

  Future<void> _handlePlaybackCompleted() => _actionHandlePlaybackCompleted();

  @override
  Future<void> cycleFitMode() => _actionCycleFitMode();

  @override
  Future<void> toggleControls() => _actionToggleControls();

  void _handleInteractionStart() {
    _controlsTimer?.cancel();
    if (!_controlsVisible) _update(() => _controlsVisible = true);
  }

  void _handleInteractionEnd() => _scheduleControlsHide();

  @override
  Future<void> requestFullscreen(bool fullscreen) =>
      _actionRequestFullscreen(fullscreen);

  @override
  Future<void> requestExit() => _actionRequestExit();

  Future<void> _pauseBackend({
    String code = 'transition_pause_failed',
    bool reportFailure = true,
  }) => _actionPauseBackend(code: code, reportFailure: reportFailure);

  void _scheduleProgressSave() => _actionScheduleProgressSave();

  Future<void> _flushProgress({bool force = false}) =>
      _actionFlushProgress(force: force);

  VideoPlaybackProgress? get _currentProgress => _actionCurrentProgress;

  void _handleLifecycle(AppLifecycleState state) {
    if (pausesVideoForLifecycle(state)) {
      unawaited(_actionPauseForBackground());
    }
  }

  void _showControls() => _actionShowControls();

  void _scheduleControlsHide() => _actionScheduleControlsHide();

  Future<void> _showEpisodes() => _actionShowEpisodes();

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) =>
      handleVideoPlayerKeyEvent(event, this, _snapshot);

  Future<void> _retry() async {
    _reportedBackendError = null;
    await _reloadSession();
  }

  void _setFailure(VideoPlayerFailure failure) {
    if (_disposed) return;
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
  Widget build(BuildContext context) => VideoPlayerStage(
    backend: _backend,
    snapshot: _snapshot,
    focusNode: _focusNode,
    exitAuthorized: _exitAuthorized,
    onPopAttempt: () => unawaited(requestExit()),
    onKeyEvent: _handleKey,
    onToggleControls: toggleControls,
    onRetry: _retry,
    onExit: requestExit,
    onPlayOrPause: playOrPause,
    onSeek: seek,
    onRate: setRate,
    onVolume: setVolume,
    onReplay: replay,
    onPreviousEpisode: playPreviousEpisode,
    onNextEpisode: playNextEpisode,
    onAutoAdvance: setAutoAdvance,
    onControlsLocked: setControlsLocked,
    onInteractionStart: _handleInteractionStart,
    onInteractionEnd: _handleInteractionEnd,
    onFit: cycleFitMode,
    onEpisodes: _showEpisodes,
    onFullscreen: requestFullscreen,
    onReadBrightness: _hostBridge.readBrightness,
    onBrightness: _hostBridge.setBrightness,
  );

  @override
  void dispose() {
    _hostBridge.dispose();
    _disposed = true;
    _loadGeneration++;
    _episodeGeneration++;
    _saveTimer?.cancel();
    _controlsTimer?.cancel();
    _firstFrameTimer?.cancel();
    _lifecycleListener.dispose();
    _focusNode.dispose();
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
