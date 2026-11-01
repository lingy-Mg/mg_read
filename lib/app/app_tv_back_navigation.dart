/// TV root back policy, shared by platform, keyboard and mouse back inputs.
/// Page-owned stacks and overlays consume back before the TV root fallback.
/// The exit window is transient and cleared on navigation, mode or lifecycle changes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/shared/presentation/widgets/app_back_navigation_scope.dart';

class AppTvBackNavigation extends StatefulWidget {
  const AppTvBackNavigation({required this.router, required this.enabled, required this.child, super.key});

  final GoRouter router;
  final bool enabled;
  final Widget child;

  @override
  State<AppTvBackNavigation> createState() => _AppTvBackNavigationState();
}

class _AppTvBackNavigationState extends State<AppTvBackNavigation> with WidgetsBindingObserver {
  static const _exitWindow = Duration(seconds: 2);
  Timer? _exitTimer;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _exitPrompt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.router.routerDelegate.addListener(_clearExit);
  }

  @override
  void didUpdateWidget(covariant AppTvBackNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.router != widget.router) {
      oldWidget.router.routerDelegate.removeListener(_clearExit);
      widget.router.routerDelegate.addListener(_clearExit);
    }
    if (oldWidget.router != widget.router || oldWidget.enabled != widget.enabled) _clearExit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _clearExit();
  }

  void _clearExit() {
    _exitTimer?.cancel();
    _exitTimer = null;
    _exitPrompt?.close();
    _exitPrompt = null;
  }

  Future<bool> _requestBack() async {
    if (await popApplicationRoute()) {
      _clearExit();
      return true;
    }
    if (!mounted || !widget.enabled) return false;
    if (widget.router.routerDelegate.currentConfiguration.uri.path != '/') {
      _clearExit();
      widget.router.go(const LibraryRoute().location);
      return true;
    }
    if (_exitTimer?.isActive ?? false) {
      _clearExit();
      await SystemNavigator.pop();
      return true;
    }
    final navigatorContext = appRootNavigatorKey.currentContext;
    if (navigatorContext == null || !navigatorContext.mounted) return false;
    final messenger = ScaffoldMessenger.of(navigatorContext)..clearSnackBars();
    _exitPrompt = messenger.showSnackBar(const SnackBar(content: Text('再按一次返回键退出应用'), duration: _exitWindow));
    _exitTimer = Timer(_exitWindow, _clearExit);
    return true;
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    widget.router.routerDelegate.removeListener(_clearExit);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppBackNavigationScope(
    backButtonDispatcher: widget.enabled ? widget.router.backButtonDispatcher : null,
    onBackRequested: _requestBack,
    child: widget.child,
  );
}
