import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';

final class AppSettingsLifecycleHost extends StatefulWidget {
  const AppSettingsLifecycleHost({
    required this.manager,
    required this.child,
    this.diagnostics,
    this.closeDiagnostics,
    this.disposeDiagnosticsBoundary,
    this.flushTimeout = const Duration(seconds: 1),
    super.key,
  });

  final AppSettingsManager manager;
  final Widget child;
  final DiagnosticsManager? diagnostics;
  final Future<void> Function()? closeDiagnostics;
  final VoidCallback? disposeDiagnosticsBoundary;
  final Duration flushTimeout;

  @override
  State<AppSettingsLifecycleHost> createState() =>
      _AppSettingsLifecycleHostState();
}

final class _AppSettingsLifecycleHostState
    extends State<AppSettingsLifecycleHost>
    with WidgetsBindingObserver {
  Future<void> _flushTail = Future<void>.value();
  AppLifecycleState? _lastState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _emitLifecycle(state);
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
      try {
        await widget.diagnostics?.flush(timeout: widget.flushTimeout);
      } on TimeoutException {
        // Diagnostic flushing is bounded and never delays lifecycle handling.
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeResources());
    super.dispose();
  }

  void _emitLifecycle(AppLifecycleState state) {
    final diagnostics = widget.diagnostics;
    if (diagnostics == null) return;
    try {
      diagnostics.emit(
        AppDiagnosticEvents.lifecycleChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'fromState': _lastState == null
              ? DiagnosticValue.nullValue
              : DiagnosticValue.string(_lastState!.name),
          'toState': DiagnosticValue.string(state.name),
        }),
      );
    } catch (_) {
      // Lifecycle delivery must stay independent of diagnostics availability.
    }
    _lastState = state;
  }

  Future<void> _closeResources() async {
    await widget.manager.close();
    widget.disposeDiagnosticsBoundary?.call();
    if (widget.closeDiagnostics case final close?) {
      await close();
    } else {
      await widget.diagnostics?.close();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
