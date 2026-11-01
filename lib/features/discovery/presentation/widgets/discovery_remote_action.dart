/// Unifies TV discovery actions without adding a second nested focus target.
/// The existing pointer surface and ordinary layout remain caller-owned.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

double discoveryRemoteMetadataExtent(BuildContext context) {
  final text = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  double height(TextStyle? style) => scaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.5);
  return height(text.titleSmall) + height(text.bodySmall) + 16;
}

class DiscoveryRemoteAction extends StatelessWidget {
  const DiscoveryRemoteAction({required this.onPressed, required this.child, this.label, super.key});

  final VoidCallback onPressed;
  final Widget child;
  final String? label;

  @override
  Widget build(BuildContext context) => TvModeScope.isEnabled(context)
      ? TvFocusable(
          onPressed: onPressed,
          label: label,
          padding: EdgeInsets.zero,
          child: ExcludeFocus(child: IgnorePointer(child: child)),
        )
      : child;
}
