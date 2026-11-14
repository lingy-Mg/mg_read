/// 开关的正常 Material/自适应展示与无动画静态展示；静态分支没有动画控制器。
/// 焦点、键盘、触摸与语义由本控件持有，不因值或动效策略变化重建业务状态。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionSwitch extends Switch {
  const MotionSwitch({
    required super.value,
    required super.onChanged,
    super.activeTrackColor,
    super.focusNode,
    super.autofocus,
    super.key,
  }) : adaptive = false;
  const MotionSwitch.adaptive({
    required super.value,
    required super.onChanged,
    super.activeTrackColor,
    super.focusNode,
    super.autofocus,
    super.key,
  }) : adaptive = true;
  final bool adaptive;
  @override
  Widget build(BuildContext context) =>
      MotionControlFocus(focusNode: focusNode, builder: _build);
  Widget _build(BuildContext context, FocusNode node) {
    if (!motionDisabled(context)) {
      return adaptive
          ? Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeTrackColor: activeTrackColor,
              focusNode: node,
              autofocus: autofocus,
            )
          : Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: activeTrackColor,
              focusNode: node,
              autofocus: autofocus,
            );
    }
    return StaticToggleAction(
      value: value,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      focusNode: node,
      autofocus: autofocus,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: StaticSwitchMark(
            value: value,
            enabled: onChanged != null,
            activeTrackColor: activeTrackColor,
          ),
        ),
      ),
    );
  }
}

/// 在常规/静态分支之间保留同一焦点节点，策略改变不丢失键盘操作目标。
class MotionControlFocus extends StatefulWidget {
  const MotionControlFocus({required this.builder, this.focusNode, super.key});
  final Widget Function(BuildContext, FocusNode) builder;
  final FocusNode? focusNode;
  @override
  State<MotionControlFocus> createState() => _MotionControlFocusState();
}

class _MotionControlFocusState extends State<MotionControlFocus> {
  final _owned = FocusNode();
  @override
  void dispose() {
    _owned.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.focusNode ?? _owned);
}

/// 内部共享静态点击表面；只在焦点真实变化时刷新边框。
class StaticToggleAction extends StatefulWidget {
  const StaticToggleAction({
    required this.value,
    required this.onTap,
    required this.child,
    this.checkbox = false,
    this.selected,
    this.button = false,
    this.focusNode,
    this.autofocus = false,
    this.onLongPress,
    this.onFocusChange,
    super.key,
  });
  final bool? value;
  final VoidCallback? onTap;
  final Widget child;
  final bool checkbox;
  final bool? selected;
  final bool button;
  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onLongPress;
  final ValueChanged<bool>? onFocusChange;
  @override
  State<StaticToggleAction> createState() => _StaticToggleActionState();
}

class _StaticToggleActionState extends State<StaticToggleAction> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => Semantics(
    enabled: widget.onTap != null || widget.onLongPress != null,
    toggled: widget.checkbox || widget.selected != null ? null : widget.value,
    selected: widget.selected,
    button: widget.button,
    checked: widget.checkbox ? widget.value == true : null,
    mixed: widget.checkbox && widget.value == null,
    onTap: widget.onTap,
    onLongPress: widget.onLongPress,
    child: FocusableActionDetector(
      enabled: widget.onTap != null || widget.onLongPress != null,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: widget.onFocusChange,
      mouseCursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onShowFocusHighlight: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: _focused
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}

class StaticSwitchMark extends StatelessWidget {
  const StaticSwitchMark({
    required this.value,
    required this.enabled,
    this.activeTrackColor,
    this.activeThumbColor,
    this.inactiveTrackColor,
    this.inactiveThumbColor,
    this.trackOutlineColor,
    super.key,
  });
  final bool value;
  final bool enabled;
  final Color? activeTrackColor;
  final Color? activeThumbColor;
  final Color? inactiveTrackColor;
  final Color? inactiveThumbColor;
  final WidgetStateProperty<Color?>? trackOutlineColor;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final states = <WidgetState>{
      if (value) WidgetState.selected,
      if (!enabled) WidgetState.disabled,
    };
    final track =
        (value ? activeTrackColor : inactiveTrackColor) ??
        theme.switchTheme.trackColor?.resolve(states) ??
        (value ? colors.primary : colors.surfaceContainerHighest);
    final thumb =
        (value ? activeThumbColor : inactiveThumbColor) ??
        theme.switchTheme.thumbColor?.resolve(states) ??
        (value ? colors.onPrimary : colors.outline);
    return Opacity(
      opacity: enabled ? 1 : .38,
      child: Container(
        width: 46,
        height: 28,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: track,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color:
                trackOutlineColor?.resolve(states) ??
                (value ? track : colors.outline),
          ),
        ),
        child: Align(
          alignment: value
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(color: thumb, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
