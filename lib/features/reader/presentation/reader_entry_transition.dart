/// 阅读器入场承载层。
///
/// 职责：
/// - 以稳定封面载体遮蔽正文首帧前的异步准备与排版。
/// - 消费阅读器公开的首帧和失败通知，完成可打断的视觉交接。
/// - 将系统返回统一交给宿主 Observer，避免退出动画阻塞进度保存。
///
/// 注意：
/// - 不持有书籍正文、Repository、Runtime DTO 或可持久化状态。
/// - 减少动态效果、路由销毁和重试都会立即停止并释放动画 Controller。
///
/// TODO:
/// - 无。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/presentation/reader_host_page.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';

/// Hosts a resolved reader behind a deterministic cover-to-reader handoff.
///
/// The reader remains mounted underneath the cover while it prepares its first
/// actual text frame. The cover is removed only after the public first-frame
/// callback, so no synthetic progress or intermediate blank surface is shown.
class ReaderEntryTransition extends StatefulWidget {
  const ReaderEntryTransition({required this.request, this.onFirstContentPresented, this.onInitialFailure, super.key});

  /// Resolved app-owned inputs for the embedded reader session.
  final ReaderLaunchRequest request;

  /// Receives the plugin's one-time real first-frame notification.
  final ValueChanged<ReaderFirstContentPresentation>? onFirstContentPresented;

  /// Receives a recoverable failure before readable content is shown.
  final ValueChanged<ReaderFailure>? onInitialFailure;

  @override
  State<ReaderEntryTransition> createState() => _ReaderEntryTransitionState();
}

/// Renders the same visual carrier while a route resolves its reader request.
///
/// This covers launch mapping failures before [ReaderEntryTransition] can mount
/// the plugin, keeping retry and return in the same stable reading surface.
class ReaderEntryPreparationSurface extends StatefulWidget {
  const ReaderEntryPreparationSurface({required this.failed, required this.onRetry, required this.onExit, super.key});

  /// Whether route-level preparation has reached a recoverable failure.
  final bool failed;

  /// Repeats the route-owned request resolution after a failure.
  final VoidCallback? onRetry;

  /// Leaves the route immediately without waiting for a visual reverse pass.
  final VoidCallback onExit;

  @override
  State<ReaderEntryPreparationSurface> createState() => _ReaderEntryPreparationSurfaceState();
}

class _ReaderEntryPreparationSurfaceState extends State<ReaderEntryPreparationSurface> with TickerProviderStateMixin {
  late final AnimationController _entryController;

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(vsync: this, duration: _ReaderEntryTransitionState._entryDuration)
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _entryController.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) _entryController.value = 1;
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double progress = Curves.easeOutCubic.transform(_entryController.value);
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, void result) {
        if (!didPop) widget.onExit();
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _ReaderEntryBackdrop(progress: progress),
          _ReaderEntryCover(
            progress: progress,
            disappearance: 0,
            failed: widget.failed ? const ReaderFailure(ReaderFailureKind.data, 'route_failure') : null,
            onRetry: widget.onRetry,
            onExit: widget.onExit,
          ),
        ],
      ),
    );
  }
}

class _ReaderEntryTransitionState extends State<ReaderEntryTransition> with TickerProviderStateMixin {
  static const Duration _entryDuration = Duration(milliseconds: 360);
  static const Duration _handoffDuration = Duration(milliseconds: 180);
  static const double _coverAspectRatio = .68;

  late final AnimationController _entryController;
  late final AnimationController _handoffController;
  late final ReaderLaunchRequest _boundRequest;
  late final _ReaderEntryObserver _observer;
  ReaderFailure? _failure;
  bool _firstContentPresented = false;
  bool _handoffComplete = false;
  int _readerEpoch = 0;

