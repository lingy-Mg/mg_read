import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test(
    'Facade queries TXT diagnostics and controls bounded capture modes',
    () async {
      final repositoryRoot = Directory.current.parent.parent;
      final runtimeDataRoot = await Directory.systemTemp.createTemp(
        'mgread-runtime-diagnostics-facade-',
      );
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: repositoryRoot,
        runtimeDataRoot: runtimeDataRoot,
      );
      addTearDown(() async {
        await runtime.debugDispose();
        if (await runtimeDataRoot.exists()) {
          await runtimeDataRoot.delete(recursive: true);
        }
      });

      await runtime.invoke(const RuntimePingInvocation());
      final initialSessions = await runtime.invoke(
        const RuntimeDiagnosticsSessionsInvocation(),
      );
      final initialEvents = await runtime.invoke(
        const RuntimeDiagnosticsEventsInvocation(),
      );

      expect(initialSessions.items, isNotEmpty);
      expect(initialEvents.items, isNotEmpty);
      expect(initialEvents.items.first.attributes, isNull);

      final capture = await runtime.invoke(
        RuntimeDiagnosticsCaptureStartInvocation(
          payloadKind: RuntimeDiagnosticPayloadKind.contentPayload,
          detailStorage: RuntimeDiagnosticDetailStorage.memoryOnly,
          duration: Duration(minutes: 1),
          maxStoredBytes: 1024 * 1024,
          components: <String>{'runtime.http', 'runtime.plugin'},
        ),
      );
      expect(capture.state, RuntimeDiagnosticSessionState.active);
      expect(capture.payloadKind, RuntimeDiagnosticPayloadKind.contentPayload);

      final event = await runtime.invoke(
        RuntimeDiagnosticsEventInvocation(initialEvents.items.first.eventId),
      );
      expect(event, isNotNull);
      expect(event!.attributes, isNotNull);

      final statistics = await runtime.invoke(
        const RuntimeDiagnosticsStatisticsInvocation(),
      );
      expect(statistics.segmentCount, greaterThanOrEqualTo(1));
      expect(statistics.eventTextBytes, greaterThan(0));

      await runtime.invoke(
        RuntimeDiagnosticsCaptureStopInvocation(capture.sessionId),
      );
      final sessionsAfterStop = await runtime.invoke(
        const RuntimeDiagnosticsSessionsInvocation(),
      );
      expect(
        sessionsAfterStop.items
            .firstWhere((session) => session.sessionId == capture.sessionId)
            .state,
        RuntimeDiagnosticSessionState.ended,
      );

      final diagnosticFiles = await Directory(
        '${runtimeDataRoot.path}${Platform.pathSeparator}diagnostics',
      ).list(recursive: true).where((entry) => entry is File).toList();
      expect(
        diagnosticFiles.every((entry) => entry.path.endsWith('.txt')),
        isTrue,
      );
    },
  );
}
