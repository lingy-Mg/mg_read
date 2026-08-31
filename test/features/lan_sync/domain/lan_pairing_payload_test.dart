import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';

void main() {
  test('pairing QR round-trips multiple private addresses and pre-shared secret', () {
    final offer = LanPairingOffer(
      addresses: const <String>['192.168.1.20', '10.0.0.8'],
      deviceId: 'desktop_device_123456',
      label: '开发电脑',
      port: 49152,
      secret: List<int>.generate(32, (index) => index),
      sessionId: 'pairing_session_123456',
    );

    final decoded = LanPairingQrPayload.decode(LanPairingQrPayload.encode(offer));

    expect(decoded, isNotNull);
    expect(decoded!.addresses, offer.addresses);
    expect(decoded.deviceId, offer.deviceId);
    expect(decoded.label, offer.label);
    expect(decoded.port, offer.port);
    expect(decoded.secret, offer.secret);
    expect(decoded.sessionId, offer.sessionId);
  });

  test('pairing QR rejects public endpoints and malformed secrets', () {
    expect(
      LanPairingQrPayload.decode(
        'mgread://device-pair/v1?addresses=8.8.8.8&device=desktop_device_123456&label=PC&port=49152&secret=AA&session=pairing_session_123456',
      ),
      isNull,
    );

    final valid = LanPairingQrPayload.encode(
      LanPairingOffer(
        addresses: const <String>['192.168.1.20'],
        deviceId: 'desktop_device_123456',
        label: 'PC',
        port: 49152,
        secret: List<int>.generate(32, (index) => index),
        sessionId: 'pairing_session_123456',
      ),
    );
    final uri = Uri.parse(valid);
    final duplicated = uri.replace(queryParameters: <String, String>{...uri.queryParameters, 'addresses': '192.168.1.20,192.168.1.20'});
    expect(LanPairingQrPayload.decode(duplicated.toString()), isNull);
  });
}
