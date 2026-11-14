/// 设置开关与复选列表项的静态分支；保留整行触摸、合并语义和稳定焦点。
/// 正常模式复用 Flutter 实现，无动画分支直接绘制目标值，不冻结框架控制器。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';
import 'motion_switch.dart';

class MotionSwitchListTile extends SwitchListTile {
  const MotionSwitchListTile({
    required super.value,
    required super.onChanged,
    super.key,
    super.title,
    super.subtitle,
    super.secondary,
    super.contentPadding,
    super.dense,
    super.minTileHeight,
    super.visualDensity,
    super.materialTapTargetSize,
    super.activeThumbColor,
    super.activeTrackColor,
    super.inactiveThumbColor,
    super.inactiveTrackColor,
    super.trackOutlineColor,
    super.shape,
    super.focusNode,
    super.autofocus,
  }) : _adaptive = false;
  const MotionSwitchListTile.adaptive({
    required super.value,
    required super.onChanged,
    super.key,
    super.title,
    super.subtitle,
    super.secondary,
    super.contentPadding,
    super.dense,
    super.minTileHeight,
    super.visualDensity,
    super.materialTapTargetSize,
    super.activeThumbColor,
    super.activeTrackColor,
    super.inactiveThumbColor,
    super.inactiveTrackColor,
    super.trackOutlineColor,
    super.shape,
    super.focusNode,
    super.autofocus,
  }) : _adaptive = true;
  final bool _adaptive;
  @override
  Widget build(BuildContext context) =>
      MotionControlFocus(focusNode: focusNode, builder: _build);
  Widget _build(BuildContext context, FocusNode node) {
    if (!motionDisabled(context)) {
      final tile = _adaptive ? SwitchListTile.adaptive : SwitchListTile.new;
      return tile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        secondary: secondary,
        contentPadding: contentPadding,
        dense: dense,
        minTileHeight: minTileHeight,
        visualDensity: visualDensity,
        materialTapTargetSize: materialTapTargetSize,
        activeThumbColor: activeThumbColor,
        activeTrackColor: activeTrackColor,
        inactiveThumbColor: inactiveThumbColor,
        inactiveTrackColor: inactiveTrackColor,
        trackOutlineColor: trackOutlineColor,
        shape: shape,
        focusNode: node,
        autofocus: autofocus,
      );
    }
    return StaticToggleAction(
      value: value,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      focusNode: node,
      autofocus: autofocus,
      child: _StaticTile(
        title: title,
        subtitle: subtitle,
        leading: secondary,
        padding: contentPadding,
        minHeight: minTileHeight,
        control: StaticSwitchMark(
          value: value,
          enabled: onChanged != null,
          activeThumbColor: activeThumbColor,
          activeTrackColor: activeTrackColor,
          inactiveThumbColor: inactiveThumbColor,
          inactiveTrackColor: inactiveTrackColor,
          trackOutlineColor: trackOutlineColor,
        ),
      ),
    );
  }
}

class MotionCheckboxListTile extends CheckboxListTile {
  const MotionCheckboxListTile({
    required super.value,
    required super.onChanged,
    super.key,
    super.title,
    super.subtitle,
    super.contentPadding,
    super.controlAffinity,
    super.dense,
    super.isThreeLine,
    super.tristate = false,
    super.visualDensity,
    super.focusNode,
    super.autofocus,
  });
  @override
  Widget build(BuildContext context) =>
      MotionControlFocus(focusNode: focusNode, builder: _build);
  Widget _build(BuildContext context, FocusNode node) {
    if (!motionDisabled(context)) {
      return CheckboxListTile(
        value: value,
        onChanged: onChanged,
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        controlAffinity: controlAffinity,
        dense: dense,
        isThreeLine: isThreeLine,
        tristate: tristate,
        visualDensity: visualDensity,
        focusNode: node,
        autofocus: autofocus,
      );
    }
    final enabled = onChanged != null;
    final colors = Theme.of(context).colorScheme;
    final control = SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: Icon(
          value == null
              ? Icons.indeterminate_check_box
              : value!
              ? Icons.check_box
              : Icons.check_box_outline_blank,
          color: enabled
              ? (value == false ? colors.onSurfaceVariant : colors.primary)
              : colors.onSurface.withValues(alpha: .38),
        ),
      ),
    );
    return StaticToggleAction(
      value: value,
      checkbox: true,
      focusNode: node,
      autofocus: autofocus,
      onTap: enabled
          ? () => onChanged!(
              tristate
                  ? (value == false
                        ? true
                        : value == true
                        ? null
                        : false)
                  : !(value ?? false),
            )
          : null,
      child: _StaticTile(
        title: title,
        subtitle: subtitle,
        padding: contentPadding,
        control: control,
        leadingControl: controlAffinity == ListTileControlAffinity.leading,
      ),
    );
  }
}

class _StaticTile extends StatelessWidget {
  const _StaticTile({
    required this.title,
    required this.subtitle,
    required this.control,
    this.leading,
    this.padding,
    this.minHeight,
    this.leadingControl = false,
  });
  final Widget? title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget control;
  final EdgeInsetsGeometry? padding;
  final double? minHeight;
  final bool leadingControl;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight ?? (subtitle == null ? 48 : 64),
      ),
      child: Padding(
        padding:
            padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            if (leadingControl) ...[
              ExcludeSemantics(child: control),
              const SizedBox(width: 12),
            ],
            if (leading != null) ...[leading!, const SizedBox(width: 16)],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    DefaultTextStyle(
                      style:
                          theme.listTileTheme.titleTextStyle ??
                          theme.textTheme.bodyLarge!,
                      child: title!,
                    ),
                  if (subtitle != null)
                    DefaultTextStyle(
                      style:
                          theme.listTileTheme.subtitleTextStyle ??
                          theme.textTheme.bodyMedium!,
                      child: subtitle!,
                    ),
                ],
              ),
            ),
            if (!leadingControl) ...[
              const SizedBox(width: 12),
              ExcludeSemantics(child: control),
            ],
          ],
        ),
      ),
    );
  }
}
