import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';

typedef FatalDiagnosticCopy = Future<void> Function(String payload);

/// Displays queued fatal reports after the root Navigator becomes available.
final class AppFatalErrorDialogHost extends StatefulWidget {
  const AppFatalErrorDialogHost({
    required this.reporter,
    required this.child,
    this.copyReport = _copyToClipboard,
    super.key,
  });

  final AppFatalErrorReporter reporter;
  final Widget child;
  final FatalDiagnosticCopy copyReport;

  static Future<void> _copyToClipboard(String payload) =>
      Clipboard.setData(ClipboardData(text: payload));

  @override
  State<AppFatalErrorDialogHost> createState() =>
      _AppFatalErrorDialogHostState();
}

final class _AppFatalErrorDialogHostState
    extends State<AppFatalErrorDialogHost> {
  StreamSubscription<AppFatalDiagnosticReport>? _subscription;
  bool _displaying = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.reporter.reports.listen(_enqueue);
    _scheduleDisplay();
  }

  @override
  void didUpdateWidget(covariant AppFatalErrorDialogHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.reporter, widget.reporter)) return;
    unawaited(_subscription?.cancel());
    _subscription = widget.reporter.reports.listen(_enqueue);
    _scheduleDisplay();
  }

  void _enqueue(AppFatalDiagnosticReport _) {
    if (!mounted) return;
    _scheduleDisplay();
  }

  void _scheduleDisplay() {
    if (_scheduled || _displaying || !widget.reporter.hasPendingReports) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_displayNext());
    });
  }

  Future<void> _displayNext() async {
    if (_displaying) return;
    final navigator = appRootNavigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      _scheduleDisplay();
      return;
    }
    _displaying = true;
    final report = widget.reporter.takeNextReport();
    if (report == null) {
      _displaying = false;
      return;
    }
    try {
      await showDialog<void>(
        context: navigator.context,
        barrierDismissible: false,
        builder: (BuildContext context) => _FatalErrorDialog(
          report: report,
          onCopy: () => widget.copyReport(report.copyPayload),
        ),
      );
    } catch (_) {
      // A broken overlay must not replace the original application failure.
    } finally {
      _displaying = false;
      if (mounted) _scheduleDisplay();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class _FatalErrorDialog extends StatelessWidget {
  const _FatalErrorDialog({required this.report, required this.onCopy});

  final AppFatalDiagnosticReport report;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<AppThemeTokens>();
    return AlertDialog(
      title: const Text('应用遇到严重错误'),
      content: SelectionArea(
        child: Text(
          '应用仍可继续使用。若问题持续出现，请复制以下诊断信息反馈。\n\n'
          '${report.copyPayload}',
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens?.mutedText),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('fatal-error-copy'),
          onPressed: () => unawaited(_copySafely()),
          child: const Text('复制诊断信息'),
        ),
        FilledButton(
          key: const Key('fatal-error-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Future<void> _copySafely() async {
    try {
      await onCopy();
    } catch (_) {
      // Copy support is optional and cannot replace the original failure.
    }
  }
}
