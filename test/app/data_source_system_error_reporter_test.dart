import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/data_source_system_error_dialog_host.dart';
import 'package:mg_read/app/data_source_system_error_reporter.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import '../core/diagnostics/diagnostics_testkit.dart';
import 'mg_read_app_test_support.dart';

void main() {
  test('development build failure keeps source identity and raw output', () async {
    final kit = DiagnosticsTestkit();
    final reporter = DataSourceSystemErrorReporter(kit.manager);
    addTearDown(() async {
      reporter.dispose();
      await kit.dispose();
    });

    reporter.reportDevelopmentReloadFailure(
      errorCode: 'plugin_build_failed',
      pluginId: 'org.example.watched',
      pluginName: '第一版',
      buildOutput: '[stderr]\ntsc: error TS2307',
    );

    final report = reporter.takeNextReport();
    expect(report?.pluginId, 'org.example.watched');
    expect(report?.pluginName, '第一版');
    expect(report?.copyPayload, contains('数据源名称: 第一版'));
    expect(report?.copyPayload, contains('数据源 ID: org.example.watched'));
    expect(report?.copyPayload, contains('tsc: error TS2307'));
  });

  test('pending development failures are presented as one report while retaining every detail', () async {
    final kit = DiagnosticsTestkit();
    final reporter = DataSourceSystemErrorReporter(kit.manager);
    addTearDown(() async {
      reporter.dispose();
      await kit.dispose();
    });

    reporter.reportDevelopmentReloadFailure(
      errorCode: 'plugin_build_failed',
      pluginId: 'org.example.first',
      pluginName: '第一批',
      buildOutput: 'first compiler output',
    );
    reporter.reportDevelopmentReloadFailure(
      errorCode: 'plugin_build_failed',
      pluginId: 'org.example.second',
      pluginName: '第二批',
      buildOutput: 'second compiler output',
    );

    final report = reporter.takeNextReport();
    expect(report?.failureCount, 2);
    expect(report?.dialogPayload, contains('第一批'));
    expect(report?.dialogPayload, contains('第二批'));
    expect(report?.copyPayload, contains('first compiler output'));
    expect(report?.copyPayload, contains('second compiler output'));
    expect(reporter.hasPendingReports, isFalse);

    final diagnostics = kit.sink.events.where((event) => event.eventName == 'app.error.unhandled').toList(growable: false);
    expect(diagnostics, hasLength(2));
    final console = const DiagnosticConsoleFormatter();
    expect(console.format(diagnostics[0]), contains('first compiler output'));
    expect(console.format(diagnostics[1]), contains('second compiler output'));
  });

  testWidgets('data-source recovery dialog is copyable with the supplied recovery metadata', (WidgetTester tester) async {
    final kit = DiagnosticsTestkit();
    final reporter = DataSourceSystemErrorReporter(kit.manager);
    String? copiedPayload;
    addTearDown(() async {
      reporter.dispose();
      await kit.dispose();
    });

    reporter.reportQuarantinedSources(quarantinedCount: 2);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: appRootNavigatorKey,
        home: DataSourceSystemErrorDialogHost(
          reporter: reporter,
          copyReport: (String payload) async => copiedPayload = payload,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据源系统异常'), findsOneWidget);
    expect(find.textContaining('已自动隔离'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-error-copy')));
    await tester.pump();
    expect(copiedPayload, contains('MgRead 数据源系统诊断报告'));
    expect(copiedPayload, contains('错误代码: plugin_load_failed'));
    expect(copiedPayload, contains('已隔离数据源数量: 2'));
    expect(copiedPayload, contains('追踪 ID:'));

    await tester.tap(find.byKey(const Key('data-source-error-close')));
    await tester.pumpAndSettle();
    expect(find.text('数据源系统异常'), findsNothing);
  });

  testWidgets('app warmup forwards the Runtime recovery summary to the dialog', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);

    await tester.pumpWidget(
      testMgReadApp(
        settings,
        runtimeGateway: const TestReadyPluginRuntimeGateway(startupRecovery: PluginRuntimeStartupRecovery(quarantinedCount: 1)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('数据源系统异常'), findsOneWidget);
    expect(find.textContaining('其他数据源可以继续使用'), findsOneWidget);
  });
}
