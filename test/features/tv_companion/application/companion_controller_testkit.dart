/// Shared real-socket fixture for coordinator integration tests.
///
/// The fixture wires two app containers to in-memory trust stores and routes
/// TV HTTP requests into the real controller. Only the network permission and
/// loopback endpoint policy are substituted; handshake, encryption, message
/// protocol, authorization and command execution remain production code.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/tv_companion/application/companion_command_engine.dart';
import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';
import 'package:mg_read/features/tv_companion/data/companion_network.dart';
import 'package:mg_read/features/tv_companion/data/companion_repository.dart';
import 'package:mg_read/features/tv_companion/data/companion_secure_channel.dart';
import 'package:mg_read/features/tv_companion/domain/companion_models.dart';

const companionTestPsk = <int>[
  0x11,
  0x52,
  0x93,
  0xd4,
  0x15,
  0x56,
  0x97,
  0xd8,
  0x19,
  0x5a,
  0x9b,
  0xdc,
  0x1d,
  0x5e,
  0x9f,
  0xe0,
  0x21,
  0x62,
  0xa3,
  0xe4,
  0x25,
  0x66,
  0xa7,
  0xe8,
  0x29,
  0x6a,
  0xab,
  0xec,
  0x2d,
  0x6e,
  0xaf,
  0xf0,
];

const companionTestPhoneId = 'phone-device-0001';
const companionTestTvId = 'tv-device-0000001';
const companionTestRotatedPsk = <int>[
  0xa1,
  0xe2,
  0x23,
  0x64,
  0xa5,
  0xe6,
  0x27,
  0x68,
  0xa9,
  0xea,
  0x2b,
  0x6c,
  0xad,
  0xee,
  0x2f,
  0x70,
  0xb1,
  0xf2,
  0x33,
  0x74,
  0xb5,
  0xf6,
  0x37,
  0x78,
  0xb9,
  0xfa,
  0x3b,
  0x7c,
  0xbd,
  0xfe,
  0x3f,
  0x80,
];

final class CompanionTestIdentityStore implements DeviceIdentityStore {
  CompanionTestIdentityStore(this.deviceId, this.label);
  final String deviceId;
  final String label;
  final Map<String, List<int>> secrets = {};

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async => secrets.remove(peerDeviceId);

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => LocalDeviceIdentity(deviceId: deviceId, label: label);

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => secrets[peerDeviceId];

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async => secrets[peerDeviceId] = List<int>.unmodifiable(secret);
}

final class CompanionTestPairedDevices implements PairedDeviceRepository {
  final Map<String, PairedDevice> devices = {};
  @override
  Future<List<PairedDevice>> list() async => devices.values.toList();
  @override
  Future<PairedDevice?> read(String deviceId) async => devices[deviceId];
  @override
  Future<void> remove(String deviceId) async => devices.remove(deviceId);
  @override
  Future<void> upsert(PairedDevice device) async => devices[device.deviceId] = device;
}

final class CompanionTestRepository implements CompanionRepository {
  final MemoryCompanionRepository _memory = MemoryCompanionRepository();
  Completer<void>? selectedClearEntered;
  Completer<void>? selectedClearGate;

  @override
  Future<bool> receiverEnabled() => _memory.receiverEnabled();
  @override
  Future<void> setReceiverEnabled(bool value) => _memory.setReceiverEnabled(value);
  @override
  Future<CompanionPolicy> policy(String deviceId) => _memory.policy(deviceId);
  @override
  Future<void> setPolicy(String deviceId, CompanionPolicy policy) => _memory.setPolicy(deviceId, policy);
  @override
  Future<String?> selectedDevice() => _memory.selectedDevice();
  @override
  Future<void> setSelectedDevice(String? deviceId) async {
    await _memory.setSelectedDevice(deviceId);
    if (deviceId == null && selectedClearGate != null) {
      if (selectedClearEntered case final entered? when !entered.isCompleted) entered.complete();
      await selectedClearGate!.future;
    }
  }
}

final class CompanionTestNetwork extends CompanionNetwork {
  const CompanionTestNetwork();
  @override
  Future<bool> available() async => true;
  @override
  Future<bool> ensurePermission() async => true;
  @override
  Future<List<String>> addresses() async => ['127.0.0.1'];
}