  bool get _reduceMotion => MediaQuery.of(context).disableAnimations;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(vsync: this, duration: _entryDuration)..addListener(_rebuildForAnimation);
    _handoffController = AnimationController(vsync: this, duration: _handoffDuration)
      ..addListener(_rebuildForAnimation)
      ..addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _handoffComplete = true);
        }
      });
    _observer = _ReaderEntryObserver(
      delegate: widget.request.observer,
      firstContentHandler: _presentFirstContent,
      failureHandler: _presentInitialFailure,
    );
    _boundRequest = widget.request.withObserver(_observer);
    _entryController.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion && !_handoffComplete) {
      _entryController.value = 1;
      if (_firstContentPresented) {
        _handoffController.value = 1;
        _handoffComplete = true;
      }
    }
  }

  void _rebuildForAnimation() {
    if (mounted) setState(() {});
  }

  void _presentFirstContent(ReaderFirstContentPresentation presentation) {
    if (!mounted || _firstContentPresented) return;
    setState(() {
      _firstContentPresented = true;
      _failure = null;
    });
    widget.onFirstContentPresented?.call(presentation);
    if (_reduceMotion) {
      _entryController.value = 1;
      _handoffController.value = 1;
      setState(() => _handoffComplete = true);
      return;
    }
    unawaited(_finishHandoff());
  }

  Future<void> _finishHandoff() async {
    await _entryController.animateTo(
      1,
      duration: _entryController.value < .92 ? const Duration(milliseconds: 120) : const Duration(milliseconds: 72),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || !_firstContentPresented || _reduceMotion) return;
    await _handoffController.forward();
  }

  void _presentInitialFailure(ReaderFailure failure) {
    if (!mounted || _firstContentPresented) return;
    setState(() => _failure = failure);
    widget.onInitialFailure?.call(failure);
    if (_reduceMotion) {
      _entryController.value = 1;
      return;
    }
    unawaited(_entryController.animateTo(1, curve: Curves.easeOutCubic));
  }

  void _retry() {
    if (_firstContentPresented) return;
    _entryController
      ..stop()
      ..value = 0;
    _handoffController
      ..stop()
      ..value = 0;
    setState(() {
      _failure = null;
      _handoffComplete = false;
      _readerEpoch++;
    });
    if (_reduceMotion) {
      _entryController.value = 1;
    } else {
      _entryController.forward();
    }
  }

  void _requestExit() {
    final FutureOr<void> Function(ReaderProgress? progress)? callback = _boundRequest.observer?.onExitRequested;
    if (callback == null) return;
    unawaited(Future<void>.sync(() async => await callback(null)));
  }

  @override
  void dispose() {
    _entryController.dispose();
    _handoffController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Animation<double> entryCurve = CurvedAnimation(parent: _entryController, curve: Curves.easeOutCubic);
    final Animation<double> handoffCurve = CurvedAnimation(parent: _handoffController, curve: Curves.easeOutQuart);
    final double handoff = handoffCurve.value;
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, void result) {
        if (!didPop) _requestExit();
      },
      child: Semantics(
        container: true,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _ReaderEntryBackdrop(progress: entryCurve.value),
            Transform.translate(
              offset: Offset(0, (1 - handoff) * 7),
              child: Opacity(
                opacity: _firstContentPresented ? handoff : 0,
                child: KeyedSubtree(
                  key: ValueKey<int>(_readerEpoch),
                  child: ReaderHostPage(request: _boundRequest),
                ),
              ),
            ),
            if (!_handoffComplete)
              _ReaderEntryCover(
                progress: entryCurve.value,
                disappearance: handoff,
                failed: _failure,
                onRetry: _failure == null ? null : _retry,
                onExit: _requestExit,
              ),
          ],
        ),
      ),
    );
  }
}

class _ReaderEntryBackdrop extends StatelessWidget {
  const _ReaderEntryBackdrop({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color.lerp(tokens.coverIndigoStart, tokens.pageBackground, progress)!,
            Color.lerp(tokens.coverOceanEnd, tokens.surface, progress)!,
          ],
        ),
      ),
    );
  }
}

class _ReaderEntryCover extends StatelessWidget {
  const _ReaderEntryCover({
    required this.progress,
    required this.disappearance,
    required this.failed,
    required this.onRetry,
    required this.onExit,
  });

