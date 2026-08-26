/// Verifies that the LAN-sync scanner owns its asynchronous startup cleanly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_scanner_page.dart';

void main() {
  testWidgets('scanner startup does not escape the page boundary', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LanSyncQrScannerPage()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('lan-sync-qr-scanner')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
