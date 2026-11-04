/// Adaptive source-management overlays. TV uses a spacious remote focus scope;
/// mobile keeps bottom sheets. Callers retain all selection and IO ownership.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

Future<T?> showSourceManagementSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  if (!TvModeScope.isEnabled(context)) {
    return showModalBottomSheet<T>(context: context, isScrollControlled: true, showDragHandle: true, builder: builder);
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: TvFocusRegion(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Builder(builder: builder),
          ),
        ),
      ),
    ),
  );
}

Future<T?> showSourceManagementDialog<T>({required BuildContext context, required WidgetBuilder builder}) => showDialog<T>(
  context: context,
  builder: (context) => TvFocusRegion(child: Builder(builder: builder)),
);

/// Read-only cards become remote stops so long diagnostics/help remain readable.
/// OK has no side effects; directional traversal reveals the next section.
class SourceManagementInfo extends StatelessWidget {
  const SourceManagementInfo({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => TvModeScope.isEnabled(context)
      ? TvFocusable(
          onPressed: () {},
          child: ExcludeFocus(child: child),
        )
      : child;
}