  final double progress;
  final double disappearance;
  final ReaderFailure? failed;
  final VoidCallback? onRetry;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size size = constraints.biggest;
        final double coverWidth = (size.width * .48).clamp(148, 224).toDouble();
        final Rect initial = Rect.fromCenter(
          center: Offset(size.width / 2, size.height * .47),
          width: coverWidth,
          height: coverWidth / _ReaderEntryTransitionState._coverAspectRatio,
        );
        final Rect terminal = Offset.zero & size;
        final Rect rect = Rect.lerp(initial, terminal, progress)!;
        final BorderRadius radius = BorderRadius.lerp(BorderRadius.circular(22), BorderRadius.zero, progress)!;
        return IgnorePointer(
          ignoring: disappearance >= .98,
          child: Opacity(
            opacity: 1 - disappearance,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Positioned.fromRect(
                  rect: rect,
                  child: ClipRRect(
                    borderRadius: radius,
                    child: _ReaderEntryArtwork(width: rect.width, height: rect.height, borderRadius: radius),
                  ),
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      key: const Key('reader-entry-back'),
                      tooltip: '返回',
                      onPressed: onExit,
                      icon: Icon(Icons.arrow_back_rounded, color: tokens.surface.withValues(alpha: .92)),
                    ),
                  ),
                ),
                _ReaderEntryStatus(failed: failed, onRetry: onRetry, foreground: tokens.surface.withValues(alpha: .94)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReaderEntryArtwork extends StatelessWidget {
  const _ReaderEntryArtwork({required this.width, required this.height, required this.borderRadius});

  final double width;
  final double height;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DefaultBookCoverArtwork(
      title: '阅读',
      width: width,
      height: height,
      startColor: tokens.coverIndigoStart,
      endColor: tokens.coverOceanEnd,
      foregroundColor: tokens.surface.withValues(alpha: .96),
      borderRadius: borderRadius,
    );
  }
}

class _ReaderEntryStatus extends StatelessWidget {
  const _ReaderEntryStatus({required this.failed, required this.onRetry, required this.foreground});

  final ReaderFailure? failed;
  final VoidCallback? onRetry;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final bool hasFailure = failed != null;
    return SafeArea(
      child: Align(
        alignment: const Alignment(0, .56),
        child: Semantics(
          key: const Key('reader-entry-status'),
          liveRegion: true,
          label: hasFailure ? '正文暂时无法打开' : '正在准备正文',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (!hasFailure)
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: foreground))
              else
                Icon(Icons.refresh_rounded, color: foreground),
              const SizedBox(height: 12),
              Text(hasFailure ? '正文暂时无法打开' : '正在准备正文', style: textTheme.bodyMedium?.copyWith(color: foreground)),
              if (hasFailure) ...<Widget>[
                const SizedBox(height: 12),
                FilledButton.tonal(key: const Key('reader-entry-retry'), onPressed: onRetry, child: const Text('重试')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

final class _ReaderEntryObserver extends ReaderObserver {
  const _ReaderEntryObserver({required this.delegate, required this.firstContentHandler, required this.failureHandler});

  final ReaderObserver? delegate;
  final void Function(ReaderFirstContentPresentation presentation) firstContentHandler;
  final void Function(ReaderFailure failure) failureHandler;

  @override
  Future<void> onSessionStarted(String bookId) async {
    await delegate?.onSessionStarted(bookId);
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    await delegate?.onSessionEnded(bookId, progress);
  }

  @override
  Future<void> onLifecycleChanged(ReaderLifecycleState state, ReaderProgress? progress) async {
    await delegate?.onLifecycleChanged(state, progress);
  }

  @override
  Future<void> onChapterChanged(ReaderChapterInfo chapter) async {
    await delegate?.onChapterChanged(chapter);
  }

  @override
  Future<void> onFailure(ReaderFailure failure) async {
    failureHandler(failure);
    await delegate?.onFailure(failure);
  }

  @override
  Future<void> onFirstContentPresented(ReaderFirstContentPresentation presentation) async {
    firstContentHandler(presentation);
    await delegate?.onFirstContentPresented(presentation);
  }

  @override
  Future<void> onChapterPerformance(ReaderChapterPerformanceEvent event) async {
    await delegate?.onChapterPerformance(event);
  }

  @override
  Future<void> onExitRequested(ReaderProgress? progress) async {
    await delegate?.onExitRequested(progress);
  }
}
