/// TV presentation preference and remote activation shared across routes.
/// Persistence belongs to the composition root; this scope performs no IO.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvModeScope extends InheritedWidget {
  const TvModeScope({required this.enabled, required this.onChanged, required super.child, super.key});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  static TvModeScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TvModeScope>();
  static bool isEnabled(BuildContext context) => maybeOf(context)?.enabled ?? false;

  @override
  bool updateShouldNotify(TvModeScope oldWidget) => enabled != oldWidget.enabled || onChanged != oldWidget.onChanged;
}

/// Android remotes can report Select instead of Enter for the centre button.
class TvRemoteShortcuts extends StatelessWidget {
  const TvRemoteShortcuts({required this.child, this.enabled = true, super.key});
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: !enabled
        ? const <ShortcutActivator, Intent>{}
        : const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          },
    child: child,
  );
}