final class CompanionPairFixture {
  CompanionPairFixture._({
    required this.phoneContainer,
    required this.tvContainer,
    required this.phoneRepository,
    required this.tvRepository,
    required this.tvServer,
    required this.phoneLibrary,
    required this.tvLibrary,
    required this.phoneIdentity,
    required this.tvIdentity,
    required this.phoneDevices,
    required this.tvDevices,
  });

  final ProviderContainer phoneContainer;
  final ProviderContainer tvContainer;
  final CompanionTestRepository phoneRepository;
  final MemoryCompanionRepository tvRepository;
  final HttpServer tvServer;
  final ContentLibrary? phoneLibrary;
  final ContentLibrary? tvLibrary;
  final CompanionTestIdentityStore phoneIdentity;
  final CompanionTestIdentityStore tvIdentity;
  final CompanionTestPairedDevices phoneDevices;
  final CompanionTestPairedDevices tvDevices;
  CompanionController get phone => phoneContainer.read(companionControllerProvider);
  CompanionController get tv => tvContainer.read(companionControllerProvider);
  bool _closed = false;

  static Future<CompanionPairFixture> create({
    bool allowControl = true,
    bool allowBrowseLibrary = false,
    Future<void> Function(String key)? onNavigate,
    Future<void> Function(CompanionContentRef content, CompanionExecutionContext context)? onHandoff,
    SourceContentGateway? sourceGateway,
    CompanionNetwork? phoneNetwork,
    ContentLibrary? phoneLibrary,
    ContentLibrary? tvLibrary,
  }) async {
    final phoneIdentity = CompanionTestIdentityStore(companionTestPhoneId, 'Phone');
    final tvIdentity = CompanionTestIdentityStore(companionTestTvId, 'TV');
    await phoneIdentity.writePeerSecret(companionTestTvId, companionTestPsk);
    await tvIdentity.writePeerSecret(companionTestPhoneId, companionTestPsk);
    final phoneDevices = CompanionTestPairedDevices();
    final tvDevices = CompanionTestPairedDevices();
    await phoneDevices.upsert(_paired(companionTestTvId, 'TV'));
    await tvDevices.upsert(_paired(companionTestPhoneId, 'Phone'));
    final phoneRepository = CompanionTestRepository();
    final tvRepository = MemoryCompanionRepository()..enabled = true;

    ProviderContainer buildContainer({
      required CompanionTestIdentityStore identity,
      required CompanionTestPairedDevices devices,
      required CompanionRepository repository,
      required ContentLibrary? library,
      required CompanionNetwork network,
    }) => ProviderContainer(
      overrides: [
        deviceIdentityStoreProvider.overrideWithValue(identity),
        pairedDeviceRepositoryProvider.overrideWithValue(devices),
        companionRepositoryProvider.overrideWithValue(repository),
        companionNetworkProvider.overrideWithValue(network),
        companionNavigateProvider.overrideWithValue(onNavigate ?? (_) async {}),
        companionHandoffLauncherProvider.overrideWithValue(onHandoff ?? (_, _) async {}),
        sourceContentGatewayProvider.overrideWithValue(sourceGateway ?? _UnavailableTestSourceGateway()),
        companionLibraryProvider.overrideWithValue(library == null ? null : () async => library),
        companionChannelConnectorProvider.overrideWith(
          (ref) =>
              ({required uri, required localDeviceId, required remoteDeviceId, required sharedSecret}) => CompanionSecureChannel.connect(
                uri: uri,
                localDeviceId: localDeviceId,
                remoteDeviceId: remoteDeviceId,
                sharedSecret: sharedSecret,
                allowLoopbackForTesting: true,
              ),
        ),
      ],
    );

    final phoneContainer = buildContainer(
      identity: phoneIdentity,
      devices: phoneDevices,
      repository: phoneRepository,
      library: phoneLibrary,
      network: phoneNetwork ?? const CompanionTestNetwork(),
    );
    final tvContainer = buildContainer(
      identity: tvIdentity,
      devices: tvDevices,
      repository: tvRepository,
      library: tvLibrary,
      network: const CompanionTestNetwork(),
    );
    await Future.wait([
      phoneContainer.read(companionControllerProvider).initialize(),
      tvContainer.read(companionControllerProvider).initialize(),
    ]);
    final tvServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    tvServer.listen((request) => unawaited(tvContainer.read(companionControllerProvider).handleRequest(request)));
    final fixture = CompanionPairFixture._(
      phoneContainer: phoneContainer,
      tvContainer: tvContainer,
      phoneRepository: phoneRepository,
      tvRepository: tvRepository,
      tvServer: tvServer,
      phoneLibrary: phoneLibrary,
      tvLibrary: tvLibrary,
      phoneIdentity: phoneIdentity,
      tvIdentity: tvIdentity,
      phoneDevices: phoneDevices,
      tvDevices: tvDevices,
    );
    // Use the same public operation as explicit approval in the TV UI so the
    // policy is bound to the exact shared secret represented by the fixture.
    await fixture.tv.setPolicy(companionTestPhoneId, CompanionPolicy(control: allowControl, browseLibrary: allowBrowseLibrary));
    return fixture;
  }

