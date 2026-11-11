/// 跨书架、发现、搜索、详情和播放器的封面展示状态。
/// 字节请求、缓存、刷新和重试归调用方；本组件覆盖图片解码等待、失败降级和首次显示过渡。
/// 不阻塞父页面、不更改封面比例、不自动重试；无动画模式使用静态等待图标并立即显示图片。
library;

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';

enum AppCoverState { loading, refreshing, missing, failed, ready }

class AppCoverFeedback extends StatelessWidget {
  const AppCoverFeedback({required this.state, required this.label, required this.child, super.key});

  final AppCoverState state;
  final String label;
  final Widget child;

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
      child: state == AppCoverState.ready || state == AppCoverState.missing
          ? child
          : Stack(
              fit: StackFit.passthrough,
              children: [
                child,
                Positioned.fill(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final side = constraints.biggest.shortestSide;
                        final size = side.isFinite ? (side * .22).clamp(14.0, 26.0) : 22.0;
                        return ColoredBox(
                          color: const Color(0x29000000),
                          child: Center(
                            child: DecoratedBox(
                              decoration: const BoxDecoration(color: Color(0xD9121824), shape: BoxShape.circle),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: state == AppCoverState.failed
                                    ? Icon(
                                        Icons.broken_image_outlined,
                                        key: const Key('cover-load-failed'),
                                        size: size,
                                        color: Colors.white,
                                      )
                                    : SizedBox.square(
                                        dimension: size,
                                        child: AppMotion.disablesAnimations(context)
                                            ? Icon(
                                                Icons.hourglass_empty_rounded,
                                                key: const Key('cover-load-static'),
                                                size: size,
                                                color: Colors.white,
                                              )
                                            : const CircularProgressIndicator(
                                                key: Key('cover-load-progress'),
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                      ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}

/// Keeps the placeholder visible through first-frame decode, including memory and asset images.
class AppCoverImage extends StatelessWidget {
  const AppCoverImage({
    required this.image,
    required this.placeholder,
    required this.label,
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
  final bool loading;
  final bool failed;
  final double? width;
  final double? height;
  final BoxFit fit;
  final AlignmentGeometry alignment;
  final ImageFrameBuilder? frameBuilder;
  final Key? imageKey;

  @override
  Widget build(BuildContext context) {
    Widget surface(AppCoverState state, Widget child) => AppCoverFeedback(state: state, label: label, child: child);
    if (image == null) {
      return surface(
        loading
            ? AppCoverState.loading
            : failed
            ? AppCoverState.failed
            : AppCoverState.missing,
        placeholder,
      );
    }
    return Image(
      key: imageKey,
      image: image!,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      gaplessPlayback: true,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => surface(AppCoverState.failed, placeholder),
      frameBuilder: (context, child, frame, synchronous) {
        if (frame == null) {
          final previous = child is RawImage && child.image != null;
          return surface(previous ? AppCoverState.refreshing : AppCoverState.loading, previous ? child : placeholder);
        }
        final content = frameBuilder?.call(context, child, frame, synchronous) ?? child;
        final state = loading
            ? AppCoverState.refreshing
            : failed
            ? AppCoverState.failed
            : AppCoverState.ready;
        if (synchronous || AppMotion.disablesAnimations(context)) return surface(state, content);
        return surface(
          state,
          TweenAnimationBuilder<double>(
            tween: Tween(begin: synchronous ? 1 : 0, end: 1),
            duration: AppMotion.effectiveDuration(context, AppMotion.short),
            curve: AppMotion.navigationCurve,
            child: content,
            builder: (context, progress, child) => progress >= 1
                ? child!
                : Stack(
                    fit: StackFit.passthrough,
                    children: [
                      Positioned.fill(
                        child: Opacity(opacity: 1 - progress, child: placeholder),
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
