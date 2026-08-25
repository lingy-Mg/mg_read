import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/data_source_system_error_reporter.dart';

typedef DataSourceDiagnosticCopy = Future<void> Function(String payload);

/// Shows one copyable, non-fatal data-source recovery dialog at a time.
final class DataSourceSystemErrorDialogHost extends StatefulWidget {
  const DataSourceSystemErrorDialogHost({
    required this.reporter,
    required this.child,
    this.copyReport = _copyToClipboard,
    super.key,
  });

  final DataSourceSystemErrorReporter reporter;
  final Widget child;
  final DataSourceDiagnosticCopy copyReport;

  static Future<void> _copyToClipboard(String payload) =>
      Clipboard.setData(ClipboardData(text: payload));

  @override
  State<DataSourceSystemErrorDialogHost> createState() =>
      _DataSourceSystemErrorDialogHostState();
}

final class _DataSourceSystemErrorDialogHostState
    extends State<DataSourceSystemErrorDialogHost> {
  StreamSubscription<DataSourceSystemDiagnosticReport>? _subscription;
  var _displaying = false;
  var _scheduled = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.reporter.reports.listen(_enqueue);
    _scheduleDisplay();
  }

  @override
  void didUpdateWidget(covariant DataSourceSystemErrorDialogHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.reporter, widget.reporter)) return;
    unawaited(_subscription?.cancel());
    _subscription = widget.reporter.reports.listen(_enqueue);
    _scheduleDisplay();
  }

  void _enqueue(DataSourceSystemDiagnosticReport _) {
    if (mounted) _scheduleDisplay();
  }

  void _scheduleDisplay() {
    if (_scheduled || _displaying || !widget.reporter.hasPendingReports) {
      return;
    }
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
    final report = widget.reporter.takeNextReport();
    if (report == null) return;
    _displaying = true;
    try {
      await showDialog<void>(
        context: navigator.context,
        barrierDismissible: false,
        builder: (BuildContext context) => _DataSourceSystemErrorDialog(
          report: report,
          onCopy: () => widget.copyReport(report.copyPayload),
        ),
      );
    } catch (_) {
      // The overlay is optional and must not affect source isolation.
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

final class _DataSourceSystemErrorDialog extends StatelessWidget {
  const _DataSourceSystemErrorDialog({
    required this.report,
    required this.onCopy,
  });

  final DataSourceSystemDiagnosticReport report;
  final Future<void> Function() onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<AppThemeTokens>();
    return AlertDialog(
      title: const Text('数据源系统异常'),
      content: SelectionArea(
        child: Text(
          '发现无法加载的数据源，已自动隔离。其他数据源可以继续使用。\n\n'
          '${report.copyPayload}',
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens?.mutedText),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('data-source-error-copy'),
          onPressed: () => unawaited(_copySafely()),
          child: const Text('复制诊断信息'),
        ),
        FilledButton(
          key: const Key('data-source-error-close'),
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
      // Clipboard support is optional.
    }
  }
}
