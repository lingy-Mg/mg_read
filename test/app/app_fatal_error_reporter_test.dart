import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_fatal_error_dialog_host.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/errors/app_error.dart';

import '../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('fatal reports contain only stable diagnostic values', () async {
    const secretCanary = 'Cookie=SECRET-CANARY https://private.example/a';
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final reports = <AppFatalDiagnosticReport>[];
    final subscription = reporter.reports.listen(reports.add);
    addTearDown(() async {
      await subscription.cancel();
      reporter.dispose();
      await kit.dispose();
    });

    reporter.reportUnhandled(
      boundary: 'platform-dispatcher',
      errorCode: 'unhandled_platform_error',
      stackTrace: StackTrace.fromString('at $secretCanary C:\\private\\a.dart'),
      fatal: true,
    );

    expect(reports, hasLength(1));
    final report = reports.single;
    expect(report.errorCode, 'unhandled_platform_error');
    expect(report.traceId, matches(RegExp(r'^[A-Za-z0-9_-]{16,128}$')));
    expect(report.stackFingerprint, matches(RegExp(r'^[a-f0-9]{16}$')));
    expect(report.copyPayload, isNot(contains(secretCanary)));
    expect(report.copyPayload, isNot(contains('C:\\private')));
    expect(
      jsonEncode(const DiagnosticEventCodec().encode(kit.sink.events.single)),
      isNot(contains(secretCanary)),
    );
  });

  test(
    'non-fatal framework reports are recorded without opening a dialog',
    () async {
      final kit = DiagnosticsTestkit();
      final reporter = AppFatalErrorReporter(kit.manager);
      final reports = <AppFatalDiagnosticReport>[];
      final subscription = reporter.reports.listen(reports.add);
      addTearDown(() async {
        await subscription.cancel();
        reporter.dispose();
        await kit.dispose();
      });

      reporter.reportUnhandled(
        boundary: 'flutter-framework',
        errorCode: 'unhandled_flutter_error',
        stackTrace: StackTrace.empty,
        fatal: false,
      );

      expect(reports, isEmpty);
      expect(kit.sink.events, hasLength(1));
      expect(kit.sink.events.single.severity, DiagnosticSeverity.error);
    },
  );

  test('runtime reporter ignores ordinary source errors', () async {
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final reports = <AppFatalDiagnosticReport>[];
    final subscription = reporter.reports.listen(reports.add);
    addTearDown(() async {
      await subscription.cancel();
      reporter.dispose();
      await kit.dispose();
    });

    reporter.reportFatalRuntimeFailure(
      AppError.fromCode(AppErrorCode.timeout),
      StackTrace.empty,
    );
    expect(reports, isEmpty);
    expect(kit.sink.events, isEmpty);

    reporter.reportFatalRuntimeFailure(
      AppError.fromCode(AppErrorCode.runtimeStartFailed),
      StackTrace.empty,
    );
    expect(reports, hasLength(1));
    expect(kit.sink.events.single.severity, DiagnosticSeverity.fatal);
    expect(
      kit.sink.events.single.attributes.values['boundary'],
      DiagnosticStringValue('runtime-warmup'),
    );
  });

  test(
    'runtime no-ready errors are fatal with a bounded safe projection',
    () async {
      final kit = DiagnosticsTestkit();
      final reporter = AppFatalErrorReporter(kit.manager);
      final reports = <AppFatalDiagnosticReport>[];
      final subscription = reporter.reports.listen(reports.add);
      addTearDown(() async {
        await subscription.cancel();
        reporter.dispose();
        await kit.dispose();
      });

      reporter.reportFatalRuntimeFailure(
        AppError.fromCode(AppErrorCode.runtimeNotReady),
        StackTrace.fromString('raw startup detail SECRET-CANARY C:\\private'),
      );

      expect(reports, hasLength(1));
      expect(reports.single.errorCode, 'runtime_not_ready');
      expect(reports.single.phase, 'runtime_facade');
      expect(reports.single.runtimeState, 'not_ready');
      expect(reports.single.diagnosticsMarker, 'runtime_failure_observed');
      expect(reports.single.copyPayload, isNot(contains('SECRET-CANARY')));
      expect(reports.single.copyPayload, isNot(contains('C:\\private')));
    },
  );

  testWidgets('dialog queues, copies its safe payload, and closes', (
    WidgetTester tester,
  ) async {
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    String? copiedPayload;
    addTearDown(() async {
      reporter.dispose();
      await kit.dispose();
    });

    reporter.reportUnhandled(
      boundary: 'platform-dispatcher',
      errorCode: 'unhandled_platform_error',
      stackTrace: StackTrace.empty,
      fatal: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appRootNavigatorKey,
        home: Builder(
          builder: (BuildContext context) => AppFatalErrorDialogHost(
            reporter: reporter,
            copyReport: (String payload) async => copiedPayload = payload,
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('应用遇到严重错误'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fatal-error-copy')));
    await tester.pump();
    expect(copiedPayload, contains('错误代码: unhandled_platform_error'));
    expect(copiedPayload, contains('追踪 ID:'));
    expect(copiedPayload, contains('堆栈指纹:'));
    expect(copiedPayload, contains('阶段: unhandled'));
    expect(copiedPayload, contains('Runtime 状态: not_applicable'));
    expect(copiedPayload, contains('诊断标记: app_boundary_recorded'));

    await tester.tap(find.byKey(const Key('fatal-error-close')));
    await tester.pumpAndSettle();
    expect(find.text('应用遇到严重错误'), findsNothing);
  });
}
