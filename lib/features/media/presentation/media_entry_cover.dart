/// 音频与视频播放器的封面入场承载层。
///
/// 职责：
/// - 在播放器异步准备期间立即展示来源封面和明确加载状态。
/// - 等待音频会话就绪或视频真实首帧后，以短淡出完成视觉交接。
/// - 在播放器尚未挂载时提供可返回、可重试的失败表面。
/// - 为音频扩展页持有可恢复的沉浸式系统 UI 生命周期。
///
/// 注意：
/// - 只消费宿主已经持有的封面字节，不自行读取网络、Runtime 或持久化。
/// - 减少动态效果时立即完成交接，不保留不可见动画层。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/media/application/source_media_system_ui_controller.dart';
import 'package:mg_read/shared/presentation/widgets/default_book_cover_artwork.dart';

enum MediaEntryKind {
  audio,
  video;

  String get loadingLabel => switch (this) {
    audio => '正在准备音频',
    video => '正在准备视频',
  };

  String get failureLabel => switch (this) {
    audio => '音频暂时无法打开',
    video => '视频暂时无法打开',
  };
}

/// Keeps portrait immersive mode aligned with one mounted media presentation.
final class SourceMediaImmersiveScope extends StatefulWidget {
  const SourceMediaImmersiveScope({required this.active, required this.child, super.key});

  final bool active;
  final Widget child;

  @override
  State<SourceMediaImmersiveScope> createState() => _SourceMediaImmersiveScopeState();
}

/// Adds host-owned portrait immersion without changing the wrapped layout.
extension SourceMediaImmersiveWidget on Widget {
  Widget withSourceMediaImmersion({required bool active}) => SourceMediaImmersiveScope(active: active, child: this);
}

final class _SourceMediaImmersiveScopeState extends State<SourceMediaImmersiveScope> {
  final SourceMediaSystemUiLease _lease = SourceMediaSystemUiLease();

  @override
  void initState() {
    super.initState();
    unawaited(_sync());
  }

  @override
  void didUpdateWidget(covariant SourceMediaImmersiveScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) unawaited(_sync());
  }

  Future<void> _sync() => widget.active ? _lease.setMode(SourceMediaSystemUiMode.portraitImmersive) : _lease.release();

  @override
  void dispose() {
    unawaited(_lease.releaseAndClose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Keeps a stable cover above a mounted player until real media is ready.
final class MediaEntryCoverTransition extends StatefulWidget {
  const MediaEntryCoverTransition({
    required this.kind,
    required this.title,
    required this.coverBytes,
    required this.presented,
    required this.onExit,
    required this.child,
    super.key,
  });

  final MediaEntryKind kind;
  final String title;
  final List<int>? coverBytes;
  final bool presented;
  final VoidCallback onExit;
  final Widget child;

  @override
  State<MediaEntryCoverTransition> createState() => _MediaEntryCoverTransitionState();
}

final class _MediaEntryCoverTransitionState extends State<MediaEntryCoverTransition> {
  late bool _coverMounted;

  @override
  void initState() {
    super.initState();
    _coverMounted = !widget.presented;
  }

  @override
  void didUpdateWidget(covariant MediaEntryCoverTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.presented && widget.presented && MediaQuery.maybeDisableAnimationsOf(context) == true) {
      _coverMounted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (widget.presented && reduceMotion) _coverMounted = false;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ExcludeSemantics(
          excluding: _coverMounted,
          child: IgnorePointer(ignoring: _coverMounted, child: widget.child),
        ),
        if (_coverMounted)
          AnimatedOpacity(
            key: const Key('media-entry-cover-transition'),
            opacity: widget.presented ? 0 : 1,
            duration: reduceMotion ? Duration.zero : AppMotion.micro,
            curve: Curves.easeOutQuart,
            onEnd: () {
              if (mounted && widget.presented) setState(() => _coverMounted = false);
            },
            child: MediaEntryCoverSurface(kind: widget.kind, title: widget.title, coverBytes: widget.coverBytes, onExit: widget.onExit),
          ),
      ],
    );
  }
}

/// Standalone preparation surface used before a player can be mounted.
final class MediaEntryCoverSurface extends StatelessWidget {
  const MediaEntryCoverSurface({
    required this.kind,
    required this.title,
    required this.coverBytes,
    required this.onExit,
    this.failureMessage,
    this.failureLocation,
    this.failureCode,
    this.failureDetail,
    this.onRetry,
    super.key,
  });

