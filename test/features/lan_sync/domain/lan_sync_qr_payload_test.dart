import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';

void main() {
  test('round trips all private LAN candidates in a versioned payload', () {
    final offer = LanSyncConnectionOffer(
      sessionId: 'session_12345678',
      port: 47231,
      addresses: const <String>['192.168.1.20', '10.10.0.8', '172.16.5.9'],
    );

    final payload = LanSyncQrPayload.encode(offer);
    final decoded = LanSyncQrPayload.decode(payload);

    expect(payload, startsWith('mgread://lan-sync/v2?'));
    expect(decoded?.sessionId, offer.sessionId);
    expect(decoded?.port, offer.port);
    expect(decoded?.addresses, offer.addresses);
    expect(decoded?.manualAddresses, <String>[
      'session_12345678@192.168.1.20:47231',
      'session_12345678@10.10.0.8:47231',
      'session_12345678@172.16.5.9:47231',
    ]);
  });

  test('rejects foreign, malformed, and oversized QR payloads', () {
    expect(LanSyncQrPayload.decode('https://example.com'), isNull);
    expect(
      LanSyncQrPayload.decode(
        'mgread://lan-sync/v1?address=session_12345678%40192.168.1.2%3A8',
      ),
      isNull,
    );
    expect(
      LanSyncQrPayload.decode(
        'mgread://lan-sync/v2?session=session_12345678&port=8&addresses=8.8.8.8',
      ),
      isNull,
    );
    expect(
      LanSyncQrPayload.decode(
        'mgread://lan-sync/v2?session=session_12345678&port=8&addresses=192.168.1.2,192.168.1.2',
      ),
      isNull,
    );
    expect(LanSyncQrPayload.decode('x' * 2049), isNull);
  });

  test('manual address only accepts RFC1918 IPv4 endpoints', () {
    expect(
      LanSyncConnectionOffer.tryParseManual(
        'session_12345678@192.168.1.20:47231',
      )?.addresses,
      <String>['192.168.1.20'],
    );
    for (final address in <String>[
      '127.0.0.1',
      '169.254.1.2',
      '100.64.1.2',
      '8.8.8.8',
    ]) {
      expect(
        LanSyncConnectionOffer.tryParseManual(
          'session_12345678@$address:47231',
        ),
        isNull,
      );
    }
  });
}
