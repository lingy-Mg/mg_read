import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test(
    'sender and receiver confirm the same code before manifest transfer',
    () async {
      final sender = await LanSyncSenderService.start(
        manifest: const LanSyncManifest(
          plugins: <LanSyncPluginDescriptor>[],
          shelfItems: <LanSyncShelfItem>[],
          skippedShelfItems: 0,
        ),
        openPlugin: (_) async => const Stream<List<int>>.empty(),
      );
      addTearDown(sender.close);
      final pairingEvent = sender.events
          .where((event) => event is LanSyncSenderPairing)
          .cast<LanSyncSenderPairing>()
          .first;
      final doneEvent = sender.events
          .where((event) => event is LanSyncSenderDone)
          .cast<LanSyncSenderDone>()
          .first;
      final receiver = await LanSyncReceiverConnection.connect(
        LanSyncPeer(
          sessionId: sender.sessionId,
          label: 'test sender',
          address: sender.addresses.first,
          port: sender.port,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
        ),
      );
      addTearDown(receiver.close);

      expect((await pairingEvent).code, receiver.pairingCode);
      sender.confirmPairing();
      final manifest = await receiver.confirmAndReadManifest();
      expect(manifest.plugins, isEmpty);
      expect(manifest.shelfItems, isEmpty);

      await receiver.receivePlugins(
        pluginIds: const <String>{},
        importPlugin: (_, _) async => fail('No plugin should be transferred.'),
      );
      await doneEvent;
    },
  );

  test('receiver rejects public and malformed IPv4 endpoints', () async {
    Future<void> connect(String address) => LanSyncReceiverConnection.connect(
      LanSyncPeer(
        sessionId: 'test-session',
        label: 'untrusted',
        address: address,
        port: 12345,
        expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    ).then((connection) => connection.close());

    await expectLater(
      connect('8.8.8.8'),
      throwsA(
        isA<LanSyncTransportException>().having(
          (error) => error.code,
          'code',
          'lan_sync_address_not_private',
        ),
      ),
    );
    await expectLater(
      connect('10.999.0.1'),
      throwsA(isA<LanSyncTransportException>()),
    );
  });

  test('candidate selection excludes virtual and non-LAN endpoints', () {
    final addresses = selectLanSyncCandidateAddresses(const <
      LanSyncNetworkAddress
    >[
      LanSyncNetworkAddress(interfaceName: 'Wi-Fi', address: '192.168.1.8'),
      LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '10.0.0.8'),
      LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '172.16.0.8'),
      LanSyncNetworkAddress(
        interfaceName: 'vEthernet (WSL (Hyper-V firewall))',
        address: '172.20.160.1',
      ),
      LanSyncNetworkAddress(interfaceName: 'DockerNAT', address: '10.10.0.1'),
      LanSyncNetworkAddress(
        interfaceName: 'VMware Network Adapter VMnet8',
        address: '192.168.200.1',
      ),
      LanSyncNetworkAddress(interfaceName: 'Tailscale', address: '100.64.0.2'),
      LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '169.254.1.2'),
      LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '127.0.0.1'),
      LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '8.8.8.8'),
    ]);

    expect(addresses, <String>['192.168.1.8', '10.0.0.8', '172.16.0.8']);
  });

  test('receiver concurrently chooses the reachable candidate', () async {
    final sender = await LanSyncSenderService.start(
      manifest: const LanSyncManifest(
        plugins: <LanSyncPluginDescriptor>[],
        shelfItems: <LanSyncShelfItem>[],
        skippedShelfItems: 0,
      ),
      openPlugin: (_) async => const Stream<List<int>>.empty(),
    );
    addTearDown(sender.close);

    final receiver = await LanSyncReceiverConnection.connectAny(<LanSyncPeer>[
      LanSyncPeer(
        sessionId: sender.sessionId,
        label: 'unreachable candidate',
        address: '10.255.255.1',
        port: sender.port,
        expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
      LanSyncPeer(
        sessionId: sender.sessionId,
        label: 'reachable candidate',
        address: sender.addresses.first,
        port: sender.port,
        expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    ]).timeout(const Duration(seconds: 3));
    addTearDown(receiver.close);

    expect(receiver.peer.address, sender.addresses.first);
    sender.confirmPairing();
    await receiver.confirmAndReadManifest();
    await receiver.receivePlugins(
      pluginIds: const <String>{},
      importPlugin: (_, _) async => fail('No plugin should be transferred.'),
    );
  });

  test('closing a receiver before confirmation is handled', () async {
    final sender = await LanSyncSenderService.start(
      manifest: const LanSyncManifest(
        plugins: <LanSyncPluginDescriptor>[],
        shelfItems: <LanSyncShelfItem>[],
        skippedShelfItems: 0,
      ),
      openPlugin: (_) async => const Stream<List<int>>.empty(),
    );
    addTearDown(sender.close);
    final receiver = await LanSyncReceiverConnection.connect(
      LanSyncPeer(
        sessionId: sender.sessionId,
        label: 'receiver that cancels pairing',
        address: sender.addresses.first,
        port: sender.port,
        expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    );

    await receiver.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('framing accepts a manifest-sized control frame', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final serverResult = server.first.then((socket) async {
      final connection = LanSyncFramedConnection(socket);
      final value = await connection.readControl(
        maxBytes: lanSyncMaxManifestBytes,
      );
      await connection.sendControl(<String, Object?>{'type': 'ack'});
      await connection.close();
      return value;
    });
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final client = LanSyncFramedConnection(socket);
    final payload = List<String>.filled(300 * 1024, 'x').join();

    await client.sendControl(<String, Object?>{
      'type': 'manifest',
      'payload': payload,
    }, maxBytes: lanSyncMaxManifestBytes);
    expect((await client.readControl())['type'], 'ack');
    expect((await serverResult)['payload'], payload);
    await client.close();
  });

  test('framing rejects a control frame above its declared limit', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = server.first;
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final peer = await accepted;
    final client = LanSyncFramedConnection(socket);
    addTearDown(client.close);
    addTearDown(peer.destroy);

    expect(
      () => client.sendControl(<String, Object?>{
        'payload': List<String>.filled(lanSyncMaxControlFrameBytes, 'x').join(),
      }),
      throwsA(
        isA<LanSyncTransportException>().having(
          (error) => error.code,
          'code',
          'lan_sync_control_too_large',
        ),
      ),
    );
  });
}
