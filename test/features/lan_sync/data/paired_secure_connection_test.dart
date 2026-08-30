import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/paired_secure_connection.dart';

void main() {
  test('paired connection authenticates control and binary frames in both directions', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final serverDone = Completer<void>();
    server.listen((socket) async {
      final connection = await PairedSecureConnection.server(
        raw: LanSyncFramedConnection(socket),
        sharedSecret: List<int>.filled(32, 7),
        clientNonce: 'client_nonce_1234567890',
        serverNonce: 'server_nonce_1234567890',
      );
      expect(await connection.readControl(), <String, Object?>{'type': 'hello', 'counter': 1});
      final binary = await connection.readFrame();
      expect(binary, isA<LanSyncBinaryFrame>());
      expect((binary as LanSyncBinaryFrame).bytes, Uint8List.fromList(<int>[1, 2, 3, 4]));
      await connection.sendControl(<String, Object?>{'type': 'ready'});
      await connection.close();
      serverDone.complete();
    });

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final client = await PairedSecureConnection.client(
      raw: LanSyncFramedConnection(socket),
      sharedSecret: List<int>.filled(32, 7),
      clientNonce: 'client_nonce_1234567890',
      serverNonce: 'server_nonce_1234567890',
    );
    await client.sendControl(<String, Object?>{'type': 'hello', 'counter': 1});
    await client.sendBinary(Uint8List.fromList(<int>[1, 2, 3, 4]));
    expect(await client.readControl(), <String, Object?>{'type': 'ready'});
    await client.close();
    await serverDone.future;
  });

  test('paired connection rejects a frame authenticated with another device secret', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final serverDone = Completer<void>();
    server.listen((socket) async {
      final connection = await PairedSecureConnection.server(
        raw: LanSyncFramedConnection(socket),
        sharedSecret: List<int>.filled(32, 9),
        clientNonce: 'client_nonce_1234567890',
        serverNonce: 'server_nonce_1234567890',
      );
      await connection.sendControl(<String, Object?>{'type': 'private'});
      await connection.close();
      serverDone.complete();
    });

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final client = await PairedSecureConnection.client(
      raw: LanSyncFramedConnection(socket),
      sharedSecret: List<int>.filled(32, 8),
      clientNonce: 'client_nonce_1234567890',
      serverNonce: 'server_nonce_1234567890',
    );
    await expectLater(
      client.readControl(),
      throwsA(isA<LanSyncTransportException>().having((error) => error.code, 'code', 'lan_sync_secure_frame_invalid')),
    );
    await client.close();
    await serverDone.future;
  });
}
