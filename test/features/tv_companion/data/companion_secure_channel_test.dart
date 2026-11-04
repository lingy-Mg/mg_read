import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/tv_companion/data/companion_secure_channel.dart';
import 'package:mg_read/features/tv_companion/data/companion_secure_handshake.dart';

void main() {
  const psk = <int>[
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
  final servers = <HttpServer>[];
  final channels = <CompanionSecureChannel>[];
  final rawSockets = <WebSocket>[];

  tearDown(() async {
    for (final channel in channels) {
      await channel.close();
    }
    channels.clear();
    for (final socket in rawSockets) {
      try {
        await socket.close();
      } catch (_) {}
    }
    rawSockets.clear();
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
  });

  Future<({CompanionSecureChannel client, Future<CompanionSecureChannel> server})> pair({
    List<int> clientSecret = psk,
    List<int>? serverSecret = psk,
    String serverId = 'tv-1',
    FutureOr<void> Function(CompanionSecureChannel)? onServerReady,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    final serverReady = Completer<CompanionSecureChannel>();
    unawaited(
      server.first.then((request) async {
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          final channel = await CompanionSecureChannel.accept(
            socket: socket,
            localDeviceId: serverId,
            resolvePeerSecret: (peer) async => peer == 'phone-1' ? serverSecret : null,
          );
          channels.add(channel);
          serverReady.complete(channel);
          await onServerReady?.call(channel);
        } catch (error) {
          // A failed handshake is expected in negative tests; the client sees
          // the bounded public error, while this test server simply closes it.
        }
      }),
    );
    final client = await CompanionSecureChannel.connect(
      uri: Uri(scheme: 'ws', host: '127.0.0.1', port: server.port, path: '/companion'),
      localDeviceId: 'phone-1',
      remoteDeviceId: 'tv-1',
      sharedSecret: clientSecret,
      allowLoopbackForTesting: true,
    );
    channels.add(client);
    return (client: client, server: serverReady.future);
  }

  Future<({CompanionSecureChannel client, WebSocket peer, CompanionHandshakeKeys keys})> rawPair() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    final peerReady = Completer<({WebSocket socket, CompanionHandshakeKeys keys})>();
    unawaited(
      server.first.then((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        rawSockets.add(socket);
        try {
          final incoming = StreamIterator<dynamic>(socket);
          final result = await CompanionSecureHandshake.server(
            localId: 'tv-1',
            resolvePeerSecret: (peerId) async => peerId == 'phone-1' ? psk : null,
            send: (message) => socket.add(utf8.decode(CompanionSecureHandshake.encodeMessage(message))),
            receive: () async {
              if (!await incoming.moveNext()) throw const CompanionSecureChannelException();
              return incoming.current;
            },
            timeout: const Duration(seconds: 5),
          );
          peerReady.complete((socket: socket, keys: result.keys));
        } catch (error, stack) {
          peerReady.completeError(error, stack);
        }
      }),
    );
    final client = await CompanionSecureChannel.connect(
      uri: Uri(scheme: 'ws', host: '127.0.0.1', port: server.port),
      localDeviceId: 'phone-1',
      remoteDeviceId: 'tv-1',
      sharedSecret: psk,
      allowLoopbackForTesting: true,
    );
    channels.add(client);
    final peer = await peerReady.future;
    return (client: client, peer: peer.socket, keys: peer.keys);
  }

  Future<List<int>> encryptedServerFrame(CompanionHandshakeKeys keys, Map<String, Object?> message, {int sequence = 0}) async {
    final sequenceBytes = List<int>.generate(8, (index) => (sequence >> ((7 - index) * 8)) & 255);
    final prefix = keys.serverNoncePrefix;
    final header = <int>[1, ...sequenceBytes, ...prefix, ...sequenceBytes];
    final nonce = <int>[...prefix, ...sequenceBytes];
    final aad = <int>[...utf8.encode('mgread-companion-frame-v1\u0000server-to-client\u0000'), ...header];
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(message)),
      secretKey: keys.serverToClientKey,
      nonce: nonce,
      aad: aad,
    );
    return <int>[...header, ...box.cipherText, ...box.mac.bytes];
  }

  test('authenticates real loopback sockets and buffers early bidirectional messages', () async {
    final connected = await pair(
      onServerReady: (channel) {
        return channel.send({'from': 'tv', 'text': 'early'});
      },
    );
    final serverChannel = await connected.server;
    expect(connected.client.peerDeviceId, 'tv-1');
    expect(serverChannel.peerDeviceId, 'phone-1');
    expect(connected.client.sessionId, isNotEmpty);
    expect(await connected.client.messages.first.timeout(const Duration(seconds: 2)), {'from': 'tv', 'text': 'early'});
    await connected.client.send({'from': 'phone', 'text': 'secret business payload'});
    expect(await serverChannel.messages.first.timeout(const Duration(seconds: 2)), {'from': 'phone', 'text': 'secret business payload'});
  });

  test('serializes concurrent sends into strictly ordered authenticated frames', () async {
    final connected = await pair();
    final serverChannel = await connected.server;
    final receive = serverChannel.messages.take(20).toList();
    await Future.wait(List<Future<void>>.generate(20, (index) => connected.client.send({'index': index})));
    final messages = await receive.timeout(const Duration(seconds: 3));
    expect(messages.map((message) => message['index']).toList(), List<int>.generate(20, (i) => i));
  });

  test('rejects a wrong PSK and does not expose handshake details', () async {
    final wrong = List<int>.filled(32, 0xA5);
    await expectLater(pair(clientSecret: wrong), throwsA(isA<CompanionSecureChannelException>()));
  });

  test('rejects a wrong remote identity before sending business data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    unawaited(
      server.first.then((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        try {
          await CompanionSecureChannel.accept(socket: socket, localDeviceId: 'different-tv', resolvePeerSecret: (_) async => psk);
        } catch (_) {}
      }),
    );
    await expectLater(
      CompanionSecureChannel.connect(
        uri: Uri(scheme: 'ws', host: '127.0.0.1', port: server.port),
        localDeviceId: 'phone-1',
        remoteDeviceId: 'tv-1',
        sharedSecret: psk,
        allowLoopbackForTesting: true,
      ),
      throwsA(isA<CompanionSecureChannelException>()),
    );
  });

  test('rejects tampered authenticated bytes and replayed sequence numbers', () async {
    final tamperPair = await rawPair();
    final tamperError = Completer<Object>();
    tamperPair.client.messages.listen((_) {}, onError: tamperError.complete);
    final tampered = await encryptedServerFrame(tamperPair.keys, {'ok': true});
    tampered[tampered.length - 1] ^= 1;
    tamperPair.peer.add(tampered);
    expect(await tamperError.future.timeout(const Duration(seconds: 2)), isA<CompanionSecureChannelException>());

    final replayPair = await rawPair();
    final firstMessage = Completer<CompanionJson>();
    final replayError = Completer<Object>();
    replayPair.client.messages.listen(firstMessage.complete, onError: replayError.complete);
    final frame = await encryptedServerFrame(replayPair.keys, {'sequence': 0});
    replayPair.peer.add(frame);
    expect(await firstMessage.future.timeout(const Duration(seconds: 2)), {'sequence': 0});
    replayPair.peer.add(frame);
    expect(await replayError.future.timeout(const Duration(seconds: 2)), isA<CompanionSecureChannelException>());
  });

  test('bounds authenticated messages received before a consumer subscribes', () async {
    final connected = await rawPair();
    final errors = Completer<Object>();
    final frames = await Future.wait(
      List<Future<List<int>>>.generate(33, (sequence) => encryptedServerFrame(connected.keys, {'index': sequence}, sequence: sequence)),
    );
    for (final frame in frames) {
      connected.peer.add(frame);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    connected.client.messages.listen((_) {}, onError: errors.complete);
    expect(await errors.future.timeout(const Duration(seconds: 2)), isA<CompanionSecureChannelException>());
  });

  test('does not accept an authenticated frame replayed from an earlier connection', () async {
    final oldConnection = await rawPair();
    final capturedFrame = await encryptedServerFrame(oldConnection.keys, {'from': 'old-session'});
    final oldReceived = Completer<CompanionJson>();
    oldConnection.client.messages.listen(oldReceived.complete);
    oldConnection.peer.add(capturedFrame);
    expect(await oldReceived.future.timeout(const Duration(seconds: 2)), {'from': 'old-session'});

    final newConnection = await rawPair();
    final replayError = Completer<Object>();
    newConnection.client.messages.listen((_) {}, onError: replayError.complete);
    newConnection.peer.add(capturedFrame);
    expect(await replayError.future.timeout(const Duration(seconds: 2)), isA<CompanionSecureChannelException>());
  });

  test('bounds oversized pre-authentication WebSocket backlog', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    final accepted = Completer<void>();
    unawaited(
      server.first.then((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        rawSockets.add(socket);
        try {
          await CompanionSecureChannel.accept(
            socket: socket,
            localDeviceId: 'tv-1',
            resolvePeerSecret: (peer) async {
              // Hold the handshake after the initial hello while the client
              // floods frames; the inbox must fail closed at its small cap.
              await Future<void>.delayed(const Duration(milliseconds: 300));
              return peer == 'phone-1' ? psk : null;
            },
          );
        } catch (_) {
          accepted.complete();
        }
      }),
    );
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/companion');
    rawSockets.add(socket);
    socket.add(
      jsonEncode({
        'type': 'hello',
        'version': 1,
        'clientId': 'phone-1',
        'serverId': 'tv-1',
        'session': base64Url.encode(List<int>.filled(16, 1)).replaceAll('=', ''),
        'clientNonce': base64Url.encode(List<int>.filled(32, 2)).replaceAll('=', ''),
      }),
    );
    final oversized = 'x' * (32 * 1024);
    for (var i = 0; i < 9; i++) {
      socket.add(oversized);
    }
    await accepted.future.timeout(const Duration(seconds: 3));
  });

  test('enforces direct private IPv4 endpoints and plaintext size limit', () async {
    await expectLater(
      CompanionSecureChannel.connect(
        uri: Uri(scheme: 'ws', host: 'example.com', port: 9999),
        localDeviceId: 'phone-1',
        remoteDeviceId: 'tv-1',
        sharedSecret: psk,
      ),
      throwsA(isA<CompanionSecureChannelException>()),
    );
    final connected = await pair();
    await expectLater(connected.client.send({'text': 'x' * (65 * 1024)}), throwsA(isA<CompanionSecureChannelException>()));
  });
}
