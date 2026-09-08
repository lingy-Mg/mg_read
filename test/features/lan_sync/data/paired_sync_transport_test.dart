import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/application/device_identity_store.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/application/paired_device_repository.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  test('paired receiver initiates one authenticated bidirectional sync without sender approval', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 1);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_device_123456', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_device_12345678', label: '手机');
    final serverPeer = _device(clientIdentity, PairedDevicePlatform.android, label: '旧手机名');
    final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows, label: '旧电脑名');
    final serverRepository = _MemoryPairedDeviceRepository(serverPeer);
    final serverSecrets = _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret});
    final serverGateway = _ShelfGateway('desktop-book');
    final clientGateway = _ShelfGateway('phone-book');
    final serverResult = Completer<PairedSyncRunSummary>();
    String? authenticatedClientLabel;
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: serverRepository,
      identityStore: serverSecrets,
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
          authenticatedClientLabel = session.peer.label;
        } on Object catch (error, stackTrace) {
          serverResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: clientPeer,
      sharedSecret: secret,
    );

    expect(session.peer.label, serverIdentity.label);
    final clientSummary = await session.run(gateway: clientGateway);
    final hostSummary = await serverResult.future;

    expect(clientSummary.receivedBooks, 1);
    expect(clientSummary.sentBooks, 1);
    expect(hostSummary.receivedBooks, 1);
    expect(hostSummary.sentBooks, 1);
    expect(clientGateway.appliedIds, <String>['desktop-book']);
    expect(serverGateway.appliedIds, <String>['phone-book']);
    expect(authenticatedClientLabel, clientIdentity.label);
  });

  test('paired sync materializes only the development source selected by the receiver', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 11);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_lazy_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_lazy_1234567890', label: '手机');
    final serverPeer = _device(clientIdentity, PairedDevicePlatform.android);
    final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows);
    final serverGateway = _PluginGateway(
      offeredIds: const <String>['org.example.selected', 'org.example.same'],
      requestedId: 'org.example.client-only',
    );
    final clientGateway = _PluginGateway(offeredIds: const <String>['org.example.client-only'], requestedId: 'org.example.selected');
    final serverResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(serverPeer),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
        } on Object catch (error, stackTrace) {
          serverResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: clientPeer,
      sharedSecret: secret,
    );

    final clientSummary = await session.run(gateway: clientGateway, operation: PairedSyncOperation.pull);
    final hostSummary = await serverResult.future;

    expect(serverGateway.materializedIds, <String>['org.example.selected']);
    expect(clientGateway.importedIds, <String>['org.example.selected']);
    expect(clientGateway.materializedIds, isEmpty);
    expect(serverGateway.importedIds, isEmpty);
    expect(clientSummary.receivedPlugins, 1);
    expect(clientSummary.sentPlugins, 0);
    expect(hostSummary.sentPlugins, 1);
    expect(hostSummary.receivedPlugins, 0);
  });

  test('paired sync runs selected plugin artifacts as bounded parallel tasks', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 41);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_parallel_12345', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_parallel_1234567', label: '手机');
    const pluginIds = <String>['org.example.one', 'org.example.two', 'org.example.three', 'org.example.four'];
    final serverGateway = _PluginGateway(offeredIds: pluginIds, requestedId: null, taskDelay: const Duration(milliseconds: 40));
    final clientGateway = _PluginGateway(
      offeredIds: const <String>[],
      requestedId: null,
      requestedIds: pluginIds.toSet(),
      taskDelay: const Duration(milliseconds: 40),
    );
    final serverResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(_device(clientIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
        } on Object catch (error, stackTrace) {
          serverResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: _device(serverIdentity, PairedDevicePlatform.windows),
      sharedSecret: secret,
    );

    final summary = await session.run(gateway: clientGateway, operation: PairedSyncOperation.pull);
    await serverResult.future;

    expect(summary.receivedPlugins, pluginIds.length);
    expect(serverGateway.maximumMaterializationTasks, 3);
    expect(clientGateway.maximumImportTasks, 3);
  });

  test('artifact upload returns the receiver import failure instead of status 400', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 51);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_upload_error_1', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_upload_error_123', label: '手机');
    final serverGateway = _PluginGateway(offeredIds: const <String>[], requestedId: 'org.example.selected', rejectImport: true);
    final clientGateway = _PluginGateway(offeredIds: const <String>['org.example.selected'], requestedId: null);
    final serverResult = Completer<Object>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(_device(clientIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
        } on Object catch (error) {
          serverResult.complete(error);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: _device(serverIdentity, PairedDevicePlatform.windows),
      sharedSecret: secret,
    );

    await expectLater(
      session.run(gateway: clientGateway, operation: PairedSyncOperation.push),
      throwsA(
        isA<PairedSyncPeerFailureException>()
            .having((error) => error.code, 'code', 'lan_sync_receive_payload_plugin_import_rejected')
            .having((error) => error.stage, 'stage', 'receive_payload')
            .having((error) => error.errorText, 'errorText', contains('plugin_import_rejected')),
      ),
    );
    expect(
      await serverResult.future,
      isA<PairedSyncPeerFailureException>().having((error) => error.code, 'code', 'lan_sync_receive_payload_plugin_import_rejected'),
    );
  });

  for (final rejectEarly in [true, false]) {
    test('paired import failure preserves its cause and allows retry (early=$rejectEarly)', () async {
      final addresses = await eligibleLanSyncAddresses();
      if (addresses.isEmpty) return;
      final secret = List<int>.generate(32, (index) => index + 11);
      const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_lazy_12345678', label: '开发电脑');
      const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_lazy_1234567890', label: '手机');
      final serverPeer = _device(clientIdentity, PairedDevicePlatform.android);
      final clientPeer = _device(serverIdentity, PairedDevicePlatform.windows);
      final serverGateway = _PluginGateway(
        offeredIds: const <String>['org.example.selected', 'org.example.same'],
        requestedId: 'org.example.client-only',
      );
      final clientGateway = _PluginGateway(
        offeredIds: const <String>['org.example.client-only'],
        requestedId: 'org.example.selected',
        rejectImport: rejectEarly,
        reportFailure: !rejectEarly,
      );
      final serverResult = Completer<Object>();
      final host = await PairedSyncHost.start(
        identity: serverIdentity,
        devices: _MemoryPairedDeviceRepository(serverPeer),
        identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
        onIncoming: (session) async {
          try {
            serverResult.complete(await session.run(gateway: serverGateway));
          } on Object catch (error) {
            serverResult.complete(error);
          }
        },
      );
      addTearDown(host.close);
      final session = await PairedSyncClientSession.connectAny(
        endpoints: <PairedSyncEndpoint>[
          PairedSyncEndpoint(
            address: addresses.first,
            deviceId: serverIdentity.deviceId,
            expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
            label: serverIdentity.label,
            port: host.port,
          ),
        ],
        identity: clientIdentity,
        peer: clientPeer,
        sharedSecret: secret,
      );

      await expectLater(
        session.run(gateway: clientGateway, operation: PairedSyncOperation.pull).timeout(const Duration(seconds: 3)),
        throwsA(isA<LanSyncGatewayException>().having((error) => error.code, 'code', 'plugin_import_rejected')),
      );
      final remoteFailure = await serverResult.future.timeout(const Duration(seconds: 3));
      expect(remoteFailure, isA<PairedSyncPeerFailureException>());
      expect((remoteFailure as PairedSyncPeerFailureException).code, 'lan_sync_receive_payload_plugin_import_rejected');
      clientGateway.rejectImport = false;
      clientGateway.reportFailure = false;
      clientGateway.importedIds.clear();
      final retryResult = Completer<PairedSyncRunSummary>();
      final retryHost = await PairedSyncHost.start(
        identity: serverIdentity,
        devices: _MemoryPairedDeviceRepository(serverPeer),
        identityStore: _MemoryIdentityStore(serverIdentity, {clientIdentity.deviceId: secret}),
        discoveryPort: 0,
        onIncoming: (session) async {
          try {
            retryResult.complete(await session.run(gateway: serverGateway));
          } on Object catch (error, stack) {
            retryResult.completeError(error, stack);
          }
        },
      );
      addTearDown(retryHost.close);
      final retry = await PairedSyncClientSession.connectAny(
        endpoints: [
          PairedSyncEndpoint(
            address: addresses.first,
            deviceId: serverIdentity.deviceId,
            expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
            label: serverIdentity.label,
            port: retryHost.port,
          ),
        ],
        identity: clientIdentity,
        peer: clientPeer,
        sharedSecret: secret,
      );
      final summary = await retry.run(gateway: clientGateway, operation: PairedSyncOperation.pull);
      expect(summary.receivedPlugins, 1);
      expect((await retryResult.future).sentPlugins, 1);
    });
  }

  test('paired initiator can push without receiving remote shelf changes', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 21);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_push_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_push_1234567890', label: '手机');
    final serverGateway = _ShelfGateway('desktop-book');
    final clientGateway = _ShelfGateway('phone-book');
    final serverResult = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(_device(clientIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          serverResult.complete(await session.run(gateway: serverGateway));
        } on Object catch (error, stackTrace) {
          serverResult.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
      ],
      identity: clientIdentity,
      peer: _device(serverIdentity, PairedDevicePlatform.windows),
      sharedSecret: secret,
    );

    final clientSummary = await session.run(gateway: clientGateway, operation: PairedSyncOperation.push);
    final hostSummary = await serverResult.future;

    expect(clientSummary.receivedBooks, 0);
    expect(clientSummary.sentBooks, 1);
    expect(hostSummary.receivedBooks, 1);
    expect(hostSummary.sentBooks, 0);
    expect(clientGateway.appliedIds, isEmpty);
    expect(serverGateway.appliedIds, <String>['phone-book']);
  });

  test('peer manifest failure is returned in the HTTP negotiation response', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 27);
    const phoneIdentity = LocalDeviceIdentity(deviceId: 'phone_manifest_1234567', label: '手机');
    const desktopIdentity = LocalDeviceIdentity(deviceId: 'desktop_manifest_12345', label: '开发电脑');
    final phoneFailure = Completer<Object>();
    final host = await PairedSyncHost.start(
      identity: phoneIdentity,
      devices: _MemoryPairedDeviceRepository(_device(desktopIdentity, PairedDevicePlatform.windows)),
      identityStore: _MemoryIdentityStore(phoneIdentity, <String, List<int>>{desktopIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          await session.run(gateway: const _FailingManifestGateway());
        } on Object catch (error) {
          if (!phoneFailure.isCompleted) phoneFailure.complete(error);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: phoneIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: phoneIdentity.label,
          port: host.port,
        ),
      ],
      identity: desktopIdentity,
      peer: _device(phoneIdentity, PairedDevicePlatform.android),
      sharedSecret: secret,
    );

    await expectLater(
      session.run(gateway: _ShelfGateway('desktop-book')),
      throwsA(
        isA<PairedSyncPeerFailureException>()
            .having((error) => error.code, 'code', 'lan_sync_local_manifest_runtime_unavailable')
            .having((error) => error.stage, 'stage', 'local_manifest')
            .having((error) => error.errorText, 'errorText', contains('runtime_unavailable')),
      ),
    );
    expect(await phoneFailure.future, isA<LanSyncGatewayException>());
  });

  test('peer manifest rejection returns the safe invalid field reason', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 28);
    const phoneIdentity = LocalDeviceIdentity(deviceId: 'phone_invalid_manifest_1', label: '手机');
    const desktopIdentity = LocalDeviceIdentity(deviceId: 'desktop_invalid_manifest', label: '开发电脑');
    final phoneFailure = Completer<Object>();
    final host = await PairedSyncHost.start(
      identity: phoneIdentity,
      devices: _MemoryPairedDeviceRepository(_device(desktopIdentity, PairedDevicePlatform.windows)),
      identityStore: _MemoryIdentityStore(phoneIdentity, <String, List<int>>{desktopIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          await session.run(gateway: _ShelfGateway('phone-book'));
        } on Object catch (error) {
          if (!phoneFailure.isCompleted) phoneFailure.complete(error);
        }
      },
    );
    addTearDown(host.close);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: addresses.first,
          deviceId: phoneIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: phoneIdentity.label,
          port: host.port,
        ),
      ],
      identity: desktopIdentity,
      peer: _device(phoneIdentity, PairedDevicePlatform.android),
      sharedSecret: secret,
    );

    await expectLater(
      session.run(gateway: _InvalidShelfGateway()),
      throwsA(
        isA<PairedSyncPeerFailureException>()
            .having((error) => error.code, 'code', 'lan_sync_manifest_invalid')
            .having((error) => error.stage, 'stage', 'manifest_exchange')
            .having((error) => error.errorText, 'errorText', contains('invalid_content_kind')),
      ),
    );
    expect(
      await phoneFailure.future,
      isA<LanSyncTransportException>()
          .having((error) => error.code, 'code', 'lan_sync_manifest_invalid')
          .having((error) => error.reason, 'reason', 'invalid_content_kind'),
    );
  });

  test('announcement policy suppresses mobile UDP until Wi-Fi is available', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 29);
    const desktopIdentity = LocalDeviceIdentity(deviceId: 'desktop_announce_1234', label: '开发电脑');
    const phoneIdentity = LocalDeviceIdentity(deviceId: 'phone_announce_123456', label: '手机');
    final desktopHost = await PairedSyncHost.start(
      identity: desktopIdentity,
      devices: _MemoryPairedDeviceRepository(_device(phoneIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(desktopIdentity, <String, List<int>>{phoneIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      discoveryPort: 0,
    );
    addTearDown(desktopHost.close);
    var wifiAvailable = false;
    final phoneHost = await PairedSyncHost.start(
      identity: phoneIdentity,
      devices: _MemoryPairedDeviceRepository(_device(desktopIdentity, PairedDevicePlatform.windows)),
      identityStore: _MemoryIdentityStore(phoneIdentity, <String, List<int>>{desktopIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      discoveryPort: desktopHost.discoveryPort,
      announcementInterval: const Duration(milliseconds: 30),
      advertisedPeerLifetime: const Duration(seconds: 20),
      canAnnounce: () async => wifiAvailable,
    );
    addTearDown(phoneHost.close);
    final received = <PairedSyncEndpoint>[];
    final subscription = desktopHost.endpoints.listen(received.add);
    addTearDown(subscription.cancel);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(received.where((endpoint) => endpoint.deviceId == phoneIdentity.deviceId), isEmpty);

    wifiAvailable = true;
    final endpoint = await desktopHost.endpoints
        .firstWhere((candidate) => candidate.deviceId == phoneIdentity.deviceId)
        .timeout(const Duration(seconds: 3));

    expect(endpoint.expiresAtUtc.difference(DateTime.now().toUtc()), greaterThan(const Duration(seconds: 15)));
  });

  test('authenticated wake request asks a Windows peer to reverse-connect once', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 31);
    const serverIdentity = LocalDeviceIdentity(deviceId: 'desktop_wake_12345678', label: '开发电脑');
    const clientIdentity = LocalDeviceIdentity(deviceId: 'phone_wake_1234567890', label: '手机');
    final wake = Completer<PairedSyncWakeRequest>();
    var callbackCount = 0;
    final host = await PairedSyncHost.start(
      identity: serverIdentity,
      devices: _MemoryPairedDeviceRepository(_device(clientIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(serverIdentity, <String, List<int>>{clientIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      onWakeRequest: (request) async {
        callbackCount++;
        if (!wake.isCompleted) wake.complete(request);
      },
      discoveryPort: 0,
    );
    addTearDown(host.close);
    final requestId = createPairedSyncWakeRequestId();

    for (final address in addresses) {
      await sendPairedSyncWakeRequest(
        identity: clientIdentity,
        endpoint: PairedSyncEndpoint(
          address: address,
          deviceId: serverIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: serverIdentity.label,
          port: host.port,
        ),
        sharedSecret: secret,
        operation: PairedSyncOperation.pull,
        localPort: 54321,
        requestId: requestId,
        discoveryPort: host.discoveryPort,
      );
    }
    final request = await wake.future.timeout(const Duration(seconds: 3));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(request.requestId, requestId);
    expect(request.operation, PairedSyncOperation.pull);
    expect(request.operation.reversed, PairedSyncOperation.push);
    expect(request.endpoint.deviceId, clientIdentity.deviceId);
    expect(request.endpoint.port, 54321);
    expect(callbackCount, 1);
  });

  test('authenticated reverse failure reports the remote stage and stable code', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 37);
    const phoneIdentity = LocalDeviceIdentity(deviceId: 'phone_failure_12345678', label: '手机');
    const desktopIdentity = LocalDeviceIdentity(deviceId: 'desktop_failure_123456', label: '开发电脑');
    final received = Completer<PairedSyncWakeFailure>();
    final host = await PairedSyncHost.start(
      identity: phoneIdentity,
      devices: _MemoryPairedDeviceRepository(_device(desktopIdentity, PairedDevicePlatform.windows)),
      identityStore: _MemoryIdentityStore(phoneIdentity, <String, List<int>>{desktopIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      onWakeFailure: (failure) async {
        if (!received.isCompleted) received.complete(failure);
      },
      discoveryPort: 0,
    );
    addTearDown(host.close);
    final requestId = createPairedSyncWakeRequestId();

    for (final address in addresses) {
      await sendPairedSyncWakeFailure(
        identity: desktopIdentity,
        endpoint: PairedSyncEndpoint(
          address: address,
          deviceId: phoneIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: phoneIdentity.label,
          port: 54321,
        ),
        sharedSecret: secret,
        requestId: requestId,
        code: 'lan_sync_connect_failed',
        stage: 'connect',
        errorText: 'SocketException: Connection refused',
        discoveryPort: host.discoveryPort,
      );
    }
    final failure = await received.future.timeout(const Duration(seconds: 3));

    expect(failure.deviceId, desktopIdentity.deviceId);
    expect(failure.requestId, requestId);
    expect(failure.code, 'lan_sync_connect_failed');
    expect(failure.stage, 'connect');
    expect(failure.errorText, 'SocketException: Connection refused');
  });

  test('phone pull wake completes through a Windows outbound reverse connection', () async {
    final addresses = await eligibleLanSyncAddresses();
    if (addresses.isEmpty) return;
    final secret = List<int>.generate(32, (index) => index + 41);
    const desktopIdentity = LocalDeviceIdentity(deviceId: 'desktop_reverse_123456', label: '开发电脑');
    const phoneIdentity = LocalDeviceIdentity(deviceId: 'phone_reverse_12345678', label: '手机');
    final desktopGateway = _ShelfGateway('desktop-book');
    final phoneGateway = _ShelfGateway('phone-book');
    final phoneResult = Completer<PairedSyncRunSummary>();
    final desktopResult = Completer<PairedSyncRunSummary>();
    String? incomingRequestId;
    final phoneHost = await PairedSyncHost.start(
      identity: phoneIdentity,
      devices: _MemoryPairedDeviceRepository(_device(desktopIdentity, PairedDevicePlatform.windows)),
      identityStore: _MemoryIdentityStore(phoneIdentity, <String, List<int>>{desktopIdentity.deviceId: secret}),
      onIncoming: (session) async {
        try {
          phoneResult.complete(await session.run(gateway: phoneGateway));
          incomingRequestId = session.requestId;
        } on Object catch (error, stackTrace) {
          phoneResult.completeError(error, stackTrace);
        }
      },
      discoveryPort: 0,
    );
    addTearDown(phoneHost.close);
    final desktopHost = await PairedSyncHost.start(
      identity: desktopIdentity,
      devices: _MemoryPairedDeviceRepository(_device(phoneIdentity, PairedDevicePlatform.android)),
      identityStore: _MemoryIdentityStore(desktopIdentity, <String, List<int>>{phoneIdentity.deviceId: secret}),
      onIncoming: (session) => session.close(),
      onWakeRequest: (request) async {
        try {
          final session = await PairedSyncClientSession.connectAny(
            endpoints: <PairedSyncEndpoint>[request.endpoint],
            identity: desktopIdentity,
            peer: _device(phoneIdentity, PairedDevicePlatform.android),
            sharedSecret: secret,
          );
          desktopResult.complete(
            await session.run(gateway: desktopGateway, operation: request.operation.reversed, requestId: request.requestId),
          );
        } on Object catch (error, stackTrace) {
          desktopResult.completeError(error, stackTrace);
        }
      },
      discoveryPort: 0,
    );
    addTearDown(desktopHost.close);
    final requestId = createPairedSyncWakeRequestId();

    for (final address in addresses) {
      await sendPairedSyncWakeRequest(
        identity: phoneIdentity,
        endpoint: PairedSyncEndpoint(
          address: address,
          deviceId: desktopIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
          label: desktopIdentity.label,
          port: desktopHost.port,
        ),
        sharedSecret: secret,
        operation: PairedSyncOperation.pull,
        localPort: phoneHost.port,
        requestId: requestId,
        discoveryPort: desktopHost.discoveryPort,
      );
    }
    final phoneSummary = await phoneResult.future.timeout(const Duration(seconds: 5));
    final desktopSummary = await desktopResult.future.timeout(const Duration(seconds: 5));

    expect(incomingRequestId, requestId);
    expect(phoneSummary.receivedBooks, 1);
    expect(phoneSummary.sentBooks, 0);
    expect(desktopSummary.receivedBooks, 0);
    expect(desktopSummary.sentBooks, 1);
    expect(phoneGateway.appliedIds, <String>['desktop-book']);
    expect(desktopGateway.appliedIds, isEmpty);
  });
}

PairedDevice _device(LocalDeviceIdentity identity, PairedDevicePlatform platform, {String? label}) => PairedDevice(
  autoSync: true,
  createdAtUtc: DateTime.utc(2026, 8, 31),
  deviceId: identity.deviceId,
  label: label ?? identity.label,
  mode: PairedSyncMode.bidirectional,
  platform: platform,
  syncBookshelf: true,
  syncPlugins: true,
);

final class _MemoryPairedDeviceRepository implements PairedDeviceRepository {
  _MemoryPairedDeviceRepository(PairedDevice device) : _devices = <String, PairedDevice>{device.deviceId: device};

  final Map<String, PairedDevice> _devices;

  @override
  Future<List<PairedDevice>> list() async => _devices.values.toList(growable: false);

  @override
  Future<PairedDevice?> read(String deviceId) async => _devices[deviceId];

  @override
  Future<void> remove(String deviceId) async {
    _devices.remove(deviceId);
  }

  @override
  Future<void> upsert(PairedDevice device) async {
    _devices[device.deviceId] = device;
  }
}

final class _FailingManifestGateway implements LanSyncGateway {
  const _FailingManifestGateway();

  @override
  Future<LanSyncManifest> createManifest() => throw const LanSyncGatewayException('runtime_unavailable');

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async => throw UnimplementedError();

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => throw UnimplementedError();

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async => throw UnimplementedError();

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => throw UnimplementedError();

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async =>
      throw UnimplementedError();

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => throw UnimplementedError();
}

final class _MemoryIdentityStore implements DeviceIdentityStore {
  _MemoryIdentityStore(this.identity, this.secrets);

  final LocalDeviceIdentity identity;
  final Map<String, List<int>> secrets;

  @override
  Future<void> deletePeerSecret(String peerDeviceId) async {
    secrets.remove(peerDeviceId);
  }

  @override
  Future<LocalDeviceIdentity> loadOrCreateIdentity() async => identity;

  @override
  Future<List<int>?> readPeerSecret(String peerDeviceId) async => secrets[peerDeviceId];

  @override
  Future<void> writePeerSecret(String peerDeviceId, List<int> secret) async {
    secrets[peerDeviceId] = secret;
  }
}

class _ShelfGateway implements LanSyncGateway {
  _ShelfGateway(this.localId);

  final String localId;
  final List<String> appliedIds = <String>[];

  @override
  Future<LanSyncManifest> createManifest() async => LanSyncManifest(
    plugins: const <LanSyncPluginDescriptor>[],
    shelfItems: <LanSyncShelfItem>[
      LanSyncShelfItem(
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: localId,
        contentKind: 'novel',
        title: localId,
      ),
    ],
    skippedShelfItems: 0,
  );

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async => LanSyncImportPreview(
    newItemCount: manifest.shelfItems.length,
    conflicts: const <LanSyncBookConflict>[],
    blockedItemCount: 0,
    pluginPlans: const <String, LanSyncPluginPlanState>{},
    selectedShelfItemIds: <String>{for (final item in manifest.shelfItems) item.identity},
  );

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {}

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {}

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async => const LanSyncPluginImportResult.empty();

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async {
    appliedIds.addAll(manifest.shelfItems.map((item) => item.remoteContentId));
    return LanSyncApplyResult(
      added: manifest.shelfItems.length,
      updated: 0,
      keptLocal: 0,
      blocked: 0,
      pluginInstalled: pluginResult.installed,
      pluginSkipped: pluginResult.skipped,
      pluginFailed: pluginResult.failed,
    );
  }

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => const Stream<List<int>>.empty();
}

final class _InvalidShelfGateway extends _ShelfGateway {
  _InvalidShelfGateway() : super('invalid-audio');

  @override
  Future<LanSyncManifest> createManifest() async => const LanSyncManifest(
    plugins: <LanSyncPluginDescriptor>[],
    shelfItems: <LanSyncShelfItem>[
      LanSyncShelfItem(
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: 'invalid-audio',
        contentKind: 'audio',
        title: '不可传输的音频条目',
      ),
    ],
    skippedShelfItems: 0,
  );
}

final class _PluginGateway implements LanSyncGateway, LanSyncPairedGateway {
  _PluginGateway({
    required this.offeredIds,
    required this.requestedId,
    Set<String>? requestedIds,
    this.rejectImport = false,
    this.reportFailure = false,
    this.taskDelay = Duration.zero,
  }) : requestedIds = requestedIds ?? <String>{?requestedId};

  bool rejectImport;
  bool reportFailure;

  final List<String> offeredIds;
  final String? requestedId;
  final Set<String> requestedIds;
  final Duration taskDelay;
  final List<String> materializedIds = <String>[];
  final List<String> importedIds = <String>[];
  int activeMaterializationTasks = 0;
  int maximumMaterializationTasks = 0;
  int activeImportTasks = 0;
  int maximumImportTasks = 0;

  @override
  Future<LanSyncManifest> createManifest() => createPairedManifest();

  @override
  Future<LanSyncManifest> createPairedManifest({
    bool includePlugins = true,
    bool includeShelf = true,
    bool deferPluginArtifacts = false,
  }) async {
    if (includePlugins) expect(deferPluginArtifacts, isTrue);
    return LanSyncManifest(
      plugins: includePlugins ? <LanSyncPluginDescriptor>[for (final id in offeredIds) _offer(id)] : const <LanSyncPluginDescriptor>[],
      shelfItems: const <LanSyncShelfItem>[],
      skippedShelfItems: 0,
    );
  }

  @override
  Future<LanSyncMaterializedPlugin> materializePluginArchive(LanSyncPluginDescriptor plugin) async {
    activeMaterializationTasks++;
    maximumMaterializationTasks = maximumMaterializationTasks < activeMaterializationTasks
        ? activeMaterializationTasks
        : maximumMaterializationTasks;
    try {
      if (taskDelay > Duration.zero) await Future<void>.delayed(taskDelay);
      materializedIds.add(plugin.id);
      final descriptor = LanSyncPluginDescriptor(
        id: plugin.id,
        version: plugin.version,
        bytes: 3,
        artifactFormat: plugin.artifactFormat,
        developmentFingerprint: plugin.developmentFingerprint,
        developmentRevision: plugin.developmentRevision,
        sha256: sha256.convert(const <int>[1, 2, 3]).toString(),
        transferable: true,
        provenance: plugin.provenance,
      );
      return LanSyncMaterializedPlugin(descriptor: descriptor, bytes: Stream<List<int>>.value(const <int>[1, 2, 3]));
    } finally {
      activeMaterializationTasks--;
    }
  }

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) async {
    return LanSyncImportPreview(
      newItemCount: 0,
      conflicts: const <LanSyncBookConflict>[],
      blockedItemCount: 0,
      pluginPlans: <String, LanSyncPluginPlanState>{
        for (final plugin in manifest.plugins)
          plugin.id: requestedIds.contains(plugin.id) ? LanSyncPluginPlanState.missing : LanSyncPluginPlanState.sameVersion,
      },
    );
  }

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {
    expect(plugins.every((plugin) => !plugin.deferred && plugin.bytes == 3), isTrue);
  }

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) async {
    activeImportTasks++;
    maximumImportTasks = maximumImportTasks < activeImportTasks ? activeImportTasks : maximumImportTasks;
    try {
      if (rejectImport) throw const LanSyncGatewayException('plugin_import_rejected');
      final received = <int>[];
      await for (final chunk in bytes) {
        received.addAll(chunk);
      }
      if (taskDelay > Duration.zero) await Future<void>.delayed(taskDelay);
      expect(received, const <int>[1, 2, 3]);
      importedIds.add(plugin.id);
    } finally {
      activeImportTasks--;
    }
  }

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() async {
    return LanSyncPluginImportResult(
      availablePluginIds: importedIds.toSet(),
      installed: reportFailure ? 0 : importedIds.length,
      skipped: 0,
      failed: reportFailure ? 1 : 0,
      failureCode: reportFailure ? 'plugin_import_rejected' : null,
    );
  }

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) async => LanSyncApplyResult(
    added: 0,
    updated: 0,
    keptLocal: 0,
    blocked: 0,
    pluginInstalled: pluginResult.installed,
    pluginSkipped: pluginResult.skipped,
    pluginFailed: pluginResult.failed,
  );

  @override
  Future<void> cancelPluginImports() async {
    if (rejectImport || reportFailure) throw StateError('cleanup_failed');
  }

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) =>
      throw StateError('paired_sync_must_materialize_selected_offer');
}

LanSyncPluginDescriptor _offer(String id) => LanSyncPluginDescriptor(
  id: id,
  version: '1.0.0-dev.7.aaaaaaaaaaaa',
  bytes: 0,
  artifactFormat: LanSyncPluginArtifactFormat.archive,
  developmentFingerprint: ''.padLeft(64, 'b'),
  developmentRevision: 7,
  sha256: ''.padLeft(64, '0'),
  transferable: true,
  deferred: true,
  provenance: LanSyncPluginProvenance.development,
);
