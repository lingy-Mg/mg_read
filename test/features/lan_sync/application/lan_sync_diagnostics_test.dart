import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_controller.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_network_environment.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('LAN sync diagnostics retain counts and reject sensitive fields', () {
    final kit = DiagnosticsTestkit();
    addTearDown(kit.dispose);
    final span = kit.manager.startSpan(
      AppDiagnosticEvents.lanSyncSession,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'role': DiagnosticValue.string('sender'),
        'stage': DiagnosticValue.string('start'),
      }),
    );
    span.complete(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'stage': DiagnosticValue.string('terminal'),
        'resultState': DiagnosticValue.string('success'),
        'pluginCount': DiagnosticValue.int64(2),
        'itemCount': DiagnosticValue.int64(8),
        'bytes': DiagnosticValue.int64(4096),
      }),
    );

    final wire = kit.sink.events.map(const DiagnosticEventCodec().encode).join();
    expect(wire, isNot(contains('192.168.1.9')));
    expect(wire, isNot(contains('123456')));
    expect(wire, isNot(contains('mgread://lan-sync')));
    expect(wire, isNot(contains('Bearer canary-secret')));
    expect(wire, isNot(contains('测试书名')));

    kit.manager.emit(
      AppDiagnosticEvents.lanSyncStage,
      traceContext: span.traceContext,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'role': DiagnosticValue.string('receiver'),
        'stage': DiagnosticValue.string('plugin_finalize_started'),
        'bytes': DiagnosticValue.int64(4096),
        'elapsedMicros': DiagnosticValue.int64(1234),
      }),
    );
    expect(kit.sink.events.last.eventName, 'lan.sync.stage');
    expect(kit.sink.events.last.traceId, span.traceContext.traceId);

    expect(
      () => kit.manager.startSpan(
        AppDiagnosticEvents.lanSyncSession,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'role': DiagnosticValue.string('receiver'),
          'stage': DiagnosticValue.string('start'),
          'pairingCode': DiagnosticValue.string('123456'),
        }),
      ),
      throwsA(isA<DiagnosticSchemaError>()),
    );
  });

  test('closed diagnostics do not prevent a sender session', () async {
    final diagnostics = DiagnosticsManager(
      sink: const NoopDiagnosticEventSink(),
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
    );
    await diagnostics.close();
    final container = ProviderContainer(
      overrides: [
        diagnosticsManagerProvider.overrideWithValue(diagnostics),
        lanSyncGatewayProvider.overrideWithValue(const _EmptyGateway()),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(const _AvailableNetwork()),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(lanSyncControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    await container.read(lanSyncControllerProvider.notifier).startSending();

    expect(container.read(lanSyncControllerProvider).phase, LanSyncPhase.waitingForPeer);
    await container.read(lanSyncControllerProvider.notifier).cancel();
  });

  test('gateway failure retains its stable stage and Runtime code', () async {
    final container = ProviderContainer(
      overrides: [
        lanSyncGatewayProvider.overrideWithValue(const _FailingGateway()),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(const _AvailableNetwork()),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(lanSyncControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    await container.read(lanSyncControllerProvider.notifier).startSending();

    final state = container.read(lanSyncControllerProvider);
    expect(state.phase, LanSyncPhase.failed);
    expect(state.errorCode, 'lan_sync_prepare_runtime_invalid_response');
  });

  test('temporary transfer failure logs the safe reason and complete application stack', () async {
    final kit = DiagnosticsTestkit();
    addTearDown(kit.dispose);
    final container = ProviderContainer(
      overrides: [
        diagnosticsManagerProvider.overrideWithValue(kit.manager),
        lanSyncGatewayProvider.overrideWithValue(const _DetailedFailingGateway()),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(const _AvailableNetwork()),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(lanSyncControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    await container.read(lanSyncControllerProvider.notifier).startSending();

    final terminal = kit.sink.events.singleWhere((event) => event.eventName == 'lan.sync.session.error');
    expect((terminal.attributes.values['errorCode']! as DiagnosticStringValue).value, 'lan_sync_prepare_manifest_invalid');
    expect((terminal.attributes.values['errorLocation']! as DiagnosticStringValue).value, 'prepare');
    expect((terminal.attributes.values['errorText']! as DiagnosticStringValue).value, contains('invalid_content_kind'));
    expect((terminal.attributes.values['stackTrace']! as DiagnosticStringValue).value, contains('detailed-manifest-stack'));
    final console = const DiagnosticConsoleFormatter().format(terminal);
    expect(console, contains('invalid_content_kind'));
    expect(console, contains('detailed-manifest-stack'));
    expect(console, isNot(contains('secret-book-title')));
  });

  test('capacity failure code has explicit LAN user feedback', () {
    expect(lanSyncFailureMessage('lan_sync_import_bookshelf_capacity_exceeded'), '书架已满，请先清理书籍');
    expect(lanSyncFailureMessage('lan_sync_manifest_invalid'), contains('Debug 控制台'));
    expect(lanSyncFailureMessage('lan_sync_prepare_manifest_invalid'), contains('Debug 控制台'));
  });

  test('temporary transfer does not start without a local network', () async {
    final gateway = _CountingGateway();
    final container = ProviderContainer(
      overrides: [
        lanSyncGatewayProvider.overrideWithValue(gateway),
        lanSyncNetworkEnvironmentProvider.overrideWithValue(const _UnavailableNetwork()),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(lanSyncControllerProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);

    await container.read(lanSyncControllerProvider.notifier).startSending();

    final state = container.read(lanSyncControllerProvider);
    expect(state.phase, LanSyncPhase.failed);
    expect(state.errorCode, 'lan_sync_local_network_unavailable');
    expect(gateway.manifestCreateCount, 0);

    container.read(lanSyncControllerProvider.notifier).reset();
    await container.read(lanSyncControllerProvider.notifier).startReceiving();

    final receivingState = container.read(lanSyncControllerProvider);
    expect(receivingState.phase, LanSyncPhase.failed);
    expect(receivingState.errorCode, 'lan_sync_local_network_unavailable');
  });
}

final class _AvailableNetwork implements LanSyncNetworkEnvironment {
  const _AvailableNetwork();

  @override
  Future<bool> isLocalNetworkAvailable() async => true;
}

final class _UnavailableNetwork implements LanSyncNetworkEnvironment {
  const _UnavailableNetwork();

  @override
  Future<bool> isLocalNetworkAvailable() async => false;
}

class _EmptyGateway implements LanSyncGateway {
  const _EmptyGateway();

  @override
  Future<LanSyncManifest> createManifest() async =>
      const LanSyncManifest(plugins: <LanSyncPluginDescriptor>[], shelfItems: <LanSyncShelfItem>[], skippedShelfItems: 0);

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins) async {}

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => const Stream<List<int>>.empty();

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest) => throw UnimplementedError();

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) => throw UnimplementedError();

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() => throw UnimplementedError();

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
  }) => throw UnimplementedError();
}

final class _FailingGateway extends _EmptyGateway {
  const _FailingGateway();

  @override
  Future<LanSyncManifest> createManifest() async => throw const LanSyncGatewayException('runtime_invalid_response');
}

final class _DetailedFailingGateway extends _EmptyGateway {
  const _DetailedFailingGateway();

  @override
  Future<LanSyncManifest> createManifest() => Future<LanSyncManifest>.error(
    const LanSyncGatewayException('manifest_invalid', reason: 'invalid_content_kind'),
    StackTrace.fromString('detailed-manifest-stack'),
  );
}

final class _CountingGateway extends _EmptyGateway {
  int manifestCreateCount = 0;

  @override
  Future<LanSyncManifest> createManifest() async {
    manifestCreateCount++;
    return super.createManifest();
  }
}
