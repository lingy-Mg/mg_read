/// Remote navigation for discovery and settings inputs, with no owned input state.
/// TV up/down leave the editor; left/right and modified keys retain text editing.
/// Placed inside the app's default editing shortcuts so EditableText cannot trap
/// vertical directions. Ordinary mode retains the platform's editing bindings.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

class TvTextInputNavigation extends StatelessWidget {
  const TvTextInputNavigation({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: TvModeScope.isEnabled(context)
        ? const {
            SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up, ignoreTextFields: false),
            SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down, ignoreTextFields: false),
          }
        : const {},
    child: child,
  );
}
