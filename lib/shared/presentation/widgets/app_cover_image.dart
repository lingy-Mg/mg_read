/// 跨书架、发现、搜索、详情和播放器的封面展示状态。
/// 字节请求、缓存、刷新和重试归调用方；本组件覆盖图片解码等待、失败降级和首次显示过渡。
/// 不阻塞父页面、不更改封面比例、不自动重试；无动画模式使用静态骨架并立即显示图片。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';

part 'app_cover_loading_surface.dart';

enum AppCoverState { loading, refreshing, missing, failed, ready }

class AppCoverFeedback extends StatelessWidget {
  const AppCoverFeedback({required this.state, required this.label, required this.child, this.loadingBaseColor, super.key});

  final AppCoverState state;
  final String label;
  final Widget child;
  final Color? loadingBaseColor;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: switch (state) {
      AppCoverState.loading => '$label加载中',
      AppCoverState.refreshing => '$label刷新中',
      AppCoverState.missing => '$label占位图',
      AppCoverState.failed => '$label加载失败',
      AppCoverState.ready => label,
    },
    child: ExcludeSemantics(
      child: switch (state) {
        AppCoverState.loading => _CoverLoadingSurface(placeholder: true, baseColor: loadingBaseColor, child: child),
        AppCoverState.refreshing => _CoverLoadingSurface(placeholder: false, baseColor: loadingBaseColor, child: child),
        AppCoverState.failed => Stack(
          fit: StackFit.passthrough,
          children: [
            child,
            const Positioned.fill(
              child: IgnorePointer(child: _CoverFailureMark(key: Key('cover-load-failed'))),
            ),
          ],
        ),
        AppCoverState.missing || AppCoverState.ready => child,
      },
    ),
  );
}

/// Keeps the placeholder visible through first-frame decode, including memory and asset images.
class AppCoverImage extends StatefulWidget {
  const AppCoverImage({
    required this.image,
    required this.placeholder,
    required this.label,
    this.loadingBaseColor,
    this.loading = false,
    this.failed = false,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.frameBuilder,
    this.imageKey,
    super.key,
  });

  final ImageProvider? image;
  final Widget placeholder;
  final String label;

  /// Optional opaque canvas for fullscreen media, independent of the host theme.
  final Color? loadingBaseColor;
  final bool loading;
  final bool failed;
  final double? width;
  final double? height;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final ImageFrameBuilder? frameBuilder;
  final Key? imageKey;

  @override
  State<AppCoverImage> createState() => _AppCoverImageState();
}

class _AppCoverImageState extends State<AppCoverImage> {
  ImageProvider? _presentedImage;
  bool _hasPresentedFrame = false;
  bool _fadeCurrent = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disablesAnimations(context)) _fadeCurrent = false;
  }

  @override
  void didUpdateWidget(AppCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image == null) {
      _presentedImage = null;
      _hasPresentedFrame = false;
      _fadeCurrent = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget surface(AppCoverState state, Widget child) =>
        AppCoverFeedback(state: state, label: widget.label, loadingBaseColor: widget.loadingBaseColor, child: child);
    if (widget.image == null) {
      return surface(
        widget.loading
            ? AppCoverState.loading
            : widget.failed
            ? AppCoverState.failed
            : AppCoverState.missing,
        widget.placeholder,
      );
    }
    return Image(
      key: widget.imageKey,
      image: widget.image!,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      alignment: widget.alignment,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) {
        _presentedImage = null;
        _hasPresentedFrame = false;
        _fadeCurrent = false;
        return surface(AppCoverState.failed, widget.placeholder);
      },
      frameBuilder: (context, child, frame, synchronous) {
        if (frame == null) {
          final previous = child is RawImage && child.image != null;
          return surface(previous ? AppCoverState.refreshing : AppCoverState.loading, previous ? child : widget.placeholder);
        }
        final content = widget.frameBuilder?.call(context, child, frame, synchronous) ?? child;
        if (_presentedImage != widget.image) {
          _fadeCurrent = !_hasPresentedFrame && !synchronous && !AppMotion.disablesAnimations(context);
          _hasPresentedFrame = true;
          _presentedImage = widget.image;
        }
        final state = widget.loading
            ? AppCoverState.refreshing
            : widget.failed
            ? AppCoverState.failed
            : AppCoverState.ready;
        if (!_fadeCurrent || AppMotion.disablesAnimations(context)) return surface(state, content);
        return surface(
          state,
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: AppMotion.effectiveDuration(context, AppMotion.short),
            curve: AppMotion.navigationCurve,
            onEnd: () => _fadeCurrent = false,
            child: content,
            builder: (context, progress, child) => progress >= 1
                ? child!
                : Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Positioned.fill(
                        child: Opacity(
                          opacity: 1 - progress,
                          child: _CoverSkeleton(baseColor: widget.loadingBaseColor),
                        ),
                      ),
                      Opacity(opacity: progress, child: child),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
