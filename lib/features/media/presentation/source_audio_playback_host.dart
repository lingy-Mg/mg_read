/// App-root host for source audio that survives page navigation.
///
/// Responsibilities:
/// - Mount and discard controlled player views without owning playback.
/// - Collapse the full player into an in-app mini player over one controller.
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

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/media/application/source_audio_playback_service.dart';
import 'package:mg_read/features/media/presentation/media_entry_cover.dart';
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
    final playback = ref.watch(sourceAudioPlaybackServiceProvider);
    if (!playback.isActive) return const SizedBox.shrink();
    final service = ref.read(sourceAudioPlaybackServiceProvider.notifier);
    final minimized = playback.presentation == SourceAudioPresentation.minimized;
    final controller = playback.controller;
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
            onExpand: service.expand,
            onStop: () => unawaited(service.stop(sessionId: playback.sessionId)),
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
    final state = ref.watch(sourceAudioPlaybackServiceProvider);
    if (!state.isActive) return const SizedBox.shrink();
    return _ActiveSourceAudioPlaybackHost(
      key: ValueKey<int>(state.sessionId!),
      playback: state,
      backButtonDispatcher: backButtonDispatcher,
      playbackNavigatorKey: playbackNavigatorKey,
    );
  }
}

final class _ActiveSourceAudioPlaybackHost extends ConsumerStatefulWidget {
  const _ActiveSourceAudioPlaybackHost({
    required this.playback,
    required this.backButtonDispatcher,
    required this.playbackNavigatorKey,
    super.key,
  });

  final SourceAudioPlaybackState playback;
  final BackButtonDispatcher backButtonDispatcher;
  final GlobalKey<NavigatorState> playbackNavigatorKey;

  @override
  ConsumerState<_ActiveSourceAudioPlaybackHost> createState() => _ActiveSourceAudioPlaybackHostState();
}

final class _ActiveSourceAudioPlaybackHostState extends ConsumerState<_ActiveSourceAudioPlaybackHost> {
  bool _rememberExitChoice = false;
  late final SourceAudioPlaybackService _service;
  late ChildBackButtonDispatcher _backButtonDispatcher;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _attachBackButtonDispatcher(widget.backButtonDispatcher);
    _service = ref.read(sourceAudioPlaybackServiceProvider.notifier);
  }

  Future<bool> _handlePlatformBack() async {
    if (widget.playback.presentation != SourceAudioPresentation.expanded) return false;
    final navigator = widget.playbackNavigatorKey.currentState;
    if (navigator != null && navigator.canPop()) {
      return navigator.maybePop();
    }
    await _requestBack();
    return true;
  }

  void _syncBackButtonPriority() {
    if (widget.playback.presentation == SourceAudioPresentation.expanded) {
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
    } else if (oldWidget.playback.presentation != widget.playback.presentation) {
      _syncBackButtonPriority();
    }
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (widget.playback.presentation != SourceAudioPresentation.expanded ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    unawaited(_handlePlatformBack());
    return true;
  }

  Future<void> _requestBack() async {
    final controller = widget.playback.controller;
    if (controller == null || !controller.isAttached) {
      await _service.stop(sessionId: widget.playback.sessionId);
    } else {
      await controller.requestExit();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.playback.presentation == SourceAudioPresentation.minimized) {
      return const SizedBox.shrink();
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[_buildExpandedPlayer(context), if (widget.playback.exitDecisionRequested) _buildExitPrompt(context)],
    ).withSourceMediaImmersion(active: true);
  }

  Widget _buildExpandedPlayer(BuildContext context) {
    final playback = widget.playback;
    final controller = playback.controller;
    final request = playback.request!;
    if (controller == null) {
      final failure = playback.setupFailure;
      return MediaEntryCoverSurface(
        kind: MediaEntryKind.audio,
        title: request.detail.summary.title,
        coverBytes: request.detail.summary.coverBytes,
        failureMessage: failure?.message,
        failureLocation: failure?.location,
        failureCode: failure?.code,
        failureDetail: failure?.debugDetail,
        onRetry: failure == null ? null : () => unawaited(_service.retryPreparation()),
        onExit: () => unawaited(_service.stop(sessionId: playback.sessionId)),
      );
    }
    return MediaEntryCoverTransition(
      kind: MediaEntryKind.audio,
      title: request.detail.summary.title,
      coverBytes: request.detail.summary.coverBytes,
      presented: playback.playerPresented,
      onExit: () => unawaited(controller.requestExit()),
      child: AudioPlayerView.controlled(
        key: const Key('source-audio-player'),
        controller: controller,
        artworkBuilder: (context, track) => _sourceAudioArtwork(context, track, request),
        keepScreenOn: playback.keepScreenOn,
        onKeepScreenOnChanged: _service.setKeepScreenOn,
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
                  onPressed: () => unawaited(_resolveExit(false)),
                  child: const Text('停止播放'),
                ),
                FilledButton(
                  key: const Key('audio-background-continue'),
                  onPressed: () => unawaited(_resolveExit(true)),
                  child: const Text('继续播放'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _resolveExit(bool continuePlaying) async {
    final sessionId = widget.playback.sessionId;
    if (sessionId == null) return;
    final remember = _rememberExitChoice;
    if (mounted) setState(() => _rememberExitChoice = false);
    await _service.resolveExitDecision(sessionId: sessionId, continuePlaying: continuePlaying, remember: remember);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _backButtonDispatcher.removeCallback(_handlePlatformBack);
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
    final failure = snapshot.failure;
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
                child: SizedBox.square(
                  dimension: 44,
                  child: Tooltip(
                    message: failure == null
                        ? '音频正在后台播放'
                        : '${failure.message}\n发生位置：${failure.location}\n诊断编号：${failure.code}'
                              '${failure.debugDetail == null ? '' : '\n技术原因：${failure.debugDetail}'}',
                    child: Icon(failure == null ? Icons.graphic_eq_rounded : Icons.error_outline_rounded),
                  ),
                ),
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
                      failure == null ? track?.collectionTitle ?? '点按返回播放器' : '${failure.message} · ${failure.location} · ${failure.code}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: failure == null ? tokens.mutedText : tokens.warning),
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
