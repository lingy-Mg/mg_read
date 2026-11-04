import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/data/companion_secure_channel.dart';

void main() {
  HttpServer? server;
  CompanionSecureChannel? clientChannel;
  CompanionSecureChannel? serverChannel;

  tearDown(() async {
    await clientChannel?.close();
    await serverChannel?.close();
    await server?.close(force: true);
  });

  test('uses ephemeral X25519 and encrypted frames without a PSK or resolver trust', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<CompanionSecureChannel>();
    server!.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      try {
        serverChannel = await CompanionSecureChannel.accept(
          socket: socket,
          localDeviceId: 'tv-lan-1',
          resolvePeerSecret: (_) async => null,
          allowLanSession: true,
        );
        accepted.complete(serverChannel!);
      } catch (error, stack) {
        accepted.completeError(error, stack);
      }
    });

    clientChannel = await CompanionSecureChannel.connect(
      uri: Uri(scheme: 'ws', host: '127.0.0.1', port: server!.port, path: '/companion/v1/ws'),
      localDeviceId: 'phone-lan-1',
      remoteDeviceId: 'tv-lan-1',
      sharedSecret: const <int>[],
      allowLoopbackForTesting: true,
    );
    serverChannel = await accepted.future.timeout(const Duration(seconds: 3));

    expect(clientChannel!.isLanSession, isTrue);
    expect(serverChannel!.isLanSession, isTrue);
    final incoming = serverChannel!.messages.first;
    await clientChannel!.send({'kind': 'command', 'payload': 'encrypted'});
    expect(await incoming.timeout(const Duration(seconds: 2)), {'kind': 'command', 'payload': 'encrypted'});
  });
}
