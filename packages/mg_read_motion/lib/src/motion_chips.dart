/// 筛选标签的静态选择/按压分支，避免 RawChip 的固定按压阴影控制器绕过零时长选择动画。
/// 选择、焦点和键盘动作即时提交，正常模式继续使用原生 Chip。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';
import 'motion_switch.dart';

class MotionChoiceChip extends ChoiceChip {
  const MotionChoiceChip({
    required super.label,
    required super.selected,
    super.key,
    super.onSelected,
    super.avatar,
    super.labelStyle,
    super.labelPadding,
    super.padding,
    super.showCheckmark,
    super.shape,
    super.side,
    super.backgroundColor,
    super.selectedColor,
    super.materialTapTargetSize,
    super.visualDensity,
    super.color,
    super.chipAnimationStyle,
    super.focusNode,
    super.autofocus,
  });
  @override
  Widget build(BuildContext context) => MotionControlFocus(
    focusNode: focusNode,
    builder: (context, node) {
      if (!motionDisabled(context)) {
        return ChoiceChip(
          label: label,
          selected: selected,
          onSelected: onSelected,
          avatar: avatar,
          labelStyle: labelStyle,
          labelPadding: labelPadding,
          padding: padding,
          showCheckmark: showCheckmark,
          shape: shape,
          side: side,
          backgroundColor: backgroundColor,
          selectedColor: selectedColor,
          materialTapTargetSize: materialTapTargetSize,
          visualDensity: visualDensity,
          color: color,
          chipAnimationStyle: chipAnimationStyle,
          focusNode: node,
          autofocus: autofocus,
        );
      }
      return StaticToggleAction(
        value: selected,
        selected: selected,
        button: true,
        focusNode: node,
        autofocus: autofocus,
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        child: _ChipSurface(
          label: label,
          avatar: avatar,
          selected: selected,
          enabled: onSelected != null,
          labelStyle: labelStyle,
          labelPadding: labelPadding,
          padding: padding,
          showCheckmark: showCheckmark,
          shape: shape,
          side: side,
          backgroundColor: backgroundColor,
          selectedColor: selectedColor,
          color: color,
          tapTarget: materialTapTargetSize,
        ),
      );
    },
  );
}

class MotionFilterChip extends FilterChip {
  const MotionFilterChip({
    required super.label,
    required super.selected,
    super.key,
    super.onSelected,
    super.avatar,
    super.labelStyle,
    super.labelPadding,
    super.padding,
    super.showCheckmark,
    super.shape,
    super.side,
    super.backgroundColor,
    super.selectedColor,
    super.materialTapTargetSize,
    super.visualDensity,
    super.color,
    super.chipAnimationStyle,
    super.focusNode,
    super.autofocus,
  });
  @override
  Widget build(BuildContext context) => MotionControlFocus(
    focusNode: focusNode,
    builder: (context, node) {
      if (!motionDisabled(context)) {
        return FilterChip(
          label: label,
          selected: selected,
          onSelected: onSelected,
          avatar: avatar,
          labelStyle: labelStyle,
          labelPadding: labelPadding,
          padding: padding,
          showCheckmark: showCheckmark,
          shape: shape,
          side: side,
          backgroundColor: backgroundColor,
          selectedColor: selectedColor,
          materialTapTargetSize: materialTapTargetSize,
          visualDensity: visualDensity,
          color: color,
          chipAnimationStyle: chipAnimationStyle,
          focusNode: node,
          autofocus: autofocus,
        );
      }
      return StaticToggleAction(
        value: selected,
        selected: selected,
        button: true,
        focusNode: node,
        autofocus: autofocus,
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        child: _ChipSurface(
          label: label,
          avatar: avatar,
          selected: selected,
          enabled: onSelected != null,
          labelStyle: labelStyle,
          labelPadding: labelPadding,
          padding: padding,
          showCheckmark: showCheckmark,
          shape: shape,
          side: side,
          backgroundColor: backgroundColor,
          selectedColor: selectedColor,
          color: color,
          tapTarget: materialTapTargetSize,
        ),
      );
    },
  );
}

class _ChipSurface extends StatelessWidget {
  const _ChipSurface({
    required this.label,
    required this.avatar,
    required this.selected,
    required this.enabled,
    required this.labelStyle,
    required this.labelPadding,
    required this.padding,
    required this.showCheckmark,
    required this.shape,
    required this.side,
    required this.backgroundColor,
    required this.selectedColor,
    required this.color,
    required this.tapTarget,
  });
  final Widget label;
  final Widget? avatar;
  final bool selected;
  final bool enabled;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? labelPadding;
  final EdgeInsetsGeometry? padding;
  final bool? showCheckmark;
  final OutlinedBorder? shape;
  final BorderSide? side;
  final Color? backgroundColor;
  final Color? selectedColor;
  final WidgetStateProperty<Color?>? color;
  final MaterialTapTargetSize? tapTarget;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = ChipTheme.of(context);
    final states = <WidgetState>{
      if (selected) WidgetState.selected,
      if (!enabled) WidgetState.disabled,
    };
    final fill =
        color?.resolve(states) ??
        (!enabled
            ? chip.disabledColor
            : selected
            ? selectedColor ?? chip.selectedColor
            : backgroundColor ?? chip.backgroundColor) ??
        (selected
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.surface);
    final textStyle =
        labelStyle ??
        (selected ? chip.secondaryLabelStyle : chip.labelStyle) ??
        theme.textTheme.labelLarge!;
    final mark = selected && (showCheckmark ?? true)
        ? Icon(Icons.check, size: 18, color: textStyle.color)
        : avatar;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight:
            (tapTarget ?? theme.materialTapTargetSize) ==
                MaterialTapTargetSize.padded
            ? 48
            : 0,
      ),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          padding: padding ?? chip.padding ?? const EdgeInsets.all(4),
          decoration: ShapeDecoration(
            color: fill,
            shape: (shape ?? chip.shape ?? const StadiumBorder()).copyWith(
              side: side ?? chip.side ?? BorderSide.none,
            ),
          ),
          child: Padding(
            padding:
                labelPadding ??
                chip.labelPadding ??
                const EdgeInsets.symmetric(horizontal: 8),
            child: DefaultTextStyle(
              style: textStyle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mark != null) ...[
                    ExcludeSemantics(child: mark),
                    const SizedBox(width: 6),
                  ],
                  label,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
