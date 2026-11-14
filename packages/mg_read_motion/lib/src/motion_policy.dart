/// 共享动效策略、Material 主题和提示条入口；不改变提示时长、业务进度或宿主设置。
library;

import 'package:flutter/material.dart';
import 'motion_scroll.dart';

bool motionDisabled(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

ThemeData motionThemeData(ThemeData theme, {required bool disabled}) {
  if (!disabled) return theme;
  ButtonStyle immediate(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        animationDuration: Duration.zero,
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      );
  return theme.copyWith(
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    expansionTileTheme: theme.expansionTileTheme.copyWith(
      expansionAnimationStyle: AnimationStyle.noAnimation,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: immediate(theme.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: immediate(theme.elevatedButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: immediate(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: immediate(theme.textButtonTheme.style),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: immediate(theme.iconButtonTheme.style),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: immediate(theme.segmentedButtonTheme.style),
    ),
  );
}

/// 应用局部主题之后再次解析策略，独立 package 也能关闭框架按钮和墨水反馈。
class MotionTheme extends StatelessWidget {
  const MotionTheme({required this.data, required this.child, super.key});
  final ThemeData data;
  final Widget child;
  @override
  Widget build(BuildContext context) => Theme(
    data: motionThemeData(data, disabled: motionDisabled(context)),
    child: TooltipVisibility(
      visible: !motionDisabled(context),
      child: MotionScrollScope(child: child),
    ),
  );
}

/// Navigator 覆盖层可能位于调用方的局部 MediaQuery 之外，显式携带策略并在新上下文内构建内容。
WidgetBuilder motionOverlayBuilder(BuildContext origin, WidgetBuilder builder) {
  final disabled = motionDisabled(origin);
  return (context) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(disableAnimations: disabled || motionDisabled(context)),
    child: MotionTheme(
      data: Theme.of(context),
      child: Builder(builder: builder),
    ),
  );
}

extension MotionScaffoldMessenger on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showMotionSnackBar(
    BuildContext context,
    SnackBar snackBar,
  ) => showSnackBar(
    SnackBar(
      key: snackBar.key,
      content: _MotionSnackBarContent(child: snackBar.content),
      backgroundColor: snackBar.backgroundColor,
      elevation: snackBar.elevation,
      margin: snackBar.margin,
      padding: snackBar.padding,
      width: snackBar.width,
      shape: snackBar.shape,
      hitTestBehavior: snackBar.hitTestBehavior,
      behavior: snackBar.behavior,
      action: snackBar.action == null
          ? null
          : _MotionSnackBarAction(snackBar.action!),
      actionOverflowThreshold: snackBar.actionOverflowThreshold,
      showCloseIcon: snackBar.showCloseIcon,
      closeIconColor: snackBar.closeIconColor,
      duration: snackBar.duration,
      persist: snackBar.persist,
      onVisible: snackBar.onVisible,
      dismissDirection: motionDisabled(context)
          ? DismissDirection.none
          : snackBar.dismissDirection,
      clipBehavior: snackBar.clipBehavior,
    ),
    snackBarAnimationStyle: motionDisabled(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            duration: Duration(milliseconds: 250),
            reverseDuration: Duration(milliseconds: 250),
          ),
  );
}

class _MotionSnackBarAction extends SnackBarAction {
  _MotionSnackBarAction(SnackBarAction action)
    : super(
        label: action.label,
        onPressed: action.onPressed,
        textColor: action.textColor,
        backgroundColor: action.backgroundColor,
        disabledTextColor: action.disabledTextColor,
        disabledBackgroundColor: action.disabledBackgroundColor,
      );
  @override
  State<SnackBarAction> createState() => _MotionSnackBarActionState();
}

class _MotionSnackBarActionState extends State<SnackBarAction> {
  bool _triggered = false;
  @override
  Widget build(BuildContext context) {
    if (!motionDisabled(context)) {
      return SnackBarAction(
        label: widget.label,
        onPressed: widget.onPressed,
        textColor: widget.textColor,
        backgroundColor: widget.backgroundColor,
        disabledTextColor: widget.disabledTextColor,
        disabledBackgroundColor: widget.disabledBackgroundColor,
      );
    }
    final theme = Theme.of(context);
    return TextButton(
      style: TextButton.styleFrom(
        animationDuration: Duration.zero,
        splashFactory: NoSplash.splashFactory,
        overlayColor: Colors.transparent,
        foregroundColor:
            widget.textColor ??
            theme.snackBarTheme.actionTextColor ??
            theme.colorScheme.inversePrimary,
        backgroundColor:
            widget.backgroundColor ?? theme.snackBarTheme.actionBackgroundColor,
      ),
      onPressed: _triggered
          ? null
          : () {
              setState(() => _triggered = true);
              widget.onPressed();
              ScaffoldMessenger.of(
                context,
              ).hideCurrentSnackBar(reason: SnackBarClosedReason.action);
            },
      child: Text(widget.label),
    );
  }
}

/// 正在展示的提示条也消费偏好变化；结束当前过渡并令之后的关闭即时完成。
class _MotionSnackBarContent extends StatefulWidget {
  const _MotionSnackBarContent({required this.child});
  final Widget child;
  @override
  State<_MotionSnackBarContent> createState() => _MotionSnackBarContentState();
}

class _MotionSnackBarContentState extends State<_MotionSnackBarContent> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!motionDisabled(context)) return;
    final animation = context
        .findAncestorWidgetOfExactType<SnackBar>()
        ?.animation;
    if (animation is! AnimationController) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !motionDisabled(context)) return;
      animation.duration = Duration.zero;
      animation.reverseDuration = Duration.zero;
      if (animation.isAnimating) {
        animation.value = animation.status == AnimationStatus.reverse ? 0 : 1;
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

ChipAnimationStyle? motionChipAnimationStyle(BuildContext context) =>
    motionDisabled(context)
    ? ChipAnimationStyle(
        enableAnimation: AnimationStyle.noAnimation,
        selectAnimation: AnimationStyle.noAnimation,
        avatarDrawerAnimation: AnimationStyle.noAnimation,
        deleteDrawerAnimation: AnimationStyle.noAnimation,
      )
    : null;
