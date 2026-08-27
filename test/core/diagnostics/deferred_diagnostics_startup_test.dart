/// 延后诊断启动维护测试。
///
/// 职责：
/// - 验证大诊断历史的保留清理可以脱离服务打开流程。
///
/// 注意：
/// - 测试以临时目录隔离 TXT 诊断记录，不读取用户应用数据。
///
/// TODO:
/// - 无。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'diagnostics_testkit.dart';

void main() {
  test('deferred startup maintenance does not block diagnostics opening', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-deferred-diagnostics-startup-');
    addTearDown(() => root.delete(recursive: true));
    const configuration = PersistentDiagnosticsConfiguration(
      minimumSeverity: DiagnosticSeverity.trace,
      retentionPolicy: DiagnosticRetentionPolicy(regularEventBytes: 8 * 1024),
    );
    final first = await AppDiagnosticsService.open(
      dataRoot: root,
      configuration: configuration,
      idGenerator: SequentialDiagnosticIdGenerator(),
      clock: FixedDiagnosticClock(),
      buildMode: 'test',
      platform: 'windows-test',
    );
    for (var index = 0; index < 100; index += 1) {
      first.manager.emit(
        AppDiagnosticEvents.routeChanged,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'toRoute': DiagnosticValue.string('route$index')}),
      );
    }
    await first.manager.flush(timeout: const Duration(seconds: 5));
    await first.close();

    final second = await AppDiagnosticsService.open(
      dataRoot: root,
      configuration: configuration,
      idGenerator: SequentialDiagnosticIdGenerator(initialValue: 100000),
      clock: FixedDiagnosticClock(initialMicros: 1800000000000000),
      buildMode: 'test',
      platform: 'windows-test',
      deferStartupMaintenance: true,
    );
    addTearDown(second.close);

    expect((await second.listSessions()).items, hasLength(2));

    final staleRewrite = File(
      '${root.path}${Platform.pathSeparator}diagnostics'
      '${Platform.pathSeparator}staging${Platform.pathSeparator}'
      'rewrite-000001.partial.txt',
    );
    await staleRewrite.parent.create(recursive: true);
    await staleRewrite.writeAsString('stale rewrite data');

    await second.enforceRetention(configuration.retentionPolicy).timeout(const Duration(seconds: 5));

    expect((await second.listSessions()).items, hasLength(1));
    expect(await staleRewrite.exists(), isFalse);
  });
}
