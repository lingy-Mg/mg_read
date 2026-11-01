/// Shared back input dispatch; page-owned navigation always runs first.
/// An explicit dispatcher supports hosts above MaterialApp.router's Router.
/// Dispatcher callbacks are attached and released with this scope's lifetime.
/// TV hosts may capture a whole key gesture before page shortcuts and consume
/// its paired Android platform signal, including one arriving after key-up.
/// Platform-only callback bursts are also coalesced until 180 ms of quiet.
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
  const AppBackNavigationScope({
    required this.onBackRequested,
    required this.child,
    this.backButtonDispatcher,
    this.captureBackKeys = false,
    super.key,
  });

  /// Returns true when back was consumed, including page-local handling.
  final Future<bool> Function() onBackRequested;
  final BackButtonDispatcher? backButtonDispatcher;
  final bool captureBackKeys;
  final Widget child;

  @override
  State<AppBackNavigationScope> createState() => _AppBackNavigationScopeState();
}

class _AppBackNavigationScopeState extends State<AppBackNavigationScope> with WidgetsBindingObserver {
  static const _echoWindow = Duration(milliseconds: 350);
  static const _platformQuietWindow = Duration(milliseconds: 180);
  bool _isHandlingBack = false;
  final _heldBackKeys = <PhysicalKeyboardKey>{};
  bool _platformEcho = false;
  bool _keyboardEcho = false;
  Timer? _echoTimer;
  Timer? _platformTimer;
  BackButtonDispatcher? _parentDispatcher;
  ChildBackButtonDispatcher? _backDispatcher;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.captureBackKeys) FocusManager.instance.addEarlyKeyEventHandler(_captureBackKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncDispatcher();
  }

  @override
  void didUpdateWidget(covariant AppBackNavigationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.captureBackKeys != widget.captureBackKeys) {
      if (widget.captureBackKeys) {
        FocusManager.instance.addEarlyKeyEventHandler(_captureBackKey);
      } else {
        FocusManager.instance.removeEarlyKeyEventHandler(_captureBackKey);
        _clearBackGesture();
      }
    }
    _syncDispatcher();
  }

  void _clearBackGesture() {
    _echoTimer?.cancel();
    _echoTimer = null;
    _platformTimer?.cancel();
    _platformTimer = null;
    _heldBackKeys.clear();
    _platformEcho = false;
    _keyboardEcho = false;
  }

  void _waitForEcho() {
    _echoTimer?.cancel();
    _echoTimer = Timer(_echoWindow, () {
      _platformEcho = false;
      _keyboardEcho = false;
      _echoTimer = null;
    });
  }

  void _waitForPlatformQuiet() {
    _platformTimer?.cancel();
    _platformTimer = Timer(_platformQuietWindow, () => _platformTimer = null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _clearBackGesture();
  }

  KeyEventResult _captureBackKey(KeyEvent event) {
    final back = event.logicalKey == LogicalKeyboardKey.escape || event.logicalKey == LogicalKeyboardKey.goBack;
    if (!back && !_heldBackKeys.contains(event.physicalKey)) {
      if (event is KeyDownEvent && _heldBackKeys.isEmpty) _keyboardEcho = false;
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      _heldBackKeys.remove(event.physicalKey);
      _waitForEcho();
    } else if (event is KeyDownEvent && _heldBackKeys.add(event.physicalKey)) {
      final echo = _keyboardEcho;
      _platformTimer?.cancel();
      _platformTimer = null;
      _echoTimer?.cancel();
      _keyboardEcho = false;
      _platformEcho = true;
      if (!echo) unawaited(_dispatchBack());
    }
    return KeyEventResult.handled;
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
    FocusManager.instance.removeEarlyKeyEventHandler(_captureBackKey);
    WidgetsBinding.instance.removeObserver(this);
    _clearBackGesture();
    _backDispatcher?.removeCallback(_requestBack);
    super.dispose();
  }

  Future<bool> _requestBack() async {
    if (widget.captureBackKeys) {
      if (_heldBackKeys.isNotEmpty || _platformEcho) return true;
      if (_platformTimer?.isActive ?? false) {
        _waitForPlatformQuiet();
        _waitForEcho();
        return true;
      }
      _waitForPlatformQuiet();
      _keyboardEcho = true;
      _waitForEcho();
    }
    return _dispatchBack();
  }

  Future<bool> _dispatchBack() async {
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
    unawaited(_dispatchBack());
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
              unawaited(_dispatchBack());
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
