import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_runtime_fatal_error_observer.dart';

import '../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('observes a pre-subscription startup failure from the typed snapshot', () async {
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final source = _FakeRuntimeFatalDiagnosticSource(
      latest: const <RuntimeDiagnostic>[
        RuntimeDiagnostic(
          code: 'runtime_ready_timeout',
          level: RuntimeDiagnosticLevel.error,
          message: 'raw process output SECRET-CANARY C:\\private',
        ),
      ],
    );
    final observer = RuntimeFatalErrorObserver(source, reporter);
    final reports = <AppFatalDiagnosticReport>[];
    final subscription = reporter.reports.listen(reports.add);
    addTearDown(() async {
      observer.dispose();
      await subscription.cancel();
      await source.dispose();
      reporter.dispose();
      await kit.dispose();
    });

    observer.start();

    expect(observer.hasObservedFatal, isTrue);
    expect(reports, hasLength(1));
    expect(reports.single.errorCode, 'runtime_not_ready');
    expect(reports.single.phase, 'runtime_startup');
    expect(reports.single.runtimeState, 'not_ready');
    expect(reports.single.diagnosticsMarker, 'runtime_diagnostic_observed');
    expect(reports.single.copyPayload, contains('SECRET-CANARY'));
    expect(reports.single.copyPayload, contains('C:\\private'));
  });

  test('observes a Windows Node exit after successful initial warmup', () async {
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final source = _FakeRuntimeFatalDiagnosticSource();
    final observer = RuntimeFatalErrorObserver(source, reporter);
    final reports = <AppFatalDiagnosticReport>[];
    final subscription = reporter.reports.listen(reports.add);
    addTearDown(() async {
      observer.dispose();
      await subscription.cancel();
      await source.dispose();
      reporter.dispose();
      await kit.dispose();
    });

    observer.start();
    source.add(
      const RuntimeDiagnostic(
        code: 'runtime_process_exited',
        level: RuntimeDiagnosticLevel.error,
        message: 'The desktop Runtime process exited unexpectedly (exit code 1).',
      ),
    );

    expect(reports, hasLength(1));
    expect(reports.single.errorCode, 'runtime_process_exited');
    expect(reports.single.phase, 'runtime_lifecycle');
    expect(reports.single.runtimeState, 'exited');
  });

  test('does not promote ordinary source diagnostics to the fatal dialog', () async {
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final source = _FakeRuntimeFatalDiagnosticSource();
    final observer = RuntimeFatalErrorObserver(source, reporter);
    final reports = <AppFatalDiagnosticReport>[];
    final subscription = reporter.reports.listen(reports.add);
    addTearDown(() async {
      observer.dispose();
      await subscription.cancel();
      await source.dispose();
      reporter.dispose();
      await kit.dispose();
    });

    observer.start();
    source.add(
      const RuntimeDiagnostic(code: 'plugin_execution_failed', level: RuntimeDiagnosticLevel.error, message: 'Source execution failed.'),
    );
    source.add(
      const RuntimeDiagnostic(
        code: 'plugin_invalid_response',
        level: RuntimeDiagnosticLevel.error,
        message: 'Source returned invalid data.',
      ),
    );

    expect(observer.hasObservedFatal, isFalse);
    expect(reports, isEmpty);
  });
}

final class _FakeRuntimeFatalDiagnosticSource implements RuntimeFatalDiagnosticSource {
  _FakeRuntimeFatalDiagnosticSource({this.latest = const <RuntimeDiagnostic>[]});

  final List<RuntimeDiagnostic> latest;
  final StreamController<RuntimeDiagnostic> _controller = StreamController<RuntimeDiagnostic>.broadcast(sync: true);

  @override
  Stream<RuntimeDiagnostic> get diagnostics => _controller.stream;

  @override
  List<RuntimeDiagnostic> get latestDiagnostics => latest;

  void add(RuntimeDiagnostic diagnostic) => _controller.add(diagnostic);

  Future<void> dispose() => _controller.close();
}
