/// Verifies that the LAN-sync scanner owns its asynchronous startup cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_scanner_page.dart';

void main() {
  test('scanner purpose accepts only the expected MgRead QR payload', () {
    final syncPayload = _syncPayload();
    final pairingPayload = _pairingPayload();

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

  testWidgets('pairing scanner rejects a sync QR and returns a pairing QR', (tester) async {
    String? scannedPayload;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            key: const Key('open-pairing-scanner'),
            onPressed: () async {
              scannedPayload = await Navigator.of(context).push<String>(
                MaterialPageRoute<String>(builder: (_) => const LanSyncQrScannerPage(purpose: LanSyncQrScannerPurpose.pairing)),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-pairing-scanner')));
    await tester.pumpAndSettle();
    var scanner = tester.widget<MobileScanner>(find.byKey(const Key('lan-sync-qr-scanner')));
    scanner.onDetect!(BarcodeCapture(barcodes: <Barcode>[Barcode(rawValue: _syncPayload())]));
    await tester.pump();

    expect(find.text('这不是 MgRead 设备配对二维码'), findsOneWidget);
    expect(scannedPayload, isNull);

    scanner = tester.widget<MobileScanner>(find.byKey(const Key('lan-sync-qr-scanner')));
    final pairingPayload = _pairingPayload();
    scanner.onDetect!(BarcodeCapture(barcodes: <Barcode>[Barcode(rawValue: pairingPayload)]));
    await tester.pumpAndSettle();

    expect(scannedPayload, pairingPayload);
    expect(find.byType(LanSyncQrScannerPage), findsNothing);
  });
}

String _syncPayload() => LanSyncQrPayload.encode(
  LanSyncConnectionOffer(sessionId: 'sync_session_123456', port: 49151, addresses: const <String>['192.168.1.20']),
);

String _pairingPayload() => LanPairingQrPayload.encode(
  LanPairingOffer(
    addresses: const <String>['192.168.1.20'],
    deviceId: 'desktop_device_123456',
    label: '开发电脑',
    port: 49152,
    secret: List<int>.generate(32, (index) => index),
    sessionId: 'pairing_session_123456',
  ),
);
