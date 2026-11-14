/// Material 表面的无动画适配：直接更新颜色、文字、形状与阴影，不重挂载业务子树。
/// Scaffold 自带 Material 没有时长入口，使用稳定的透明表面与外部即时背景承载，正文恢复原始主题。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionMaterial extends StatelessWidget {
  const MotionMaterial({
    this.type = MaterialType.canvas,
    this.elevation = 0,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.textStyle,
    this.borderRadius,
    this.shape,
    this.borderOnForeground = true,
    this.clipBehavior = Clip.none,
    this.animationDuration = kThemeChangeDuration,
    this.animateColor = false,
    this.child,
    super.key,
  });
  final MaterialType type;
  final double elevation;
  final Color? color;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final TextStyle? textStyle;
  final BorderRadiusGeometry? borderRadius;
  final ShapeBorder? shape;
  final bool borderOnForeground;
  final Clip clipBehavior;
  final Duration animationDuration;
  final bool animateColor;
  final Widget? child;
  @override
  Widget build(BuildContext context) => Material(
    type: type,
    elevation: elevation,
    color: color,
    shadowColor: shadowColor,
    surfaceTintColor: surfaceTintColor,
    textStyle: textStyle,
    borderRadius: borderRadius,
    shape: shape,
    borderOnForeground: borderOnForeground,
    clipBehavior: clipBehavior,
    animateColor: animateColor,
    animationDuration: motionDisabled(context)
        ? Duration.zero
        : animationDuration,
    child: child,
  );
}

class MotionCard extends StatelessWidget {
  const MotionCard({
    this.child,
    this.color,
    this.shadowColor,
    this.surfaceTintColor,
    this.elevation,
    this.shape,
    this.borderOnForeground = true,
    this.margin,
    this.clipBehavior,
    this.semanticContainer = true,
    super.key,
  });
  final Widget? child;
  final Color? color;
  final Color? shadowColor;
  final Color? surfaceTintColor;
  final double? elevation;
  final ShapeBorder? shape;
  final bool borderOnForeground;
  final EdgeInsetsGeometry? margin;
  final Clip? clipBehavior;
  final bool semanticContainer;
  @override
  Widget build(BuildContext context) =>
      _RetainedSurfaceChild(builder: _build, child: child);
  Widget _build(BuildContext context, Widget? retainedChild) {
    if (!motionDisabled(context)) {
      return Card(
        color: color,
        shadowColor: shadowColor,
        surfaceTintColor: surfaceTintColor,
        elevation: elevation,
        shape: shape,
        borderOnForeground: borderOnForeground,
        margin: margin,
        clipBehavior: clipBehavior,
        semanticContainer: semanticContainer,
        child: retainedChild,
      );
    }
    final theme = Theme.of(context);
    final card = CardTheme.of(context);
    return Semantics(
      container: semanticContainer,
      child: Padding(
        padding: margin ?? card.margin ?? const EdgeInsets.all(4),
        child: MotionMaterial(
          type: MaterialType.card,
          color: color ?? card.color ?? theme.colorScheme.surfaceContainerLow,
          shadowColor: shadowColor ?? card.shadowColor,
          surfaceTintColor: surfaceTintColor ?? card.surfaceTintColor,
          elevation: elevation ?? card.elevation ?? 1,
          shape:
              shape ??
              card.shape ??
              const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
          borderOnForeground: borderOnForeground,
          clipBehavior: clipBehavior ?? card.clipBehavior ?? Clip.none,
          child: retainedChild,
        ),
      ),
    );
  }
}

class MotionScaffold extends StatelessWidget {
  const MotionScaffold({
    this.appBar,
    this.body,
    this.backgroundColor,
    this.bottomNavigationBar,
    this.bottomSheet,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.resizeToAvoidBottomInset,
    this.extendBody = false,
    this.extendBodyBehindAppBar = false,
    this.drawer,
    this.endDrawer,
    this.onDrawerChanged,
    this.onEndDrawerChanged,
    this.drawerEnableOpenDragGesture = true,
    this.endDrawerEnableOpenDragGesture = true,
    this.persistentFooterButtons,
    super.key,
  });
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Color? backgroundColor;
  final Widget? bottomNavigationBar;
  final Widget? bottomSheet;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final bool? resizeToAvoidBottomInset;
  final bool extendBody;
  final bool extendBodyBehindAppBar;
  final Widget? drawer;
  final Widget? endDrawer;
  final DrawerCallback? onDrawerChanged;
  final DrawerCallback? onEndDrawerChanged;
  final bool drawerEnableOpenDragGesture;
  final bool endDrawerEnableOpenDragGesture;
  final List<Widget>? persistentFooterButtons;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget? content(Widget? child) => child == null
        ? null
        : Theme(
            data: theme,
            child: DefaultTextStyle(
              style: theme.textTheme.bodyMedium!,
              child: child,
            ),
          );
    // Keep this Theme and DefaultTextStyle in both modes so policy changes
    // retain Scaffold state, text inputs and all children at the same paths.
    final scaffold = Scaffold(
      appBar: appBar,
      body: content(body),
      backgroundColor: Colors.transparent,
      bottomNavigationBar: content(bottomNavigationBar),
      bottomSheet: content(bottomSheet),
      floatingActionButton: content(floatingActionButton),
      floatingActionButtonLocation: floatingActionButtonLocation,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      extendBody: extendBody,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      drawer: content(drawer),
      endDrawer: content(endDrawer),
      onDrawerChanged: onDrawerChanged,
      onEndDrawerChanged: onEndDrawerChanged,
      drawerEnableOpenDragGesture: drawerEnableOpenDragGesture,
      endDrawerEnableOpenDragGesture: endDrawerEnableOpenDragGesture,
      persistentFooterButtons: persistentFooterButtons
          ?.map((child) => content(child)!)
          .toList(),
    );
    return ColoredBox(
      color: backgroundColor ?? theme.scaffoldBackgroundColor,
      child: Theme(
        data: theme.copyWith(
          shadowColor: Colors.transparent,
          textTheme: theme.textTheme.copyWith(bodyMedium: const TextStyle()),
          appBarTheme: theme.appBarTheme.copyWith(
            toolbarTextStyle:
                theme.appBarTheme.toolbarTextStyle ??
                theme.textTheme.bodyMedium,
            titleTextStyle:
                theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge,
          ),
        ),
        child: scaffold,
      ),
    );
  }
}

class _RetainedSurfaceChild extends StatefulWidget {
  const _RetainedSurfaceChild({required this.child, required this.builder});
  final Widget? child;
  final Widget Function(BuildContext, Widget?) builder;
  @override
  State<_RetainedSurfaceChild> createState() => _RetainedSurfaceChildState();
}

class _RetainedSurfaceChildState extends State<_RetainedSurfaceChild> {
  final _anchor = GlobalKey();
  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    widget.child == null
        ? null
        : KeyedSubtree(key: _anchor, child: widget.child!),
  );
}
