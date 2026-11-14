/// 对话框的静态表面与键盘避让；不插值背景、文字、阴影或视口 inset。
/// 内容子树跨策略切换保留；Flutter 升级时核对 AlertDialog.build 返回的公开 Dialog 配置。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';
import 'motion_surfaces.dart';

class MotionDialog extends Dialog {
  const MotionDialog({
    super.key,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.insetAnimationDuration,
    super.insetAnimationCurve,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.child,
    super.semanticsRole,
    super.constraints,
  }) : fullscreen = false;
  const MotionDialog.fullscreen({
    super.key,
    super.backgroundColor,
    super.insetAnimationDuration,
    super.insetAnimationCurve,
    super.child,
    super.semanticsRole,
  }) : fullscreen = true,
       super.fullscreen();
  final bool fullscreen;
  @override
  Widget build(BuildContext context) =>
      _DialogSurface(dialog: this, fullscreen: fullscreen);
}

class _DialogSurface extends StatefulWidget {
  const _DialogSurface({required this.dialog, this.fullscreen = false});
  final Dialog dialog;
  final bool fullscreen;
  @override
  State<_DialogSurface> createState() => _DialogSurfaceState();
}

class _DialogSurfaceState extends State<_DialogSurface> {
  final _contentKey = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final dialog = widget.dialog;
    final content = KeyedSubtree(
      key: _contentKey,
      child: dialog.child ?? const SizedBox.shrink(),
    );
    if (!motionDisabled(context)) {
      if (widget.fullscreen) {
        return Dialog.fullscreen(
          backgroundColor: dialog.backgroundColor,
          insetAnimationDuration: dialog.insetAnimationDuration,
          insetAnimationCurve: dialog.insetAnimationCurve,
          semanticsRole: dialog.semanticsRole,
          child: content,
        );
      }
      return Dialog(
        backgroundColor: dialog.backgroundColor,
        elevation: dialog.elevation,
        shadowColor: dialog.shadowColor,
        surfaceTintColor: dialog.surfaceTintColor,
        insetAnimationDuration: dialog.insetAnimationDuration,
        insetAnimationCurve: dialog.insetAnimationCurve,
        insetPadding: dialog.insetPadding,
        clipBehavior: dialog.clipBehavior,
        shape: dialog.shape,
        alignment: dialog.alignment,
        constraints: dialog.constraints,
        semanticsRole: dialog.semanticsRole,
        child: content,
      );
    }
    final theme = Theme.of(context);
    final defaults = DialogTheme.of(context);
    if (widget.fullscreen) {
      return Semantics(
        role: dialog.semanticsRole,
        child: MotionMaterial(
          color:
              dialog.backgroundColor ??
              defaults.backgroundColor ??
              theme.colorScheme.surface,
          child: content,
        ),
      );
    }
    return Semantics(
      role: dialog.semanticsRole,
      child: Padding(
        padding:
            MediaQuery.viewInsetsOf(context) +
            (dialog.insetPadding ??
                defaults.insetPadding ??
                const EdgeInsets.symmetric(horizontal: 40, vertical: 24)),
        child: MediaQuery.removeViewInsets(
          context: context,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          child: Align(
            alignment:
                dialog.alignment ?? defaults.alignment ?? Alignment.center,
            child: ConstrainedBox(
              constraints:
                  dialog.constraints ??
                  defaults.constraints ??
                  const BoxConstraints(minWidth: 280),
              child: MotionMaterial(
                type: MaterialType.card,
                color:
                    dialog.backgroundColor ??
                    defaults.backgroundColor ??
                    theme.colorScheme.surfaceContainerHigh,
                elevation:
                    dialog.elevation ??
                    defaults.elevation ??
                    (theme.useMaterial3 ? 6 : 24),
                shadowColor: dialog.shadowColor ?? defaults.shadowColor,
                surfaceTintColor:
                    dialog.surfaceTintColor ?? defaults.surfaceTintColor,
                shape:
                    dialog.shape ??
                    defaults.shape ??
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        theme.useMaterial3 ? 28 : 4,
                      ),
                    ),
                clipBehavior:
                    dialog.clipBehavior ?? defaults.clipBehavior ?? Clip.none,
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MotionAlertDialog extends AlertDialog {
  const MotionAlertDialog({
    super.key,
    super.icon,
    super.iconPadding,
    super.iconColor,
    super.title,
    super.titlePadding,
    super.titleTextStyle,
    super.content,
    super.contentPadding,
    super.contentTextStyle,
    super.actions,
    super.actionsPadding,
    super.actionsAlignment,
    super.actionsOverflowAlignment,
    super.actionsOverflowDirection,
    super.actionsOverflowButtonSpacing,
    super.buttonPadding,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.semanticLabel,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.constraints,
    super.scrollable,
  });
  @override
  Widget build(BuildContext context) =>
      _DialogSurface(dialog: super.build(context) as Dialog);
}
