/// App-root host for source audio that survives page navigation.
///
/// Responsibilities:
/// - Mount one audio player for the full lifetime of global playback.
/// - Collapse the full player into an in-app mini player without disposing it.
/// - Ask whether to continue on exit and optionally persist that answer.
///
/// Notes:
/// - Android recovery also uses the system media notification; Windows relies
///   on this app-global mini player after its window is restored.
/// - No system overlay permission is requested on either platform.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';

import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/android_audio_background_service.dart';
import 'package:mg_read/features/media/application/source_audio_playback_coordinator.dart';
import 'package:mg_read/features/media/application/source_audio_playback_lifecycle.dart';
import 'package:mg_read/features/media/application/source_audio_playlist_data_source.dart';
import 'package:mg_read/features/media/application/transient_source_audio_playback_state_store.dart';
import 'package:mg_read/features/media/presentation/media_entry_cover.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// Owns a transparent local Navigator for playback above the app router.
///
/// [MaterialApp.builder] is above the router's Navigator. Mounting the playback
/// host there directly leaves tooltips without an [Overlay] and bottom sheets
/// without a [Navigator]. The local route is non-opaque so routed app content
/// remains visible whenever playback is minimized.
final class SourceAudioPlaybackNavigator extends ConsumerStatefulWidget {
  const SourceAudioPlaybackNavigator({required this.backButtonDispatcher, super.key});

  final BackButtonDispatcher backButtonDispatcher;

  @override
  ConsumerState<SourceAudioPlaybackNavigator> createState() => _SourceAudioPlaybackNavigatorState();
}

final class _SourceAudioPlaybackNavigatorState extends ConsumerState<SourceAudioPlaybackNavigator> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'sourceAudioPlaybackNavigator');
  Offset? _miniPlayerPosition;

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(sourceAudioPlaybackCoordinatorProvider);
    if (!playback.isActive) return const SizedBox.shrink();
    final coordinator = ref.read(sourceAudioPlaybackCoordinatorProvider.notifier);
    final minimized = playback.presentation == SourceAudioPresentation.minimized;
    final controller = coordinator.attachedController;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          ignoring: minimized,
          child: HeroControllerScope.none(
            child: Navigator(
              key: _navigatorKey,
              onGenerateRoute: (settings) => PageRouteBuilder<void>(
                settings: settings,
                opaque: false,
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (context, animation, secondaryAnimation) =>
                    SourceAudioPlaybackHost(backButtonDispatcher: widget.backButtonDispatcher, playbackNavigatorKey: _navigatorKey),
              ),
            ),
          ),
        ),
        if (minimized && controller != null)
          _SourceAudioMiniOverlay(
            controller: controller,
            initialPosition: _miniPlayerPosition,
            onPositionChanged: (position) => _miniPlayerPosition = position,
            onExpand: coordinator.expand,
            onStop: () => unawaited(coordinator.stop(sessionId: playback.sessionId)),
          ),
      ],
    );
  }
}

/// Renders the active playback above the router while keeping it route-free.
final class SourceAudioPlaybackHost extends ConsumerWidget {
  const SourceAudioPlaybackHost({required this.backButtonDispatcher, required this.playbackNavigatorKey, super.key});

  final BackButtonDispatcher backButtonDispatcher;
  final GlobalKey<NavigatorState> playbackNavigatorKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sourceAudioPlaybackCoordinatorProvider);
    if (!state.isActive) return const SizedBox.shrink();
    return _ActiveSourceAudioPlaybackHost(
      key: ValueKey<int>(state.sessionId!),
      sessionId: state.sessionId!,
      request: state.request!,
      presentation: state.presentation,
      backButtonDispatcher: backButtonDispatcher,
      playbackNavigatorKey: playbackNavigatorKey,
    );
  }
}

