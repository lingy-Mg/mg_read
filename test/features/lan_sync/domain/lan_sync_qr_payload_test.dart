import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';

void main() {
  test('round trips a versioned bounded LAN sync QR payload', () {
    const address = 'session_12345678@192.168.1.20:47231';

    final payload = LanSyncQrPayload.encode(address);

    expect(payload, startsWith('mgread://lan-sync/v1?'));
    expect(LanSyncQrPayload.decode(payload), address);
  });

  test('rejects foreign, malformed, and oversized QR payloads', () {
    expect(LanSyncQrPayload.decode('https://example.com'), isNull);
    expect(
      LanSyncQrPayload.decode(
        'mgread://lan-sync/v2?address=session_12345678%40192.168.1.2%3A8',
      ),
      isNull,
    );
    expect(
      LanSyncQrPayload.decode('mgread://lan-sync/v1?address=broken'),
      isNull,
    );
    expect(LanSyncQrPayload.decode('x' * 513), isNull);
  });
}
