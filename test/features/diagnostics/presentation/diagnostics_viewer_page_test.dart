import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_capture_preference_store.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_viewer_gateway.dart';
import 'package:mg_read/features/diagnostics/presentation/diagnostics_viewer_page.dart';

import '../../../core/diagnostics/persistent_diagnostics_testkit.dart';

void main() {
  testWidgets('defaults diagnostics off, lists file metadata, and reads no events', (WidgetTester tester) async {
    final gateway = _FakeDiagnosticsViewerGateway();
    final preferences = _FakeDiagnosticsCapturePreferenceStore(diagnosticsEnabled: false);
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();

    expect(find.text('默认关闭，不创建日志文件；开启后立即记录本次启动后续事件'), findsOneWidget);
    expect(gateway.fileListReads, 1);
    expect(gateway.eventReads, 0);
    await tester.tap(find.text('实时详情'));
    await tester.pumpAndSettle();
    expect(gateway.startedModes, isEmpty);
  });

  testWidgets('defaults to key logs and reads details only after explicit realtime selection', (WidgetTester tester) async {
    await _setViewport(tester, const Size(800, 1200));
    final gateway = _FakeDiagnosticsViewerGateway();
    final preferences = _FakeDiagnosticsCapturePreferenceStore();
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();

    expect(gateway.startedModes, isEmpty);
    expect(find.text('仅关键日志'), findsOneWidget);
    expect(gateway.eventReads, 0);

    await tester.tap(find.byKey(const Key('diagnostics-log-log_file_current')));
    await tester.pumpAndSettle();
    expect(gateway.eventReads, 1);

    await tester.tap(find.text('实时详情'));
    await tester.pumpAndSettle();
    expect(gateway.startedModes, <DiagnosticsDetailMode>[DiagnosticsDetailMode.memoryOnly]);
    expect(preferences.realtimeDetailsEnabled, isTrue);
    expect(find.text('实时详情 · 仅内存'), findsOneWidget);
    expect(find.text('app.bootstrap.success'), findsOneWidget);
    expect(gateway.detailReads, 0);
    expect(gateway.previewReads, 0);

    await tester.tap(find.text('app.bootstrap.success'));
    await tester.pumpAndSettle();
    expect(gateway.detailReads, 1);
    expect(find.text('结构化字段'), findsOneWidget);
    expect(find.text('详情附件'), findsOneWidget);

    final previewButton = find.text('纯文本预览前 32 KiB');
    await tester.ensureVisible(previewButton);
    await tester.tap(previewButton);
    await tester.pumpAndSettle();
    expect(gateway.previewReads, 1);
    expect(find.text('<html>safe preview</html>'), findsOneWidget);

    final persistMode = find.text('保存详情 TXT');
    await tester.ensureVisible(persistMode);
    await tester.tap(persistMode);
    await tester.pumpAndSettle();
    expect(gateway.startedModes, <DiagnosticsDetailMode>[DiagnosticsDetailMode.memoryOnly, DiagnosticsDetailMode.persistToText]);
    expect(gateway.stoppedModes, <DiagnosticsDetailMode>[DiagnosticsDetailMode.memoryOnly]);
    expect(find.text('详细日志 · TXT'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(gateway.stoppedModes, <DiagnosticsDetailMode>[DiagnosticsDetailMode.memoryOnly, DiagnosticsDetailMode.persistToText]);
  });

  testWidgets('shows only the App event feed after Runtime history removal', (WidgetTester tester) async {
    final gateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(gateway, _FakeDiagnosticsCapturePreferenceStore()));
    await tester.pumpAndSettle();

    expect(find.text('Runtime'), findsNothing);
    await tester.tap(find.byKey(const Key('diagnostics-log-log_file_current')));
    await tester.pumpAndSettle();
    expect(find.text('app.bootstrap.success'), findsOneWidget);
    expect(gateway.requestedSources, contains(DiagnosticsViewerSource.app));
    expect(gateway.startedSources, isEmpty);
  });

  testWidgets('restores realtime details but does not persist TXT capture', (WidgetTester tester) async {
    final preferences = _FakeDiagnosticsCapturePreferenceStore(realtimeDetailsEnabled: true);
    final firstGateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(firstGateway, preferences));
    await tester.pumpAndSettle();

    expect(firstGateway.startedModes, <DiagnosticsDetailMode>[DiagnosticsDetailMode.memoryOnly]);
    expect(find.text('实时详情 · 仅内存'), findsOneWidget);

    await tester.tap(find.text('保存详情 TXT'));
    await tester.pumpAndSettle();
    expect(preferences.realtimeDetailsEnabled, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final reopenedGateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(reopenedGateway, preferences));
    await tester.pumpAndSettle();

    expect(reopenedGateway.startedModes, <DiagnosticsDetailMode>[DiagnosticsDetailMode.memoryOnly]);
    expect(find.text('实时详情 · 仅内存'), findsOneWidget);

    await tester.tap(find.text('仅关键'));
    await tester.pumpAndSettle();
    expect(preferences.realtimeDetailsEnabled, isFalse);
    expect(find.text('仅关键日志'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    final keyLogsGateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(keyLogsGateway, preferences));
    await tester.pumpAndSettle();

    expect(keyLogsGateway.startedModes, isEmpty);
    expect(find.text('仅关键日志'), findsOneWidget);
  });

  test('starts an App capture without requiring the Runtime Facade', () async {
    final kit = await PersistentDiagnosticsTestkit.open();
    addTearDown(kit.dispose);
    final gateway = DefaultDiagnosticsViewerGateway(kit.service, kit.service, kit.service.manager);

    final capture = await gateway.startCapture(mode: DiagnosticsDetailMode.memoryOnly, source: DiagnosticsViewerSource.app);

    expect(capture.appSessionId, isNotNull);
    await gateway.stopCapture(capture);
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}

Widget _host(DiagnosticsViewerGateway gateway, DiagnosticsCapturePreferenceStore preferences) {
  return ProviderScope(
    overrides: [
      diagnosticsViewerGatewayProvider.overrideWithValue(gateway),
      diagnosticsCapturePreferenceStoreProvider.overrideWithValue(preferences),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: DiagnosticsViewerPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
    ),
  );
}

final class _FakeDiagnosticsCapturePreferenceStore implements DiagnosticsCapturePreferenceStore {
  _FakeDiagnosticsCapturePreferenceStore({this.realtimeDetailsEnabled = false, this.diagnosticsEnabled = true});

  bool realtimeDetailsEnabled;
  bool diagnosticsEnabled;

  @override
  Future<bool> loadDiagnosticsEnabled() async => diagnosticsEnabled;

  @override
  Future<void> saveDiagnosticsEnabled(bool enabled) async {
    diagnosticsEnabled = enabled;
  }

  @override
  Future<bool> loadRealtimeDetailsEnabled() async => realtimeDetailsEnabled;

  @override
  Future<void> saveRealtimeDetailsEnabled(bool enabled) async {
    realtimeDetailsEnabled = enabled;
  }
}

final class _FakeDiagnosticsViewerGateway implements DiagnosticsViewerGateway {
  final List<DiagnosticsDetailMode> startedModes = <DiagnosticsDetailMode>[];
  final List<DiagnosticsViewerSource> startedSources = <DiagnosticsViewerSource>[];
  final List<DiagnosticsDetailMode> stoppedModes = <DiagnosticsDetailMode>[];
  final List<DiagnosticsViewerSource> requestedSources = <DiagnosticsViewerSource>[];
  var detailReads = 0;
  var previewReads = 0;
  var eventReads = 0;
  var fileListReads = 0;

  @override
  Future<List<DiagnosticsViewerLogFile>> listLogFiles() async {
    fileListReads += 1;
    return const <DiagnosticsViewerLogFile>[
      DiagnosticsViewerLogFile(
        fileId: 'log_file_current',
        startedAtUtcMicros: 1800000000000000,
        modifiedAtUtcMicros: 1800000000000000,
        storedBytes: 1024,
        isCurrent: true,
      ),
    ];
  }

  @override
  Future<DiagnosticsViewerEventPage> listEvents({
    required DiagnosticsViewerSource source,
    required String logFileId,
    String? cursor,
  }) async {
    requestedSources.add(source);
    eventReads += 1;
    return DiagnosticsViewerEventPage(
      items: <DiagnosticsViewerEvent>[
        DiagnosticsViewerEvent(
          source: source,
          eventId: 'app_event_00000001',
          component: 'app.bootstrap',
          eventName: 'app.bootstrap.success',
          summary: 'Application started.',
          severity: 'info',
          phase: 'terminal',
          outcome: 'success',
          occurredAtUtcMicros: 1_800_000_000_000_000,
          durationMicros: 1200,
          attachmentCount: 1,
          capturedBytes: 25,
          logFileId: logFileId,
        ),
      ],
    );
  }

  @override
  Future<DiagnosticsViewerEventDetails> loadEventDetails(DiagnosticsViewerEvent event) async {
    detailReads += 1;
    return DiagnosticsViewerEventDetails(
      attributesText: '{\n  "stage": "ready"\n}',
      attachments: <DiagnosticsViewerAttachment>[
        DiagnosticsViewerAttachment(
          source: event.source,
          attachmentId: 'attachment_00000001',
          kind: 'http.response',
          mediaType: 'text/html',
          captureState: 'captured',
          rawByteLength: 25,
          storedByteLength: 25,
          logFileId: event.logFileId,
        ),
      ],
    );
  }

  @override
  Future<String> readAttachmentPreview(DiagnosticsViewerAttachment attachment) async {
    previewReads += 1;
    return '<html>safe preview</html>';
  }

  @override
  Future<DiagnosticsViewerCapture> startCapture({required DiagnosticsDetailMode mode, required DiagnosticsViewerSource source}) async {
    startedModes.add(mode);
    startedSources.add(source);
    return DiagnosticsViewerCapture(
      mode: mode,
      source: source,
      appSessionId: 'app_capture_0000001',
      expiresAtUtcMicros: 1_800_000_900_000_000,
    );
  }

  @override
  Future<void> stopCapture(DiagnosticsViewerCapture capture) async {
    stoppedModes.add(capture.mode);
  }

  @override
  Future<void> deleteLogFile(String logFileId) async {}

  @override
  Future<DiagnosticExportResult> exportLogFile(String logFileId) async => DiagnosticExportResult(
    exportId: 'export_0000000001',
    relativeObjectKey: 'exports/export.txt',
    byteLength: 1024,
    sessionCount: 1,
    eventCount: 1,
    attachmentCount: 1,
  );
}
