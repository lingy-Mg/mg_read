/// 应用动效的唯一 token 与策略入口；只描述视觉，不延迟 IO 或业务提交。
/// 系统减少动态效果和应用无动画模式通过 MediaQuery 合并，任一开启即立即呈现终态。
/// 持续动效必须同时遵守本策略、TickerMode 与前后台生命周期。
library;

import 'package:flutter/material.dart';

abstract final class AppMotion {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration navigationSelection = Duration(milliseconds: 140);
  static const Duration short = Duration(milliseconds: 180);
  static const Duration shortReverse = Duration(milliseconds: 140);
  static const Duration contentChange = Duration(milliseconds: 220);
  static const Duration pageTransition = Duration(milliseconds: 260);
  static const Duration pageReverseTransition = Duration(milliseconds: 200);
  static const Duration themeTransition = Duration(milliseconds: 240);
  static const Duration loadingSettle = Duration(milliseconds: 120);
  static const Duration loadingShimmer = Duration(milliseconds: 980);
  static const Duration playingIndicatorCycle = Duration(milliseconds: 820);
  static const Duration carouselTravel = Duration(milliseconds: 360);
  static const Duration bottomNavigationIconResponse = Duration(milliseconds: 220);
  static const Duration bottomNavigationLabelResponse = Duration(milliseconds: 190);
  static const Duration bottomNavigationPillMinimumTravel = Duration(milliseconds: 180);
  static const Duration bottomNavigationPillTravel = Duration(milliseconds: 300);
  static const Duration privacyModeReveal = Duration(milliseconds: 520);
  static const Duration destinationTransition = short;
  static const Duration destinationReverseTransition = shortReverse;
  static const double contentTravel = 12;
  static const double bottomNavigationPillOvershoot = 0.045;
  static const double bottomNavigationPillTravelWidthScale = 0.72;
  static const double bottomNavigationPillTravelHeightScale = 0.8;
  static const double bottomNavigationPillArrivalWidthScale = 1.08;
  static const double bottomNavigationPillArrivalHeightScale = 1.06;
  static const double bottomNavigationSelectionHandoff = 0.64;
  static const double bottomNavigationSelectedIconScale = 1.12;
  static const double bottomNavigationUnselectedIconAlignmentY = -0.38;
  static const double bottomNavigationLabelAlignmentY = 0.58;
  static const Curve navigationCurve = Curves.easeOutCubic;
  static const Curve navigationReverseCurve = Curves.easeInCubic;
  static const Curve standardCurve = Curves.easeInOutCubic;

  static bool disablesAnimations(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  static Duration effectiveDuration(BuildContext context, Duration duration) => disablesAnimations(context) ? Duration.zero : duration;

  /// DialogRoute 当前仅消费 duration；底部面板同时消费 reverseDuration。
  static AnimationStyle overlayStyle(BuildContext context) => AnimationStyle(
    duration: effectiveDuration(context, pageTransition),
    reverseDuration: effectiveDuration(context, pageReverseTransition),
    curve: navigationCurve,
    reverseCurve: navigationReverseCurve,
  );

  /// 中途改目标时按剩余距离缩短时长；无动画模式必须同步完成。
  static Duration interruptedDuration({
    required Duration fullDuration,
    required double from,
    required double to,
    required bool disableAnimations,
    Duration minimumDuration = Duration.zero,
  }) {
    if (disableAnimations) return Duration.zero;
    final double distance = (to - from).abs().clamp(0, 1);
    final int scaledMicroseconds = (fullDuration.inMicroseconds * distance).round();
    return Duration(
      microseconds: scaledMicroseconds < minimumDuration.inMicroseconds ? minimumDuration.inMicroseconds : scaledMicroseconds,
    );
  }
}
