import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_diagnostics_boundary.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import '../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('framework boundary stores only stable error metadata', () async {
    const secretCanary = 'Bearer SECRET-CANARY?token=private';
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final reports = <AppFatalDiagnosticReport>[];
    final subscription = reporter.reports.listen(reports.add);
    final previousHandler = FlutterError.onError;
    FlutterError.onError = (_) {};
    final boundary = AppDiagnosticsErrorBoundary.install(kit.manager, fatalReporter: reporter);
    addTearDown(() async {
      boundary.dispose();
      FlutterError.onError = previousHandler;
      await subscription.cancel();
      reporter.dispose();
      await kit.dispose();
    });

    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError(secretCanary),
        stack: StackTrace.fromString('at secret (C:\\private\\$secretCanary\\source.dart:10:2)'),
      ),
    );

    final event = kit.sink.events.single;
    final encoded = jsonEncode(const DiagnosticEventCodec().encode(event));
    expect(event.eventName, 'app.error.unhandled');
    expect(event.severity, DiagnosticSeverity.error);
    expect(event.attributes.values['boundary'], DiagnosticStringValue('flutter-framework'));
    expect(encoded, isNot(contains(secretCanary)));
    expect(encoded, isNot(contains('C:\\private')));
    expect(reports, isEmpty);
  });

  test('platform boundary retains only the stable platform code', () async {
    final kit = DiagnosticsTestkit();
    final reporter = AppFatalErrorReporter(kit.manager);
    final boundary = AppDiagnosticsErrorBoundary.install(kit.manager, fatalReporter: reporter);
    addTearDown(() async {
      boundary.dispose();
      reporter.dispose();
      await kit.dispose();
    });

    final handled = PlatformDispatcher.instance.onError!(
      PlatformException(code: 'camera-session-failed', message: 'C:\\private\\secret-token'),
      StackTrace.empty,
    );

    expect(handled, isTrue);
    expect(kit.sink.events.single.attributes.values['errorCode'], DiagnosticStringValue('platform_camera_session_failed'));
    expect(reporter.takeNextReport()?.errorCode, 'platform_camera_session_failed');
  });
}
