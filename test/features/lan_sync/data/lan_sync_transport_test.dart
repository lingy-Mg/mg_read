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
          address: InternetAddress.loopbackIPv4.address,
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
