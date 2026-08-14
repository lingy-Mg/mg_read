import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mg_read/core/settings/settings.dart';

final class AppSettingsLifecycleHost extends StatefulWidget {
  const AppSettingsLifecycleHost({
    required this.manager,
    required this.child,
    this.flushTimeout = const Duration(seconds: 1),
    super.key,
  });

  final AppSettingsManager manager;
  final Widget child;
  final Duration flushTimeout;

  @override
  State<AppSettingsLifecycleHost> createState() =>
      _AppSettingsLifecycleHostState();
}

final class _AppSettingsLifecycleHostState
    extends State<AppSettingsLifecycleHost>
    with WidgetsBindingObserver {
  Future<void> _flushTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden &&
        state != AppLifecycleState.detached) {
      return;
    }
    _flushTail = _flushTail.then((_) async {
      try {
        await widget.manager.flush().timeout(widget.flushTimeout);
      } on TimeoutException {
        // The manager retains dirty state and its retry policy. Lifecycle
        // callbacks must never block indefinitely.
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.manager.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
