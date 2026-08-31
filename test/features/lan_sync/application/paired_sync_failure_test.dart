import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/lan_sync/application/paired_sync_failure.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('paired failure owner span retains stage, exception text, and stack for the debug console', () {
    final kit = DiagnosticsTestkit();
    addTearDown(kit.dispose);
    final session = PairedSyncDiagnosticSession.start(
      kit.manager,
      role: 'paired_outbound',
      operation: PairedSyncOperation.pull,
      automatic: false,
      peerPlatform: PairedDevicePlatform.windows,
    );
    session.stage('connect');
    final failure = PairedSyncFailure.fromException(
      stage: session.stageName,
      error: const SocketException('Connection refused'),
      stackTrace: StackTrace.fromString('paired-connect-stack'),
    );

    session.fail(failure);

    final terminal = kit.sink.events.singleWhere((event) => event.eventName == 'lan.sync.session.error');
    expect((terminal.attributes.values['operation']! as DiagnosticStringValue).value, 'pull');
    expect((terminal.attributes.values['errorLocation']! as DiagnosticStringValue).value, 'connect');
    expect((terminal.attributes.values['errorText']! as DiagnosticStringValue).value, contains('Connection refused'));
    expect((terminal.attributes.values['stackTrace']! as DiagnosticStringValue).value, contains('paired-connect-stack'));
    final console = const DiagnosticConsoleFormatter();
    expect(console.shouldMirror(terminal), isTrue);
    expect(console.format(terminal), contains('Connection refused'));
    expect(console.format(terminal), contains('paired-connect-stack'));
  });

  test('partial transfer reports the exact interrupted stage to the UI', () {
    final failure = PairedSyncFailure.fromException(
      stage: 'complete',
      error: PairedSyncPartialException(
        StateError('archive import failed'),
        stage: 'receive_payload',
        causeStackTrace: StackTrace.fromString('receive-stack'),
      ),
      stackTrace: StackTrace.current,
    );

    expect(failure.code, 'device_sync_partial');
    expect(failure.stage, 'receive_payload');
    expect(failure.uiDetails, contains('接收并导入数据'));
    expect(failure.uiDetails, contains('archive import failed'));
    expect(failure.stackTrace, contains('receive-stack'));
  });

  test('remote reverse failure keeps the remote code and stage', () {
    final failure = PairedSyncFailure.remote(
      code: 'lan_sync_connect_failed',
      stage: 'connect',
      errorText: 'SocketException: Connection refused',
      receiptStackTrace: StackTrace.current,
    );
    expect(failure.remote, isTrue);
    expect(failure.uiDetails, contains('lan_sync_connect_failed'));
    expect(failure.uiDetails, contains('建立局域网连接'));
    expect(failure.uiDetails, contains('Connection refused'));
  });

  test('disconnect keeps the stage that was actually waiting for data', () {
    final failure = PairedSyncFailure.fromException(
      stage: 'manifest_exchange',
      error: const LanSyncTransportException('lan_sync_disconnected'),
      stackTrace: StackTrace.current,
    );

    expect(failure.stage, 'manifest_exchange');
    expect(failure.uiDetails, contains('交换同步清单'));
  });

  test('authenticated peer failure retains the peer stage and concrete reason', () {
    final failure = PairedSyncFailure.fromException(
      stage: 'manifest_exchange',
      error: const PairedSyncPeerFailureException(
        code: 'lan_sync_local_manifest_runtime_unavailable',
        stage: 'local_manifest',
        errorText: 'PluginRuntimeException(runtime_unavailable)',
      ),
      stackTrace: StackTrace.current,
    );

    expect(failure.remote, isTrue);
    expect(failure.code, 'lan_sync_local_manifest_runtime_unavailable');
    expect(failure.stage, 'local_manifest');
    expect(failure.uiDetails, contains('runtime_unavailable'));
  });
}
