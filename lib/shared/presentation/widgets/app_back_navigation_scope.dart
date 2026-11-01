/// Shared back input dispatch; page-owned navigation always runs first.
/// An explicit dispatcher supports hosts above MaterialApp.router's Router.
/// Dispatcher callbacks are attached and released with this scope's lifetime.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Provides the non-visual back gestures shared by routed app pages.
///
/// Router history already handles browser back and forward navigation. This
/// scope adds the equivalent Escape and mouse side-back actions, while
/// a child dispatcher covers platform back events such as Android.
class AppBackNavigationScope extends StatefulWidget {
  const AppBackNavigationScope({required this.onBackRequested, required this.child, this.backButtonDispatcher, super.key});

  /// Returns true when back was consumed, including page-local handling.
  final Future<bool> Function() onBackRequested;
  final BackButtonDispatcher? backButtonDispatcher;
  final Widget child;

  @override
  State<AppBackNavigationScope> createState() => _AppBackNavigationScopeState();
}

class _AppBackNavigationScopeState extends State<AppBackNavigationScope> {
  bool _isHandlingBack = false;
  BackButtonDispatcher? _parentDispatcher;
  ChildBackButtonDispatcher? _backDispatcher;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDispatcher();
  }

  @override
  void didUpdateWidget(covariant AppBackNavigationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncDispatcher();
  }

  void _syncDispatcher() {
    final parent = widget.backButtonDispatcher ?? Router.maybeOf(context)?.backButtonDispatcher;
    if (identical(parent, _parentDispatcher)) return;
    _backDispatcher?.removeCallback(_requestBack);
    _parentDispatcher = parent;
    _backDispatcher = parent?.createChildBackButtonDispatcher();
    _backDispatcher?.addCallback(_requestBack);
    if (parent?.hasCallbacks ?? false) {
      _backDispatcher?.takePriority();
    } else {
      // An explicit dispatcher can arrive before the descendant Router mounts.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(parent, _parentDispatcher) && (parent?.hasCallbacks ?? false)) {
          _backDispatcher?.takePriority();
        }
      });
    }
  }

  @override
  void dispose() {
    _backDispatcher?.removeCallback(_requestBack);
    super.dispose();
  }

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
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): const _AppBackIntent(),
        const SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): const _AppBackIntent(),
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
        child: Listener(behavior: HitTestBehavior.translucent, onPointerDown: _handlePointerDown, child: widget.child),
      ),
    );
  }
}

class _AppBackIntent extends Intent {
  const _AppBackIntent();
}