final class _ActiveSourceAudioPlaybackHost extends ConsumerStatefulWidget {
  const _ActiveSourceAudioPlaybackHost({
    required this.sessionId,
    required this.request,
    required this.presentation,
    required this.backButtonDispatcher,
    required this.playbackNavigatorKey,
    super.key,
  });

  final int sessionId;
  final SourceAudioPlaybackRequest request;
  final SourceAudioPresentation presentation;
  final BackButtonDispatcher backButtonDispatcher;
  final GlobalKey<NavigatorState> playbackNavigatorKey;

  @override
  ConsumerState<_ActiveSourceAudioPlaybackHost> createState() => _ActiveSourceAudioPlaybackHostState();
}

final class _ActiveSourceAudioPlaybackHostState extends ConsumerState<_ActiveSourceAudioPlaybackHost> {
  late final AudioPlayerController _controller;
  SourceAudioPlaybackLifecycle? _playbackLifecycle;
  _AudioPlayerSetup? _setup;
  Object? _setupFailure;
  bool _playerPresented = false, _rememberExitChoice = false;
  Completer<_AudioExitDecision?>? _exitDecision;
  int _generation = 0;
  late final SourceAudioPlaybackCoordinator _coordinator;
  late ChildBackButtonDispatcher _backButtonDispatcher;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _attachBackButtonDispatcher(widget.backButtonDispatcher);
    _coordinator = ref.read(sourceAudioPlaybackCoordinatorProvider.notifier);
    _controller = AudioPlayerController();
    if (!_coordinator.attachController(widget.sessionId, _controller)) {
      _controller.dispose();
      return;
    }
    _playbackLifecycle = SourceAudioPlaybackLifecycle(
      controller: _controller,
      settings: ref.read(appSettingsProvider),
      onPreferenceChanged: () => setState(() {}),
    );
    unawaited(_prepare());
  }

  Future<bool> _handlePlatformBack() async {
    if (widget.presentation != SourceAudioPresentation.expanded) return false;
    final navigator = widget.playbackNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      return navigator.maybePop();
    }
    await _requestBack();
    return true;
  }

  void _syncBackButtonPriority() {
    if (widget.presentation == SourceAudioPresentation.expanded) {
      _backButtonDispatcher.takePriority();
    } else {
      widget.backButtonDispatcher.forget(_backButtonDispatcher);
    }
  }

  void _attachBackButtonDispatcher(BackButtonDispatcher parent) {
    _backButtonDispatcher = parent.createChildBackButtonDispatcher()..addCallback(_handlePlatformBack);
    _syncBackButtonPriority();
  }

  @override
  void didUpdateWidget(covariant _ActiveSourceAudioPlaybackHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backButtonDispatcher, widget.backButtonDispatcher)) {
      _backButtonDispatcher.removeCallback(_handlePlatformBack);
      _attachBackButtonDispatcher(widget.backButtonDispatcher);
    } else if (oldWidget.presentation != widget.presentation) {
      _syncBackButtonPriority();
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (widget.presentation != SourceAudioPresentation.expanded ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    unawaited(_handlePlatformBack());
    return true;
  }

  Future<void> _requestBack() async {
    if (_setup == null || !_controller.isAttached) {
      await _stopFromPreparation();
    } else {
      await _controller.requestExit();
    }
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _setup = null;
        _setupFailure = null;
        _playerPresented = false;
      });
    }
    try {
      final request = widget.request;
      final library = request.libraryItemId == null ? null : await ref.read(appStartupControllerProvider).contentLibrary;
      final itemId = request.libraryItemId == null ? null : LibraryItemId(request.libraryItemId!);
      final storedProgress = library == null || itemId == null ? null : await library.loadProgress(itemId);
      final savedProgress = storedProgress is LibraryAudioPlaybackProgress ? storedProgress : null;
      final configuredProxyUri = await Future<Uri?>.value(
        ref.read(configuredFlutterNetworkProxyManagerProvider).proxyUriFor(NetworkProxyTraffic.audio),
      );
      final proxyUri = configuredProxyUri?.scheme == 'http' ? configuredProxyUri : null;
      final observer = await AndroidAudioBackgroundService.instance.attach(
        controller: _controller,
        onSystemStop: () => _coordinator.stop(sessionId: widget.sessionId),
        observer: _SourceAudioSessionObserver(
          onPresented: _presentPlayer,
          exitRequested: _handleExitRequested,
          sessionEnded: () => _coordinator.sessionEnded(widget.sessionId),
        ),
      );
      if (!mounted || generation != _generation) {
        await AndroidAudioBackgroundService.instance.detach(_controller);
        return;
      }
      setState(() {
        _setup = _AudioPlayerSetup(
          library: library,
          itemId: itemId,
          initialTrackId: savedProgress?.chapterId ?? request.chapter.id,
          proxyUri: proxyUri,
          observer: observer,
        );
      });
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _setupFailure = error);
    }
  }

  void _presentPlayer() {
    if (mounted && !_playerPresented) {
      setState(() => _playerPresented = true);
    }
  }

  Future<void> _handleExitRequested() async {
    if (!mounted) return;
    final settings = ref.read(appSettingsProvider);
    final behavior = settings.supports(AppSettingKeys.audioExitBehavior) ? settings.get(AppSettingKeys.audioExitBehavior) : 'ask';
    final decision = switch (behavior) {
      'continue' => _AudioExitDecision.continuePlaying,
      'stop' => _AudioExitDecision.stop,
      _ => await _askForExitDecision(),
    };
    if (decision == null || !mounted) return;
    if (_rememberExitChoice && settings.supports(AppSettingKeys.audioExitBehavior)) {
      final value = decision == _AudioExitDecision.continuePlaying ? 'continue' : 'stop';
      try {
        await settings.set(AppSettingKeys.audioExitBehavior, value);
      } on Object {
        // The immediate exit choice remains valid when persistence is degraded.
      }
    }
    _rememberExitChoice = false;
    if (decision == _AudioExitDecision.continuePlaying) {
      _coordinator.minimize(widget.sessionId);
    } else {
      await _coordinator.stop(sessionId: widget.sessionId);
    }
  }

  Future<_AudioExitDecision?> _askForExitDecision() {
    final existing = _exitDecision;
    if (existing != null) return existing.future;
    final decision = Completer<_AudioExitDecision?>();
    setState(() {
      _rememberExitChoice = false;
      _exitDecision = decision;
    });
    return decision.future;
  }

  void _completeExitDecision(_AudioExitDecision decision) {
    final completion = _exitDecision;
    if (completion == null || completion.isCompleted) return;
    setState(() => _exitDecision = null);
    completion.complete(decision);
  }

  Future<void> _stopFromPreparation() => _coordinator.stop(sessionId: widget.sessionId);

  @override
  Widget build(BuildContext context) {
    final minimized = widget.presentation == SourceAudioPresentation.minimized;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ExcludeFocus(
          excluding: minimized,
          child: Offstage(offstage: minimized, child: _buildExpandedPlayer(context)),
        ),
        if (_exitDecision != null) _buildExitPrompt(context),
      ],
    );
  }

  Widget _buildExpandedPlayer(BuildContext context) {
    final setup = _setup;
    final request = widget.request;
    if (setup == null) {
      return MediaEntryCoverSurface(
        kind: MediaEntryKind.audio,
        title: request.detail.summary.title,
        coverBytes: request.detail.summary.coverBytes,
        failureMessage: _setupFailure == null ? null : '播放器准备失败，请重试。',
        onRetry: _setupFailure == null ? null : () => unawaited(_prepare()),
        onExit: () => unawaited(_stopFromPreparation()),
      );
    }
    return MediaEntryCoverTransition(
      kind: MediaEntryKind.audio,
      title: request.detail.summary.title,
      coverBytes: request.detail.summary.coverBytes,
      presented: _playerPresented,
      onExit: () => unawaited(_handleExitRequested()),
      child: AudioPlayerView(
        key: const Key('source-audio-player'),
        collectionId: request.detail.summary.id,
        dataSource: SourceAudioPlaylistDataSource(
          gateway: ref.read(sourceContentGatewayProvider),
          pluginId: request.detail.pluginId,
          initialTrackId: setup.initialTrackId,
          initialDetail: request.detail,
          initialCatalog: request.libraryItemId == null ? request.firstCatalogPage : null,
        ),
        stateStore: TransientSourceAudioPlaybackStateStore(
          collectionId: request.detail.summary.id,
          initialTrackId: setup.initialTrackId,
          library: setup.library,
          libraryItemId: setup.itemId,
        ),
        controller: _controller,
        backend: ref.read(sourceAudioPlaybackBackendFactoryProvider)?.call(),
        proxyUri: setup.proxyUri,
        observer: setup.observer,
        artworkBuilder: (context, track) => _sourceAudioArtwork(context, track, request),
        prefetchBatchSize: 1,
        prefetchLeadTime: const Duration(seconds: 30),
        keepScreenOn: _playbackLifecycle!.keepScreenOn,
        onKeepScreenOnChanged: _playbackLifecycle!.setKeepScreenOn,
      ),
    );
  }

  Widget _buildExitPrompt(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ModalBarrier(key: Key('audio-background-exit-barrier'), dismissible: false, color: Color(0x73000000)),
        SafeArea(
          child: Center(
            child: AlertDialog(
              key: const Key('audio-background-exit-dialog'),
              title: const Text('是否继续播放？'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('继续后可从应用内播放条恢复；Android 也可从系统媒体通知控制。'),
                  const SizedBox(height: AppSpacing.compact),
                  CheckboxListTile(
                    key: const Key('audio-background-remember-choice'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('记住我的选择'),
                    value: _rememberExitChoice,
                    onChanged: (value) => setState(() => _rememberExitChoice = value ?? false),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  key: const Key('audio-background-stop'),
                  onPressed: () => _completeExitDecision(_AudioExitDecision.stop),
                  child: const Text('停止播放'),
                ),
                FilledButton(
                  key: const Key('audio-background-continue'),
                  onPressed: () => _completeExitDecision(_AudioExitDecision.continuePlaying),
                  child: const Text('继续播放'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _generation++;
    _playbackLifecycle?.dispose();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _backButtonDispatcher.removeCallback(_handlePlatformBack);
    final exitDecision = _exitDecision;
    if (exitDecision != null && !exitDecision.isCompleted) {
      exitDecision.complete(null);
    }
    _coordinator.detachController(widget.sessionId, _controller);
    _controller.dispose();
    super.dispose();
  }
}

final class _SourceAudioMiniOverlay extends StatefulWidget {
  const _SourceAudioMiniOverlay({
    required this.controller,
    required this.initialPosition,
    required this.onPositionChanged,
    required this.onExpand,
    required this.onStop,
  });

  final AudioPlayerController controller;
  final Offset? initialPosition;
  final ValueChanged<Offset> onPositionChanged;
  final VoidCallback onExpand;
  final VoidCallback onStop;

  @override
  State<_SourceAudioMiniOverlay> createState() => _SourceAudioMiniOverlayState();
}

final class _SourceAudioMiniOverlayState extends State<_SourceAudioMiniOverlay> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (context) => _DraggableSourceAudioMiniPlayer(
      controller: widget.controller,
      initialPosition: widget.initialPosition,
      onPositionChanged: widget.onPositionChanged,
      onExpand: widget.onExpand,
      onStop: widget.onStop,
    ),
  );

  @override
  void didUpdateWidget(covariant _SourceAudioMiniOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: <OverlayEntry>[_entry]);

  @override
  void dispose() {
    _entry.remove();
    _entry.dispose();
    super.dispose();
  }
}

final class _DraggableSourceAudioMiniPlayer extends StatefulWidget {
  const _DraggableSourceAudioMiniPlayer({
    required this.controller,
    required this.initialPosition,
    required this.onPositionChanged,
    required this.onExpand,
    required this.onStop,
  });

  final AudioPlayerController controller;
  final Offset? initialPosition;
  final ValueChanged<Offset> onPositionChanged;
  final VoidCallback onExpand;
  final VoidCallback onStop;

  @override
  State<_DraggableSourceAudioMiniPlayer> createState() => _DraggableSourceAudioMiniPlayerState();
}

final class _DraggableSourceAudioMiniPlayerState extends State<_DraggableSourceAudioMiniPlayer> {
  static const double _maxWidth = 520;
  static const double _height = 44 + AppSpacing.compact * 2;

  Offset? _position;
  Offset _resolvedPosition = Offset.zero;
  Offset _minimumPosition = Offset.zero;
  Offset _maximumPosition = Offset.zero;
  Offset _dragPointerOrigin = Offset.zero;
  Offset _dragPlayerOrigin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _position = widget.initialPosition;
  }

  @override
  void didUpdateWidget(covariant _DraggableSourceAudioMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_position == null && widget.initialPosition != oldWidget.initialPosition) {
      _position = widget.initialPosition;
    }
  }

  void _startDrag(DragStartDetails details) {
    _dragPointerOrigin = details.globalPosition;
    _dragPlayerOrigin = _resolvedPosition;
  }

  void _drag(DragUpdateDetails details) {
    final pointerDelta = details.globalPosition - _dragPointerOrigin;
    final next = Offset(
      (_dragPlayerOrigin.dx + pointerDelta.dx).clamp(_minimumPosition.dx, _maximumPosition.dx).toDouble(),
      (_dragPlayerOrigin.dy + pointerDelta.dy).clamp(_minimumPosition.dy, _maximumPosition.dy).toDouble(),
    );
    setState(() => _position = next);
    widget.onPositionChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = (constraints.maxWidth - AppSpacing.regular * 2).clamp(0.0, _maxWidth).toDouble();
        final minX = AppSpacing.regular;
        final maxX = (constraints.maxWidth - padding.right - AppSpacing.regular - availableWidth).clamp(minX, double.infinity).toDouble();
        final minY = padding.top + AppSpacing.regular;
        final maxY = (constraints.maxHeight - padding.bottom - AppSpacing.regular - _height).clamp(minY, double.infinity).toDouble();
        final defaultPosition = Offset(
          ((constraints.maxWidth - availableWidth) / 2).clamp(minX, maxX).toDouble(),
          (constraints.maxHeight - padding.bottom - AppSpacing.bottomNavigationHeight - AppSpacing.compact - _height)
              .clamp(minY, maxY)
              .toDouble(),
        );
        final requested = _position ?? defaultPosition;
        _minimumPosition = Offset(minX, minY);
        _maximumPosition = Offset(maxX, maxY);
        _resolvedPosition = Offset(requested.dx.clamp(minX, maxX).toDouble(), requested.dy.clamp(minY, maxY).toDouble());
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              left: _resolvedPosition.dx,
              top: _resolvedPosition.dy,
              width: availableWidth,
              child: Semantics(
                container: true,
                label: '可拖动后台播放条',
                child: GestureDetector(
                  key: const Key('source-audio-mini-drag-region'),
                  behavior: HitTestBehavior.opaque,
                  dragStartBehavior: DragStartBehavior.down,
                  onPanStart: _startDrag,
                  onPanUpdate: _drag,
                  child: _SourceAudioMiniPlayer(controller: widget.controller, onExpand: widget.onExpand, onStop: widget.onStop),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

final class _SourceAudioMiniPlayer extends StatefulWidget {
  const _SourceAudioMiniPlayer({required this.controller, required this.onExpand, required this.onStop});

  final AudioPlayerController controller;
  final VoidCallback onExpand;
  final VoidCallback onStop;

  @override
  State<_SourceAudioMiniPlayer> createState() => _SourceAudioMiniPlayerState();
}

final class _SourceAudioMiniPlayerState extends State<_SourceAudioMiniPlayer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(covariant _SourceAudioMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.controller.snapshot;
    final track = snapshot.currentTrack;
    final tokens = AppThemeTokens.of(context);
    return Material(
      key: const Key('source-audio-mini-player'),
      color: tokens.surface,
      elevation: 8,
      shadowColor: tokens.shadow,
      borderRadius: AppRadii.detailControl,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onExpand,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.regular, AppSpacing.compact, AppSpacing.unit, AppSpacing.compact),
          child: Row(
            children: <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: AppRadii.discoveryTile),
                child: const SizedBox.square(dimension: 44, child: Icon(Icons.graphic_eq_rounded)),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      track?.title ?? '正在准备音频',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      track?.collectionTitle ?? '点按返回播放器',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('source-audio-mini-toggle'),
                tooltip: snapshot.playing ? '暂停' : '播放',
                onPressed: () => unawaited(widget.controller.toggle()),
                icon: Icon(snapshot.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              IconButton(
                key: const Key('source-audio-mini-stop'),
                tooltip: '停止并关闭',
                onPressed: widget.onStop,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }
}

final class _AudioPlayerSetup {
  const _AudioPlayerSetup({
    required this.library,
    required this.itemId,
    required this.initialTrackId,
    required this.proxyUri,
    required this.observer,
  });

  final ContentLibrary? library;
  final LibraryItemId? itemId;
  final String initialTrackId;
  final Uri? proxyUri;
  final AudioPlayerObserver? observer;
}

final class _SourceAudioSessionObserver extends AudioPlayerObserver {
  const _SourceAudioSessionObserver({required this.onPresented, required this.exitRequested, required this.sessionEnded});

  final VoidCallback onPresented;
  final Future<void> Function() exitRequested;
  final VoidCallback sessionEnded;

  @override
  FutureOr<void> onSessionStarted(String collectionId) {
    onPresented();
  }

  @override
  FutureOr<void> onFailure(AudioPlayerFailure failure) {
    onPresented();
  }

  @override
  FutureOr<void> onExitRequested(AudioPlaybackProgress? progress) => exitRequested();

  @override
  FutureOr<void> onSessionEnded(String collectionId, AudioPlaybackProgress? progress) {
    sessionEnded();
  }
}

Widget _sourceAudioArtwork(BuildContext context, AudioTrack track, SourceAudioPlaybackRequest request) {
  final artwork = track.artwork;
  if (artwork == null || (artwork.scheme != 'http' && artwork.scheme != 'https')) {
    return const _SourceAudioArtworkFallback();
  }
  final coverRequest = BookCoverRequest(
    pluginId: request.detail.pluginId,
    pluginVersion: 'unknown',
    remoteContentId: request.detail.summary.id,
    coverUrl: artwork,
  );
  return Consumer(
    builder: (context, ref, _) => ref
        .watch(bookCoverBytesProvider(coverRequest))
        .when(
          data: (bytes) => bytes == null || bytes.isEmpty
              ? const _SourceAudioArtworkFallback()
              : Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover, gaplessPlayback: true),
          error: (_, _) => const _SourceAudioArtworkFallback(),
          loading: () => const _SourceAudioArtworkFallback(),
        ),
  );
}

final class _SourceAudioArtworkFallback extends StatelessWidget {
  const _SourceAudioArtworkFallback();

  @override
  Widget build(BuildContext context) => const Center(child: Icon(Icons.headphones_rounded, size: 86, color: Color(0xFFFFF7EB)));
}

enum _AudioExitDecision { continuePlaying, stop }
