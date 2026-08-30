/// 音频与视频播放器的封面入场承载层。
///
/// 职责：
/// - 在播放器异步准备期间立即展示来源封面和明确加载状态。
/// - 等待音频会话就绪或视频真实首帧后，以短淡出完成视觉交接。
/// - 在播放器尚未挂载时提供可返回、可重试的失败表面。
///
/// 注意：
/// - 只消费宿主已经持有的封面字节，不自行读取网络、Runtime 或持久化。
/// - 减少动态效果时立即完成交接，不保留不可见动画层。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
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
  bool _coverMounted = true;

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
          AbsorbPointer(
            child: AnimatedOpacity(
              key: const Key('media-entry-cover-transition'),
              opacity: widget.presented ? 0 : 1,
              duration: reduceMotion ? Duration.zero : AppMotion.micro,
              curve: Curves.easeOutQuart,
              onEnd: () {
                if (mounted && widget.presented) setState(() => _coverMounted = false);
              },
              child: MediaEntryCoverSurface(kind: widget.kind, title: widget.title, coverBytes: widget.coverBytes, onExit: widget.onExit),
            ),
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
    this.onRetry,
    super.key,
  });

  final MediaEntryKind kind;
  final String title;
  final List<int>? coverBytes;
  final VoidCallback onExit;
  final String? failureMessage;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bytes = coverBytes;
    final hasFailure = failureMessage != null;
    return Material(
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
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
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
                        label: hasFailure ? '${kind.failureLabel}：$failureMessage' : kind.loadingLabel,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (!hasFailure)
                              const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                            else
                              const Icon(Icons.refresh_rounded, color: Colors.white),
                            const SizedBox(height: 12),
                            Text(
                              hasFailure ? kind.failureLabel : kind.loadingLabel,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
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
    );
  }
}
