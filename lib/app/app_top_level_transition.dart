/// Lifecycle owner for interruptible top-level route fades.
///
/// Keeps one curved animation per route animation and releases its status
/// listener on replacement or disposal. CurvedAnimation retains the active
/// curve when interrupted, preserving the route's existing reverse behavior.
library;

import 'package:flutter/material.dart';

import 'app_theme.dart';

final class AppTopLevelTransition extends StatefulWidget {
  const AppTopLevelTransition({required this.animation, required this.child, super.key});

  final Animation<double> animation;
  final Widget child;

  @override
  State<AppTopLevelTransition> createState() => _AppTopLevelTransitionState();
}

final class _AppTopLevelTransitionState extends State<AppTopLevelTransition> {
  late CurvedAnimation _opacity;

  @override
  void initState() {
    super.initState();
    _createOpacity();
  }

  @override
  void didUpdateWidget(AppTopLevelTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.animation, widget.animation)) return;
    _opacity.dispose();
    _createOpacity();
  }

  void _createOpacity() {
    _opacity = CurvedAnimation(parent: widget.animation, curve: AppMotion.navigationCurve, reverseCurve: AppMotion.navigationReverseCurve);
  }

  @override
  void dispose() {
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(key: const Key('top-level-destination-transition'), opacity: _opacity, child: widget.child);
}
