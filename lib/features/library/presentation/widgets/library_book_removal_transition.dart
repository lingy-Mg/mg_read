/// 书架条目移除过渡。
///
/// 职责：
/// - 在原位置收缩、淡出并轻微位移待删除条目。
/// - 在持久化失败时将同一条目平滑恢复到原相邻位置。
///
/// 注意：
/// - 只处理展示过渡，不拥有持久化或滚动控制器。
/// - reduce motion 时直接切换，避免无意义的动态效果。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// 在保持父 Sliver 身份的条件下过渡一个书架条目。
class LibraryBookRemovalTransition extends StatelessWidget {
  const LibraryBookRemovalTransition({required this.isRemoving, required this.child, super.key});

  final bool isRemoving;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool disableAnimations = MediaQuery.disableAnimationsOf(context);
    final double target = isRemoving ? 0 : 1;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: disableAnimations ? Duration.zero : AppMotion.destinationTransition,
      curve: AppMotion.navigationCurve,
      builder: (BuildContext context, double progress, Widget? child) {
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: progress,
            child: Opacity(
              opacity: progress,
              child: Transform.translate(offset: Offset(0, (1 - progress) * AppSpacing.compact), child: child),
            ),
          ),
        );
      },
      child: child,
    );
  }
}