  Future<void> rotatePhonePairing(List<int> newSecret) async {
    await tvDevices.remove(companionTestPhoneId);
    await tvIdentity.deletePeerSecret(companionTestPhoneId);
    await phoneIdentity.deletePeerSecret(companionTestTvId);
    await tvDevices.upsert(_paired(companionTestPhoneId, 'Phone re-paired'));
    await tvIdentity.writePeerSecret(companionTestPhoneId, newSecret);
    await phoneIdentity.writePeerSecret(companionTestTvId, newSecret);
  }

  Future<void> connect({String label = 'Test TV'}) async => phone.connect(
    CompanionEndpoint(
      deviceId: companionTestTvId,
      label: label,
      address: '127.0.0.1',
      port: tvServer.port,
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      receiving: true,
    ),
  );

  Future<void> waitFor(bool Function() predicate, {Duration timeout = const Duration(seconds: 4)}) async {
    final clock = Stopwatch()..start();
    while (!predicate()) {
      if (clock.elapsed >= timeout) throw TimeoutException('companion fixture condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await phone.disconnect();
    phoneContainer.dispose();
    tvContainer.dispose();
    await tvServer.close(force: true);
    if (phoneLibrary != null) await phoneLibrary!.close();
    if (tvLibrary != null && !identical(tvLibrary, phoneLibrary)) await tvLibrary!.close();
  }
}

/// A second real TV process with the same paired device ID but a different
/// boot epoch. It lets connection-race tests distinguish which endpoint won.
final class CompanionAlternateTvHost {
  CompanionAlternateTvHost._(this.container, this.server);
  final ProviderContainer container;
  final HttpServer server;
  CompanionController get tv => container.read(companionControllerProvider);

  static Future<CompanionAlternateTvHost> create({
    required CompanionPairFixture fixture,
    Future<void> Function(String key)? onNavigate,
  }) async {
    final identity = CompanionTestIdentityStore(companionTestTvId, 'Replacement TV');
    await identity.writePeerSecret(companionTestPhoneId, companionTestPsk);
    final devices = CompanionTestPairedDevices();
    await devices.upsert((await fixture.tvDevices.read(companionTestPhoneId))!);
    final repository = MemoryCompanionRepository()..enabled = true;
    final container = ProviderContainer(
      overrides: [
        deviceIdentityStoreProvider.overrideWithValue(identity),
        pairedDeviceRepositoryProvider.overrideWithValue(devices),
        companionRepositoryProvider.overrideWithValue(repository),
        companionNetworkProvider.overrideWithValue(const CompanionTestNetwork()),
        companionNavigateProvider.overrideWithValue(onNavigate ?? (_) async {}),
      ],
    );
    final tv = container.read(companionControllerProvider);
    await tv.initialize();
    await tv.setPolicy(companionTestPhoneId, const CompanionPolicy(control: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => unawaited(tv.handleRequest(request)));
    return CompanionAlternateTvHost._(container, server);
  }

  CompanionEndpoint get endpoint => CompanionEndpoint(
    deviceId: companionTestTvId,
    label: 'Replacement endpoint',
    address: '127.0.0.1',
    port: server.port,
    expiresAt: DateTime.now().add(const Duration(minutes: 1)),
    receiving: true,
  );

  Future<void> close() async {
    container.dispose();
    await server.close(force: true);
  }
}

final class _UnavailableTestSourceGateway implements SourceContentGateway {
  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();
  @override
  Future<List<PluginSourceDescriptor>> listSources() async => const [];
}

PairedDevice _paired(String id, String label) => PairedDevice(
  autoSync: false,
  createdAtUtc: DateTime.utc(2026),
  deviceId: id,
  label: label,
  mode: PairedSyncMode.bidirectional,
  platform: PairedDevicePlatform.unknown,
  syncBookshelf: false,
  syncPlugins: false,
);
