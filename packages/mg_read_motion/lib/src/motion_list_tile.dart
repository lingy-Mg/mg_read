/// 列表项静态布局；Flutter ListTile 的文字样式过渡时长不可配置，静态分支直接绘制目标样式。
/// 不拥有数据或 IO；保留行点击、长按、子控件动作、焦点、选中语义与调用方最小高度。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';
import 'motion_surfaces.dart';
import 'motion_switch.dart';

class MotionListTile extends ListTile {
  const MotionListTile({
    super.key,
    super.leading,
    super.title,
    super.subtitle,
    super.trailing,
    super.isThreeLine,
    super.dense,
    super.visualDensity,
    super.shape,
    super.style,
    super.selectedColor,
    super.iconColor,
    super.textColor,
    super.titleTextStyle,
    super.subtitleTextStyle,
    super.leadingAndTrailingTextStyle,
    super.contentPadding,
    super.enabled,
    super.onTap,
    super.onLongPress,
    super.onFocusChange,
    super.mouseCursor,
    super.selected,
    super.focusColor,
    super.hoverColor,
    super.splashColor,
    super.focusNode,
    super.autofocus,
    super.tileColor,
    super.selectedTileColor,
    super.enableFeedback,
    super.horizontalTitleGap,
    super.minVerticalPadding,
    super.minLeadingWidth,
    super.minTileHeight,
    super.titleAlignment,
    super.internalAddSemanticForOnTap,
    super.statesController,
  });

  @override
  Widget build(BuildContext context) => MotionControlFocus(
    focusNode: focusNode,
    builder: (context, node) => motionDisabled(context)
        ? _static(context, node)
        : ListTile(
            leading: leading,
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            isThreeLine: isThreeLine,
            dense: dense,
            visualDensity: visualDensity,
            shape: shape,
            style: style,
            selectedColor: selectedColor,
            iconColor: iconColor,
            textColor: textColor,
            titleTextStyle: titleTextStyle,
            subtitleTextStyle: subtitleTextStyle,
            leadingAndTrailingTextStyle: leadingAndTrailingTextStyle,
            contentPadding: contentPadding,
            enabled: enabled,
            onTap: onTap,
            onLongPress: onLongPress,
            onFocusChange: onFocusChange,
            mouseCursor: mouseCursor,
            selected: selected,
            focusColor: focusColor,
            hoverColor: hoverColor,
            splashColor: splashColor,
            focusNode: node,
            autofocus: autofocus,
            tileColor: tileColor,
            selectedTileColor: selectedTileColor,
            enableFeedback: enableFeedback,
            horizontalTitleGap: horizontalTitleGap,
            minVerticalPadding: minVerticalPadding,
            minLeadingWidth: minLeadingWidth,
            minTileHeight: minTileHeight,
            titleAlignment: titleAlignment,
            internalAddSemanticForOnTap: internalAddSemanticForOnTap,
            statesController: statesController,
          ),
  );

  Widget _static(BuildContext context, FocusNode node) {
    final theme = Theme.of(context);
    final tiles = ListTileTheme.of(context);
    final compact = dense ?? tiles.dense ?? false;
    final states = <WidgetState>{
      if (!enabled) WidgetState.disabled,
      if (selected) WidgetState.selected,
    };
    Color? resolve(Color? color) =>
        WidgetStateProperty.resolveAs<Color?>(color, states);
    Color? foreground(Color? color, Color? fallback) =>
        resolve(color) ??
        (!enabled
            ? theme.disabledColor
            : selected
            ? resolve(selectedColor ?? tiles.selectedColor) ??
                  theme.colorScheme.primary
            : resolve(fallback));
    final text = foreground(textColor, tiles.textColor);
    final icon =
        foreground(iconColor, tiles.iconColor) ??
        theme.colorScheme.onSurfaceVariant;
    final titleStyle =
        (titleTextStyle ?? tiles.titleTextStyle ?? theme.textTheme.bodyLarge!)
            .copyWith(color: text, fontSize: compact ? 13 : null);
    final subtitleStyle =
        (subtitleTextStyle ??
                tiles.subtitleTextStyle ??
                theme.textTheme.bodyMedium!.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ))
            .copyWith(color: text, fontSize: compact ? 12 : null);
    final sideStyle =
        (leadingAndTrailingTextStyle ??
                tiles.leadingAndTrailingTextStyle ??
                theme.textTheme.labelSmall!)
            .copyWith(color: text ?? icon);
    final gap = horizontalTitleGap ?? tiles.horizontalTitleGap ?? 16;
    final density = visualDensity ?? tiles.visualDensity ?? theme.visualDensity;
    final height =
        minTileHeight ??
        tiles.minTileHeight ??
        ((isThreeLine ?? false)
            ? (compact ? 76.0 : 88.0)
            : subtitle != null
            ? (compact ? 64.0 : 72.0)
            : (compact ? 48.0 : 56.0));
    Widget side(Widget child) => IconTheme.merge(
      data: IconThemeData(color: icon),
      child: DefaultTextStyle(style: sideStyle, child: child),
    );
    final row = Padding(
      padding:
          contentPadding ??
          tiles.contentPadding ??
          EdgeInsetsDirectional.only(
            start: 16,
            end: theme.useMaterial3 ? 24 : 16,
          ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (height + density.baseSizeAdjustment.dy).clamp(
            0,
            double.infinity,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            vertical:
                minVerticalPadding ??
                tiles.minVerticalPadding ??
                (theme.useMaterial3 ? 8 : 4),
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth:
                        minLeadingWidth ??
                        tiles.minLeadingWidth ??
                        (theme.useMaterial3 ? 24 : 40),
                  ),
                  child: side(leading!),
                ),
                SizedBox(width: gap),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      DefaultTextStyle(style: titleStyle, child: title!),
                    if (subtitle != null)
                      DefaultTextStyle(style: subtitleStyle, child: subtitle!),
                  ],
                ),
              ),
              if (trailing != null) ...[SizedBox(width: gap), side(trailing!)],
            ],
          ),
        ),
      ),
    );
    final interactive = onTap != null || onLongPress != null;
    return MotionMaterial(
      type: MaterialType.transparency,
      child: Ink(
        decoration: ShapeDecoration(
          color:
              (selected
                  ? selectedTileColor ?? tiles.selectedTileColor
                  : tileColor ?? tiles.tileColor) ??
              Colors.transparent,
          shape: shape ?? tiles.shape ?? const RoundedRectangleBorder(),
        ),
        child: interactive
            ? StaticToggleAction(
                value: null,
                selected: selected,
                button: internalAddSemanticForOnTap,
                onTap: enabled ? onTap : null,
                onLongPress: enabled ? onLongPress : null,
                onFocusChange: onFocusChange,
                focusNode: node,
                autofocus: autofocus,
                child: row,
              )
            : Semantics(enabled: enabled, selected: selected, child: row),
      ),
    );
  }
}
