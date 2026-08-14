import 'dart:io';

import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'diagnostics_testkit.dart';

final class PersistentDiagnosticsTestkit {
  PersistentDiagnosticsTestkit._(this.root, this.service);

  final Directory root;
  final AppDiagnosticsService service;
  bool _closed = false;

  static Future<PersistentDiagnosticsTestkit> open({
    PersistentDiagnosticsConfiguration configuration =
        const PersistentDiagnosticsConfiguration(
          minimumSeverity: DiagnosticSeverity.trace,
        ),
    DiagnosticEventRegistry? registry,
    DiagnosticClock? clock,
  }) async {
    final root = await Directory.systemTemp.createTemp('mg-read-diagnostics-');
    final service = await AppDiagnosticsService.open(
      dataRoot: root,
      configuration: configuration,
      idGenerator: SequentialDiagnosticIdGenerator(),
      clock: clock ?? FixedDiagnosticClock(),
      registry: registry,
      buildMode: 'test',
      platform: 'windows-test',
    );
    return PersistentDiagnosticsTestkit._(root, service);
  }

  Future<void> closeService() async {
    if (_closed) return;
    _closed = true;
    await service.close();
  }

  Future<void> dispose() async {
    await closeService();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
