/// 适配框架内部生成的悬停提示与 AppBar 表面；保留原控件 key、动作、焦点及无障碍名称。
/// 原生提示关闭后由共享 RawTooltip 恢复静态语义与提示，避免仅隐藏 Tooltip 时丢失按钮名称。
/// Flutter 升级时同步核对 AppBar 的公开参数转发，避免遗漏新增的宿主配置。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';
import 'motion_tooltip.dart';

class MotionIconButtonSurface extends StatelessWidget {
  const MotionIconButtonSurface({required this.child, super.key});
  final IconButton child;
  @override
  Widget build(BuildContext context) =>
      child.tooltip == null || child.tooltip!.isEmpty
      ? child
      : MotionTooltip(
          message: child.tooltip!,
          childProvidesTooltip: true,
          child: child,
        );
}

class MotionPopupMenuSurface extends StatelessWidget {
  const MotionPopupMenuSurface({required this.child, super.key});
  final PopupMenuButton<dynamic> child;
  @override
  Widget build(BuildContext context) => MotionTooltip(
    message: child.tooltip ?? MaterialLocalizations.of(context).showMenuTooltip,
    childProvidesTooltip: true,
    child: child,
  );
}

class MotionAppBarSurface extends StatelessWidget
    implements PreferredSizeWidget {
  const MotionAppBarSurface({required this.child, super.key});
  final AppBar child;
  @override
  Size get preferredSize => child.preferredSize;
  @override
  Widget build(BuildContext context) {
    final disabled = motionDisabled(context);
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final scaffold = Scaffold.maybeOf(context);
    final route = ModalRoute.of(context);
    Widget label(String message, Widget button) => MotionTooltip(
      message: message,
      childProvidesTooltip: true,
      child: button,
    );
    Widget? leading = child.leading;
    if (leading == null && child.automaticallyImplyLeading) {
      if (scaffold?.hasDrawer ?? false) {
        leading = label(
          localizations.openAppDrawerTooltip,
          const DrawerButton(),
        );
      } else if (route?.impliesAppBarDismissal ?? false) {
        leading = route?.fullscreenDialog == true
            ? label(localizations.closeButtonTooltip, const CloseButton())
            : label(localizations.backButtonTooltip, const BackButton());
      }
    }
    final actions =
        child.actions ??
        (child.automaticallyImplyActions && (scaffold?.hasEndDrawer ?? false)
            ? [
                label(
                  localizations.openAppDrawerTooltip,
                  const EndDrawerButton(),
                ),
              ]
            : null);
    final background = child.forceMaterialTransparency
        ? Colors.transparent
        : child.backgroundColor ??
              theme.appBarTheme.backgroundColor ??
              (theme.useMaterial3
                  ? theme.colorScheme.surface
                  : theme.colorScheme.primary);
    return MotionTheme(
      data: theme,
      child: ColoredBox(
        color: disabled ? background : Colors.transparent,
        child: AppBar(
          key: child.key,
          leading: leading,
          automaticallyImplyLeading: child.automaticallyImplyLeading,
          title: child.title,
          actions: actions,
          automaticallyImplyActions: child.automaticallyImplyActions,
          flexibleSpace: child.flexibleSpace,
          bottom: child.bottom,
          elevation: child.elevation,
          scrolledUnderElevation: child.scrolledUnderElevation,
          notificationPredicate: child.notificationPredicate,
          shadowColor: child.shadowColor,
          surfaceTintColor: child.surfaceTintColor,
          shape: child.shape,
          backgroundColor: child.backgroundColor,
          foregroundColor: child.foregroundColor,
          iconTheme: child.iconTheme,
          actionsIconTheme: child.actionsIconTheme,
          primary: child.primary,
          centerTitle: child.centerTitle,
          excludeHeaderSemantics: child.excludeHeaderSemantics,
          titleSpacing: child.titleSpacing,
          toolbarOpacity: child.toolbarOpacity,
          bottomOpacity: child.bottomOpacity,
          toolbarHeight: child.toolbarHeight,
          leadingWidth: child.leadingWidth,
          toolbarTextStyle: child.toolbarTextStyle,
          titleTextStyle: child.titleTextStyle,
          systemOverlayStyle: child.systemOverlayStyle,
          forceMaterialTransparency:
              disabled || child.forceMaterialTransparency,
          useDefaultSemanticsOrder: child.useDefaultSemanticsOrder,
          clipBehavior: child.clipBehavior,
          actionsPadding: child.actionsPadding,
          animateColor: !disabled && child.animateColor,
        ),
      ),
    );
  }
}
