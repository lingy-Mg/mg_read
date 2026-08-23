import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Provides the non-visual back gestures shared by routed app pages.
///
/// Router history already handles browser back and forward navigation. This
/// scope adds the equivalent Escape and mouse side-back actions, while
/// [BackButtonListener] covers platform back dispatchers such as Android.
class AppBackNavigationScope extends StatefulWidget {
  const AppBackNavigationScope({
    required this.onBackRequested,
    required this.child,
    super.key,
  });

  /// Returns true when a page was popped and false when the app is at its root.
  final Future<bool> Function() onBackRequested;
  final Widget child;

  @override
  State<AppBackNavigationScope> createState() => _AppBackNavigationScopeState();
}

class _AppBackNavigationScopeState extends State<AppBackNavigationScope> {
  bool _isHandlingBack = false;

  Future<bool> _requestBack() async {
    if (_isHandlingBack) return true;
    _isHandlingBack = true;
    try {
      return await widget.onBackRequested();
    } finally {
      _isHandlingBack = false;
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if (event.buttons & kBackMouseButton == 0) return;
    unawaited(_requestBack());
  }

  @override
  Widget build(BuildContext context) {
    final Widget shortcutAwareChild = Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _AppBackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _AppBackIntent: CallbackAction<_AppBackIntent>(
            onInvoke: (_) {
              unawaited(_requestBack());
              return null;
            },
          ),
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _handlePointerDown,
          child: widget.child,
        ),
      ),
    );
    // MaterialApp.router's builder is above Router, so BackButtonListener
    // would assert during the first frame when this scope is installed there.
    // In that position go_router/Navigator handles platform back by default;
    // keep the explicit listener only when a Router is actually available.
    if (Router.maybeOf(context) == null) return shortcutAwareChild;
    return BackButtonListener(
      onBackButtonPressed: _requestBack,
      child: shortcutAwareChild,
    );
  }
}

class _AppBackIntent extends Intent {
  const _AppBackIntent();
}
