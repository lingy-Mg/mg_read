/// Remote activation for TV surfaces and route-owned dialogs.
/// Direction repeats remain available; holding OK must never repeat commands.
library;

// Internal UI composition, not a public player API.
// ignore_for_file: public_member_api_docs
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VideoTvShortcuts extends StatelessWidget {
  const VideoTvShortcuts({required this.child, this.enabled = true, super.key});
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) =>
        enabled &&
            event is KeyRepeatEvent &&
            const [
              LogicalKeyboardKey.select,
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.numpadEnter,
              LogicalKeyboardKey.space,
              LogicalKeyboardKey.gameButtonA,
            ].contains(event.logicalKey)
        ? KeyEventResult.handled
        : KeyEventResult.ignored,
    child: Shortcuts(
      shortcuts: enabled
          ? const {
              SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
                  ActivateIntent(),
              SingleActivator(
                LogicalKeyboardKey.gameButtonA,
                includeRepeats: false,
              ): ActivateIntent(),
            }
          : const {},
      child: child,
    ),
  );
}
