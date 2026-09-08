import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/app_transfer_qr_payload.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';

void main() {
  test('compares semantic version before build number and never crosses platforms', () {
    const local = AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.9.9', buildNumber: 20);

    expect(isRemoteAppUpgrade(const AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.10.0', buildNumber: 1), local), isTrue);
    expect(isRemoteAppUpgrade(const AppVersionInfo(platform: AppUpdatePlatform.android, version: '0.9.9', buildNumber: 21), local), isTrue);
    expect(
      isRemoteAppUpgrade(const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '9.0.0', buildNumber: 999), local),
      isFalse,
    );
  });

  test('App QR is isolated from data-sync QR and preserves private candidates', () {
    final offer = AppTransferConnectionOffer(
      sessionId: 'app_session_123456',
      port: 52173,
      addresses: const <String>['192.168.1.8', '10.0.0.7'],
    );

    final encoded = AppTransferQrPayload.encode(offer);
    final decoded = AppTransferQrPayload.decode(encoded);

    expect(encoded, startsWith('mgread://app-transfer/v1'));
    expect(decoded?.sessionId, offer.sessionId);
    expect(decoded?.addresses, offer.addresses);
    expect(AppTransferQrPayload.decode('mgread://lan-sync/v2?session=x&port=1&addresses=192.168.1.1'), isNull);
  });
}
