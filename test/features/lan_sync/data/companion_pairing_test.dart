import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/lan_pairing_authentication.dart';
import 'package:mg_read/features/lan_sync/data/lan_pairing_transport.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  const desktop = LocalDeviceIdentity(deviceId: 'desktop_pairing_123456', label: '开发电视');
  const phone = LocalDeviceIdentity(deviceId: 'phone_pairing_12345678', label: '手机');
  const seed = <int>[0x11, 0x52, 0x93, 0xd4, 0x15, 0x56, 0x97, 0xd8, 0x19, 0x5a, 0x9b, 0xdc, 0x1d, 0x5e, 0x9f, 0xe0];
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

  test('manual pairing code is canonical 128-bit base32 and HKDF is session-bound', () async {
    final code = encodeCompanionManualSeed(seed);
    expect(code, hasLength(26));
    expect(decodeCompanionManualSeed(code), seed);
    expect(() => decodeCompanionManualSeed(code.toLowerCase()), throwsFormatException);
    expect(() => decodeCompanionManualSeed('${code.substring(0, 25)}B'), throwsFormatException);
    final secretA = await deriveCompanionManualSecret(seed, 'session-a');
    final secretB = await deriveCompanionManualSecret(seed, 'session-b');
    expect(secretA, hasLength(32));
    expect(secretA, isNot(secretB));
  });

  test('companion QR uses v2 while legacy QR remains v1', () {
    final legacy = LanPairingOffer(
      addresses: const <String>['192.168.1.20'],
      deviceId: desktop.deviceId,
      label: desktop.label,
      port: 4321,
      secret: psk,
      sessionId: 'legacy-session-123',
    );
    final companion = LanPairingOffer(
      addresses: const <String>['192.168.1.20'],
      deviceId: desktop.deviceId,
      label: desktop.label,
      port: 4321,
      secret: psk,
      sessionId: 'companion-session-123',
      companionOnly: true,
    );
    expect(LanPairingQrPayload.encode(legacy), contains('/v1?'));
    expect(LanPairingQrPayload.decode(LanPairingQrPayload.encode(legacy))?.companionOnly, isFalse);
    final companionQr = LanPairingQrPayload.encode(companion);
    expect(companionQr, contains('/v2?'));
    expect(companionQr, contains('purpose=companion'));
    expect(LanPairingQrPayload.decode(companionQr)?.companionOnly, isTrue);
  });

  test('manual companion pairing keeps sync scopes off until both devices confirm', () async {
    if ((await eligibleLanSyncAddresses()).isEmpty) return;
    final server = await LanPairingServer.start(desktop, companionOnly: true);
    addTearDown(server.close);
    expect(server.manualPairingCode, hasLength(26));
    final address = server.offer.addresses.first;
    final offer = await LanPairingClientConnection.fetchManualOffer(
      address: address,
      port: server.offer.port,
      code: server.manualPairingCode!,
    );
    expect(offer.companionOnly, isTrue);
    final requestFuture = server.requests.first;
    final client = await LanPairingClientConnection.connect(offer, phone);
    addTearDown(client.close);
    final request = await requestFuture;

    expect(request.companionOnly, isTrue);
    expect(request.peer.autoSync, isFalse);
    expect(request.peer.syncBookshelf, isFalse);
    expect(request.peer.syncPlugins, isFalse);
    expect(client.peer.autoSync, isFalse);
    expect(client.peer.syncBookshelf, isFalse);
    expect(client.peer.syncPlugins, isFalse);
    expect(client.pairingCode, request.pairingCode);

    var phoneConfirmed = false;
    final approvedPeerFuture = client.waitForApproval().then((peer) {
      phoneConfirmed = true;
      return peer;
    });
    final serverApproval = request.approve();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(phoneConfirmed, isFalse, reason: 'phone must confirm the displayed six-digit code');
    client.confirmCode();
    client.confirmCode();
    final approvedPeer = await approvedPeerFuture.timeout(const Duration(seconds: 3));
    expect(approvedPeer.deviceId, desktop.deviceId);
    expect(phoneConfirmed, isTrue);
    await client.confirmCommitted();
    await serverApproval.timeout(const Duration(seconds: 3));
    expect(request.isActive, isFalse);
  });

  test('manual wrong code is rejected by v4 request authentication', () async {
    if ((await eligibleLanSyncAddresses()).isEmpty) return;
    final server = await LanPairingServer.start(desktop, companionOnly: true);
    addTearDown(server.close);
    final wrongCode = encodeCompanionManualSeed(List<int>.filled(16, 0xA5));
    final address = server.offer.addresses.first;
    final wrongOffer = await LanPairingClientConnection.fetchManualOffer(address: address, port: server.offer.port, code: wrongCode);
    await expectLater(LanPairingClientConnection.connect(wrongOffer, phone), throwsA(isA<LanSyncTransportException>()));
    expect(server.pending, isEmpty);
    expect(server.failedV4Attempts[address], hasLength(1));
  });

  test('cancelling an unconfirmed companion join rejects the TV approval promptly', () async {
    if ((await eligibleLanSyncAddresses()).isEmpty) return;
    final server = await LanPairingServer.start(desktop, companionOnly: true);
    addTearDown(server.close);
    final offer = await LanPairingClientConnection.fetchManualOffer(
      address: server.offer.addresses.first,
      port: server.offer.port,
      code: server.manualPairingCode!,
    );
    final requestFuture = server.requests.first;
    final client = await LanPairingClientConnection.connect(offer, phone);
    final request = await requestFuture;
    final waitForApproval = client.waitForApproval();
    final approval = request.approve();
    final waitRejected = expectLater(waitForApproval, throwsA(isA<LanSyncTransportException>()));
    final approvalRejected = expectLater(approval, throwsA(isA<LanSyncTransportException>()));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await client.close();
    await waitRejected;
    await approvalRejected;
    expect(request.isActive, isFalse);
  });

  test('v4 response authentication detects body tampering and wrong PSKs', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final result = Completer<bool>();
    server.listen((request) async {
      final body = await request.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
      final proof = CompanionPairingAuthentication.verifyRequest(request, sharedSecret: psk, body: body, acceptedNonces: <String, int>{});
      if (proof == null) {
        if (!result.isCompleted) result.complete(false);
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
        return;
      }
      const responseBody = '{"status":"ok"}';
      final bytes = utf8.encode(responseBody);
      request.response.statusCode = HttpStatus.ok;
      CompanionPairingAuthentication.signResponseWithSecret(
        request.response,
        sharedSecret: psk,
        request: proof,
        status: HttpStatus.ok,
        body: bytes,
      );
      request.response.contentLength = bytes.length;
      request.response.add(<int>[...bytes]..[10] ^= 1);
      await request.response.close();
      if (!result.isCompleted) result.complete(true);
    });

    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/v4/pair'));
    const requestBody = <int>[123, 125];
    final auth = CompanionPairingAuthentication.signRequest(request, deviceId: phone.deviceId, sharedSecret: psk, body: requestBody);
    request.contentLength = requestBody.length;
    request.add(requestBody);
    final response = await request.close();
    final responseBody = await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    expect(await result.future, isTrue);
    expect(CompanionPairingAuthentication.verifyResponse(response, sharedSecret: psk, request: auth, body: responseBody), isFalse);

    final badRequest = await client.postUrl(Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: '/v4/pair'));
    CompanionPairingAuthentication.signRequest(
      badRequest,
      deviceId: phone.deviceId,
      sharedSecret: List<int>.filled(32, 0xA5),
      body: requestBody,
    );
    badRequest.contentLength = requestBody.length;
    badRequest.add(requestBody);
    final rejected = await badRequest.close();
    await rejected.drain<void>();
  });
}
