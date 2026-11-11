/// Adaptive source-management overlays. TV uses a spacious remote focus scope;
/// mobile keeps bottom sheets. Callers retain all selection and IO ownership.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'source_management_tv_layout.dart';
export 'source_management_tv_layout.dart';

Future<T?> showSourceManagementSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  if (!TvModeScope.isEnabled(context)) {
    return showModalBottomSheet<T>(
      context: context,
      sheetAnimationStyle: AppMotion.overlayStyle(context),
      isScrollControlled: true,
      showDragHandle: true,
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    animationStyle: AppMotion.overlayStyle(context),
    builder: (context) => Dialog.fullscreen(
      child: TvFocusRegion(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Builder(builder: builder),
          ),
        ),
      ),
    ),
  );
}

Future<T?> showSourceManagementDialog<T>({required BuildContext context, required WidgetBuilder builder}) => showDialog<T>(
  context: context,
  animationStyle: AppMotion.overlayStyle(context),
  builder: (context) => TvFocusRegion(child: Builder(builder: builder)),
);

/// TV confirmations keep actions outside the reading viewport. The caller still
/// owns result values and mutations; the first action is the safe default.
class SourceManagementDialog extends StatelessWidget {
  const SourceManagementDialog({required this.title, required this.content, required this.actions, this.destructive = false, super.key});
  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    if (!TvModeScope.isEnabled(context)) return AlertDialog(title: title, content: content, actions: actions);
    return Dialog(
      backgroundColor: AppThemeTokens.of(context).surface,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 1000, maxHeight: MediaQuery.sizeOf(context).height - 64),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle(style: Theme.of(context).textTheme.titleLarge!, child: title),
              const SizedBox(height: 12),
              Flexible(
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.bodyLarge!,
                  child: TvSourceScrollBody(child: content is SelectableText ? Text((content as SelectableText).data ?? '') : content),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  for (var index = 0; index < actions.length; index++)
                    _action(context, actions[index], index == 0, index == actions.length - 1),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(BuildContext context, Widget action, bool first, bool last) {
    if (action is ButtonStyleButton) {
      return TvFocusable(
        key: action.key,
        autofocus: first,
        onPressed: action.onPressed,
        child: DefaultTextStyle.merge(
          style: TextStyle(color: destructive && last ? AppThemeTokens.of(context).notification : null),
          child: action.child ?? const SizedBox.shrink(),
        ),
      );
    }
    return action;
  }
}

/// Read-only cards become remote stops so long diagnostics/help remain readable.
/// OK opens a dedicated reading viewport; directional traversal reveals sections.
class SourceManagementInfo extends StatelessWidget {
  const SourceManagementInfo({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => TvModeScope.isEnabled(context)
      ? TvFocusable(
          onPressed: () => showSourceManagementDialog<void>(
            context: context,
            builder: (context) => SourceManagementDialog(
              title: const Text('详细信息'),
              content: ExcludeFocus(child: child),
              actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('返回'))],
            ),
          ),
          child: ExcludeFocus(child: child),
        )
      : child;
}
