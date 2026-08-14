import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

/// Application page that hosts the reader plugin through its public API.
class ReaderHostPage extends ConsumerStatefulWidget {
  /// Creates a page for one resolved reader launch [request].
  const ReaderHostPage({required this.request, super.key});

  /// The main-application inputs for this reading session.
  final ReaderLaunchRequest request;

  @override
  ConsumerState<ReaderHostPage> createState() => _ReaderHostPageState();
}

class _ReaderHostPageState extends ConsumerState<ReaderHostPage> {
  late final DiagnosticSpanHandle _launchSpan;
  late final Stopwatch _launchStopwatch;
  late final DiagnosticsManager _diagnostics;

  @override
  void initState() {
    super.initState();
    _diagnostics = ref.read(diagnosticsManagerProvider);
    _launchStopwatch = Stopwatch()..start();
    _launchSpan = _diagnostics.startSpan(
      AppDiagnosticEvents.readerLaunch,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'readerMode': DiagnosticValue.string('text'),
        'sourceKind': DiagnosticValue.string('resolvedFacade'),
      }),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _launchSpan.isEnded) return;
      _launchSpan.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'readerMode': DiagnosticValue.string('text'),
          'sourceKind': DiagnosticValue.string('resolvedFacade'),
          'resultState': DiagnosticValue.string('firstFrame'),
        }),
      );
      _reportLaunchPerformance(DiagnosticOutcome.success);
    });
  }

  @override
  void dispose() {
    if (!_launchSpan.isEnded) {
      _launchSpan.cancel(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
          'readerMode': DiagnosticValue.string('text'),
          'sourceKind': DiagnosticValue.string('resolvedFacade'),
          'resultState': DiagnosticValue.string('disposedBeforeFirstFrame'),
        }),
      );
      _reportLaunchPerformance(DiagnosticOutcome.cancelled);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TextReaderView(
        bookId: widget.request.bookId,
        dataSource: widget.request.dataSource,
        stateStore: widget.request.stateStore,
        observer: widget.request.observer,
        controller: widget.request.controller,
        extensions: widget.request.extensions,
      ),
    );
  }

  void _reportLaunchPerformance(DiagnosticOutcome outcome) {
    _launchStopwatch.stop();
    reportSlowDiagnostic(
      _diagnostics,
      subjectComponent: 'feature.reader',
      operation: 'firstFrame',
      elapsed: _launchStopwatch.elapsed,
      threshold: AppDiagnosticThresholds.readerFirstFrame,
      outcome: outcome,
      traceContext: _launchSpan.traceContext,
    );
  }
}
