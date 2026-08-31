/// Verifies that the LAN-sync scanner owns its asynchronous startup cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_scanner_page.dart';

void main() {
  test('scanner purpose accepts only the expected MgRead QR payload', () {
    final syncPayload = LanSyncQrPayload.encode(
      LanSyncConnectionOffer(sessionId: 'sync_session_123456', port: 49151, addresses: const <String>['192.168.1.20']),
    );
    final pairingPayload = LanPairingQrPayload.encode(
      LanPairingOffer(
        addresses: const <String>['192.168.1.20'],
        deviceId: 'desktop_device_123456',
        label: '开发电脑',
        port: 49152,
        secret: List<int>.generate(32, (index) => index),
        sessionId: 'pairing_session_123456',
      ),
    );

    expect(LanSyncQrScannerPurpose.sync.accepts(syncPayload), isTrue);
    expect(LanSyncQrScannerPurpose.sync.accepts(pairingPayload), isFalse);
    expect(LanSyncQrScannerPurpose.pairing.accepts(pairingPayload), isTrue);
    expect(LanSyncQrScannerPurpose.pairing.accepts(syncPayload), isFalse);
  });

  testWidgets('scanner startup does not escape the page boundary', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LanSyncQrScannerPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lan-sync-qr-scanner')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
