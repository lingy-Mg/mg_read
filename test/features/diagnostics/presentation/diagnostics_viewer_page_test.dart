import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_viewer_gateway.dart';
import 'package:mg_read/features/diagnostics/presentation/diagnostics_viewer_page.dart';

void main() {
  testWidgets(
    'opens bounded memory capture and reads details only after expansion',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(800, 1200));
      final gateway = _FakeDiagnosticsViewerGateway();
      await tester.pumpWidget(_host(gateway));
      await tester.pumpAndSettle();

      expect(gateway.startedModes, <DiagnosticsDetailMode>[
        DiagnosticsDetailMode.memoryOnly,
      ]);
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
      expect(gateway.startedModes, <DiagnosticsDetailMode>[
        DiagnosticsDetailMode.memoryOnly,
        DiagnosticsDetailMode.persistToText,
      ]);
      expect(gateway.stoppedModes, <DiagnosticsDetailMode>[
        DiagnosticsDetailMode.memoryOnly,
      ]);
      expect(find.text('详细日志 · TXT'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(gateway.stoppedModes, <DiagnosticsDetailMode>[
        DiagnosticsDetailMode.memoryOnly,
        DiagnosticsDetailMode.persistToText,
      ]);
    },
  );

  testWidgets('keeps app and Runtime event feeds separately pageable', (
    WidgetTester tester,
  ) async {
    final gateway = _FakeDiagnosticsViewerGateway();
    await tester.pumpWidget(_host(gateway));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Runtime'));
    await tester.pumpAndSettle();

    expect(find.text('runtime.core.ready'), findsOneWidget);
    expect(gateway.requestedSources, contains(DiagnosticsViewerSource.app));
    expect(gateway.requestedSources, contains(DiagnosticsViewerSource.runtime));
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

Widget _host(DiagnosticsViewerGateway gateway) {
  return ProviderScope(
    overrides: [diagnosticsViewerGatewayProvider.overrideWithValue(gateway)],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: DiagnosticsViewerPage(
        onBackRequested: () {},
        onDestinationRequested: (_) {},
      ),
    ),
  );
}

final class _FakeDiagnosticsViewerGateway implements DiagnosticsViewerGateway {
  final List<DiagnosticsDetailMode> startedModes = <DiagnosticsDetailMode>[];
  final List<DiagnosticsDetailMode> stoppedModes = <DiagnosticsDetailMode>[];
  final List<DiagnosticsViewerSource> requestedSources =
      <DiagnosticsViewerSource>[];
  var detailReads = 0;
  var previewReads = 0;

  @override
  Future<DiagnosticsViewerEventPage> listEvents({
    required DiagnosticsViewerSource source,
    String? cursor,
  }) async {
    requestedSources.add(source);
    final isApp = source == DiagnosticsViewerSource.app;
    return DiagnosticsViewerEventPage(
      items: <DiagnosticsViewerEvent>[
        DiagnosticsViewerEvent(
          source: source,
          eventId: isApp ? 'app_event_00000001' : 'runtime_event_0001',
          component: isApp ? 'app.bootstrap' : 'runtime.core',
          eventName: isApp ? 'app.bootstrap.success' : 'runtime.core.ready',
          summary: isApp ? 'Application started.' : 'Runtime ready.',
          severity: 'info',
          phase: 'terminal',
          outcome: 'success',
          occurredAtUtcMicros: 1_800_000_000_000_000,
          durationMicros: 1200,
          attachmentCount: isApp ? 1 : 0,
          capturedBytes: isApp ? 25 : 0,
        ),
      ],
    );
  }

  @override
  Future<DiagnosticsViewerEventDetails> loadEventDetails(
    DiagnosticsViewerEvent event,
  ) async {
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
        ),
      ],
    );
  }

  @override
  Future<String> readAttachmentPreview(
    DiagnosticsViewerAttachment attachment,
  ) async {
    previewReads += 1;
    return '<html>safe preview</html>';
  }

  @override
  Future<DiagnosticsViewerCapture> startCapture(
    DiagnosticsDetailMode mode,
  ) async {
    startedModes.add(mode);
    return DiagnosticsViewerCapture(
      mode: mode,
      appSessionId: 'app_capture_0000001',
      runtimeSessionId: 'runtime_capture_01',
      expiresAtUtcMicros: 1_800_000_900_000_000,
    );
  }

  @override
  Future<void> stopCapture(DiagnosticsViewerCapture capture) async {
    stoppedModes.add(capture.mode);
  }
}
