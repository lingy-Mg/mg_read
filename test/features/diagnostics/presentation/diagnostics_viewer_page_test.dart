import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_capture_preference_store.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_viewer_gateway.dart';
import 'package:mg_read/features/diagnostics/presentation/diagnostics_viewer_page.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_debug_http.dart';

import '../../../core/diagnostics/persistent_diagnostics_testkit.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final icons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([font.load(), icons.load()]);
  });
  for (final dark in [false, true]) {
    testWidgets('diagnostics compact ${dark ? 'dark' : 'light'} visual layout', (tester) async {
      await _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_host(_FakeDiagnosticsViewerGateway(), _FakeDiagnosticsCapturePreferenceStore(), dark: dark));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/diagnostics_compact_${dark ? 'dark' : 'light'}.png'));
    });
  }

  testWidgets('defaults to recent issues without file writes or restored capture', (tester) async {
    final gateway = _FakeDiagnosticsViewerGateway();
    final preferences = _FakeDiagnosticsCapturePreferenceStore(realtimeDetailsEnabled: true);
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();
    expect(find.text('仅关注异常'), findsOneWidget);
    expect(find.text('仅在内存中保留 · 不写出日志文件'), findsOneWidget);
    expect(find.text('内存日志不可导出'), findsNothing);
    expect(gateway.startedModes, isEmpty);
    expect(gateway.eventReads, 1);
    expect(gateway.detailReads, 0);
  });

  testWidgets('detailed collection survives page navigation and saving remains independent', (tester) async {
    await _setViewport(tester, const Size(800, 1200));
    final gateway = _FakeDiagnosticsViewerGateway();
    final preferences = _FakeDiagnosticsCapturePreferenceStore();
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-detail-switch')));
    await tester.pumpAndSettle();
    expect(gateway.startedModes, [DiagnosticsDetailMode.memoryOnly]);
    expect(preferences.diagnosticsEnabled, isFalse);
    expect(preferences.realtimeDetailsEnabled, isFalse);
    expect(find.text('正在记录排查过程'), findsOneWidget);

    await tester.tap(find.byKey(const Key('diagnostics-master-switch')));
    await tester.pumpAndSettle();
    expect(preferences.diagnosticsEnabled, isTrue);
    expect(gateway.startedModes.last, DiagnosticsDetailMode.persistToText);
    expect(gateway.stoppedModes, [DiagnosticsDetailMode.memoryOnly]);

    await tester.tap(find.byKey(const Key('diagnostics-master-switch')));
    await tester.pumpAndSettle();
    expect(preferences.diagnosticsEnabled, isFalse);
    expect(gateway.startedModes.last, DiagnosticsDetailMode.memoryOnly);
    expect(gateway.stoppedModes.last, DiagnosticsDetailMode.persistToText);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(gateway.activeCapture?.mode, DiagnosticsDetailMode.memoryOnly);
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();
    expect(find.text('正在记录排查过程'), findsOneWidget);
    await tester.tap(find.byKey(const Key('diagnostics-detail-switch')));
    await tester.pumpAndSettle();
    expect(gateway.activeCapture, isNull);
  });

  testWidgets('capture failure keeps saving off and allows a retry', (tester) async {
    final gateway = _FakeDiagnosticsViewerGateway()..failNextCapture = true;
    final preferences = _FakeDiagnosticsCapturePreferenceStore();
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-detail-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagnostics-capture-message')), findsOneWidget);
    expect(find.text('仅关注异常'), findsOneWidget);
    expect(preferences.diagnosticsEnabled, isFalse);
    await tester.tap(find.byKey(const Key('diagnostics-detail-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('diagnostics-capture-message')), findsNothing);
    expect(gateway.activeCapture?.mode, DiagnosticsDetailMode.memoryOnly);
    await tester.tap(find.byKey(const Key('diagnostics-detail-switch')));
    await tester.pumpAndSettle();
  });

  testWidgets('saving alone does not enable detailed collection', (tester) async {
    final gateway = _FakeDiagnosticsViewerGateway();
    final preferences = _FakeDiagnosticsCapturePreferenceStore();
    await tester.pumpWidget(_host(gateway, preferences));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-master-switch')));
    await tester.pumpAndSettle();
    expect(preferences.diagnosticsEnabled, isTrue);
    expect(gateway.startedModes, isEmpty);
    expect(find.text('仅关注异常'), findsOneWidget);
  });

  testWidgets('capture automatically returns to warnings after fifteen minutes', (tester) async {
    final gateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(gateway, _FakeDiagnosticsCapturePreferenceStore()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-detail-switch')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 15));
    await tester.pumpAndSettle();
    expect(gateway.stoppedModes, [DiagnosticsDetailMode.memoryOnly]);
    expect(find.text('仅关注异常'), findsOneWidget);
  });

  testWidgets('history and event payloads load only on selection', (tester) async {
    await _setViewport(tester, const Size(800, 1200));
    final gateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(gateway, _FakeDiagnosticsCapturePreferenceStore()));
    await tester.pumpAndSettle();
    expect(gateway.requestedFiles, ['live-current']);
    await tester.tap(find.byKey(const Key('diagnostics-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('diagnostics-log-log_file_current')));
    await tester.pumpAndSettle();
    expect(gateway.requestedFiles.last, 'log_file_current');
    expect(find.text('导出文件'), findsOneWidget);
    expect(find.text('删除文件'), findsNothing);
    await tester.tap(find.text('app.bootstrap.success'));
    await tester.pumpAndSettle();
    expect(gateway.detailReads, 1);
    final preview = find.text('纯文本预览前 32 KiB');
    await tester.ensureVisible(preview);
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(gateway.previewReads, 1);
    expect(find.text('<html>safe preview</html>'), findsOneWidget);
  });

  testWidgets('recording controls fit a narrow screen with enlarged text', (tester) async {
    await _setViewport(tester, const Size(320, 740));
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(_host(_FakeDiagnosticsViewerGateway(), _FakeDiagnosticsCapturePreferenceStore()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('diagnostics-master-switch')));
    await tester.tap(find.byKey(const Key('diagnostics-master-switch')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('real memory capture expires without a mounted diagnostics page or a file service', (tester) async {
    final buffer = LiveDiagnosticsBuffer();
    final manager = DiagnosticsManager(sink: buffer, registry: AppDiagnosticEvents.registry, source: DiagnosticSource.app);
    final gateway = DefaultDiagnosticsViewerGateway(null, null, manager, null, buffer);
    addTearDown(() async {
      gateway.dispose();
      await manager.close();
    });
    await gateway.startCapture(mode: DiagnosticsDetailMode.memoryOnly, source: DiagnosticsViewerSource.app);
    expect(buffer.minimumSeverity, DiagnosticSeverity.debug);
    await tester.pump(const Duration(minutes: 15));
    expect(gateway.activeCapture, isNull);
    expect(buffer.minimumSeverity, DiagnosticSeverity.warn);
  });

  test('starts an App capture without requiring the Runtime Facade', () async {
    final kit = await PersistentDiagnosticsTestkit.open();
    addTearDown(kit.dispose);
    final gateway = DefaultDiagnosticsViewerGateway(kit.service, kit.service, kit.service.manager);

    final capture = await gateway.startCapture(mode: DiagnosticsDetailMode.memoryOnly, source: DiagnosticsViewerSource.app);

    expect(capture.appSessionId, isNotNull);
    await gateway.stopCapture(capture);
  });

  test('projects the bounded current-process buffer as the default live log', () async {
    final buffer = LiveDiagnosticsBuffer()..setDetailedRecording(true);
    final manager = DiagnosticsManager(sink: buffer, registry: AppDiagnosticEvents.registry, source: DiagnosticSource.app);
    addTearDown(manager.close);
    manager.emit(
      AppDiagnosticEvents.routeChanged,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'fromRoute': DiagnosticValue.nullValue,
        'toRoute': DiagnosticValue.string('profile.diagnostics'),
        'navigationType': DiagnosticValue.string('test'),
      }),
    );
    final gateway = DefaultDiagnosticsViewerGateway(null, null, manager, null, buffer);

    final files = await gateway.listLogFiles();
    final events = await gateway.listEvents(source: DiagnosticsViewerSource.app, logFileId: files.single.fileId);
    final details = await gateway.loadEventDetails(events.items.single);

    expect(files.single.isLive, isTrue);
    expect(events.items.single.eventName, 'app.route.changed');
    expect(details.attributesText, contains('profile.diagnostics'));
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

Widget _host(DiagnosticsViewerGateway gateway, DiagnosticsCapturePreferenceStore preferences, {bool dark = false}) {
  return ProviderScope(
    overrides: [
      diagnosticsViewerGatewayProvider.overrideWithValue(gateway),
      diagnosticsCapturePreferenceStoreProvider.overrideWithValue(preferences),
      pluginRuntimeDebugHttpProvider.overrideWithBuild((ref, notifier) => const PluginRuntimeDebugHttp.disabled()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: DiagnosticsViewerPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
    ),
  );
}

final class _FakeDiagnosticsCapturePreferenceStore implements DiagnosticsCapturePreferenceStore {
  _FakeDiagnosticsCapturePreferenceStore({this.realtimeDetailsEnabled = false});

  bool realtimeDetailsEnabled;
  bool diagnosticsEnabled = false;

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
  _FakeDiagnosticsViewerGateway() {
    addTearDown(() {
      _captureTimer?.cancel();
      _captureChanges.close();
    });
  }
  final _captureChanges = StreamController<void>.broadcast();
  Timer? _captureTimer;
  @override
  DiagnosticsViewerCapture? activeCapture;
  @override
  Stream<void> watchCaptureChanges() => _captureChanges.stream;

  final List<DiagnosticsDetailMode> startedModes = <DiagnosticsDetailMode>[];
  final List<DiagnosticsViewerSource> startedSources = <DiagnosticsViewerSource>[];
  final List<DiagnosticsDetailMode> stoppedModes = <DiagnosticsDetailMode>[];
  final List<DiagnosticsViewerSource> requestedSources = <DiagnosticsViewerSource>[];
  var detailReads = 0;
  var previewReads = 0;
  var eventReads = 0;
  var fileListReads = 0;
  var failNextCapture = false;
  final requestedFiles = <String>[];

  @override
  Stream<void> watchLiveEvents() => const Stream<void>.empty();

  @override
  Future<List<DiagnosticsViewerLogFile>> listLogFiles() async {
    fileListReads += 1;
    return const <DiagnosticsViewerLogFile>[
      DiagnosticsViewerLogFile(
        fileId: 'live-current',
        startedAtUtcMicros: 1800000000000000,
        modifiedAtUtcMicros: 1800000000000000,
        storedBytes: 200,
        isCurrent: true,
        isLive: true,
      ),
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
    requestedFiles.add(logFileId);
    eventReads += 1;
    return DiagnosticsViewerEventPage(
      items: <DiagnosticsViewerEvent>[
        DiagnosticsViewerEvent(
          source: source,
          eventId: 'app_event_00000001',
          component: logFileId == 'live-current' ? 'feature.plugins' : 'app.bootstrap',
          eventName: logFileId == 'live-current' ? 'runtime.facade.call.error' : 'app.bootstrap.success',
          summary: 'Application started.',
          severity: logFileId == 'live-current' ? 'error' : 'info',
          phase: 'terminal',
          outcome: logFileId == 'live-current' ? 'error' : 'success',
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
    if (failNextCapture) {
      failNextCapture = false;
      throw const DiagnosticsViewerException('capture_unavailable');
    }
    startedModes.add(mode);
    startedSources.add(source);
    final capture = DiagnosticsViewerCapture(
      mode: mode,
      source: source,
      appSessionId: 'app_capture_0000001',
      expiresAtUtcMicros: DateTime.now().toUtc().add(const Duration(minutes: 15)).microsecondsSinceEpoch,
    );
    activeCapture = capture;
    _captureChanges.add(null);
    _captureTimer = Timer(const Duration(minutes: 15), () {
      unawaited(stopCapture(capture));
    });
    return capture;
  }

  @override
  Future<void> stopCapture(DiagnosticsViewerCapture capture) async {
    stoppedModes.add(capture.mode);
    activeCapture = null;
    _captureTimer?.cancel();
    _captureChanges.add(null);
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