  final MediaEntryKind kind;
  final String title;
  final List<int>? coverBytes;
  final VoidCallback onExit;
  final String? failureMessage;
  final String? failureLocation;
  final String? failureCode;
  final String? failureDetail;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bytes = coverBytes;
    final hasFailure = failureMessage != null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Material(
        color: tokens.pageBackground,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[tokens.coverIndigoStart, tokens.coverOceanEnd],
                ),
              ),
            ),
            SafeArea(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final coverWidth = (constraints.maxWidth * .58).clamp(168.0, 268.0);
                  final coverHeight = coverWidth / .68;
                  final hasCoverArtwork = bytes != null && bytes.isNotEmpty;
                  return Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      if (hasCoverArtwork)
                        Positioned.fill(child: _MediaEntryCoverArtwork(bytes: bytes))
                      else
                        Align(
                          alignment: const Alignment(0, -.08),
                          child: TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: .94, end: 1),
                            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : AppMotion.destinationTransition,
                            curve: Curves.easeOutCubic,
                            builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: <BoxShadow>[
                                  BoxShadow(color: Colors.black.withValues(alpha: .28), blurRadius: 30, offset: const Offset(0, 16)),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: bytes == null || bytes.isEmpty
                                    ? DefaultBookCoverArtwork(
                                        title: title,
                                        width: coverWidth,
                                        height: coverHeight,
                                        startColor: tokens.coverIndigoStart,
                                        endColor: tokens.coverOceanEnd,
                                        foregroundColor: Colors.white.withValues(alpha: .96),
                                        borderRadius: BorderRadius.circular(22),
                                      )
                                    : Image.memory(
                                        Uint8List.fromList(bytes),
                                        key: const Key('media-entry-cover-image'),
                                        width: coverWidth,
                                        height: coverHeight,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, _, _) => DefaultBookCoverArtwork(
                                          title: title,
                                          width: coverWidth,
                                          height: coverHeight,
                                          startColor: tokens.coverIndigoStart,
                                          endColor: tokens.coverOceanEnd,
                                          foregroundColor: Colors.white.withValues(alpha: .96),
                                          borderRadius: BorderRadius.circular(22),
                                        ),
                                      ),
                              ),
                            ),
                          ),
                        ),
                      Align(
                        alignment: const Alignment(0, .72),
                        child: Semantics(
                          key: const Key('media-entry-status'),
                          liveRegion: true,
                          label: hasFailure
                              ? '${kind.failureLabel}：$failureMessage；位置：${failureLocation ?? '未知'}；编号：${failureCode ?? '未知'}'
                              : kind.loadingLabel,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              if (!hasFailure)
                                const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                                )
                              else
                                const Icon(Icons.refresh_rounded, color: Colors.white),
                              const SizedBox(height: 12),
                              Text(
                                hasFailure ? kind.failureLabel : kind.loadingLabel,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                              ),
                              if (hasFailure) ...<Widget>[
                                const SizedBox(height: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 520),
                                  child: Text(
                                    failureMessage!,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white),
                                  ),
                                ),
                                if (failureLocation != null || failureCode != null) ...<Widget>[
                                  const SizedBox(height: 4),
                                  Text(
                                    '发生位置：${failureLocation ?? '未知'}  ·  诊断编号：${failureCode ?? '未知'}',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                                  ),
                                ],
                                if (failureDetail case final detail?) ...<Widget>[
                                  const SizedBox(height: 4),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 520),
                                    child: SelectableText(
                                      '技术原因：$detail',
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                                    ),
                                  ),
                                ],
                              ],
                              if (hasFailure && onRetry != null) ...<Widget>[
                                const SizedBox(height: 12),
                                FilledButton.tonal(key: const Key('media-entry-retry'), onPressed: onRetry, child: const Text('重试')),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  key: const Key('media-entry-back'),
                  tooltip: '返回',
                  onPressed: onExit,
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Presents media artwork inside the whole player viewport without changing
/// its intrinsic aspect ratio. A black background naturally creates the
/// required letterbox bars for landscape and square artwork.
final class _MediaEntryCoverArtwork extends StatelessWidget {
  const _MediaEntryCoverArtwork({required this.bytes});

  final List<int> bytes;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Image.memory(
      Uint8List.fromList(bytes),
      key: const Key('media-entry-cover-image'),
      fit: BoxFit.contain,
      alignment: Alignment.center,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
    ),
  );
}
