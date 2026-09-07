import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_scanner_page.dart';

void main() {
  testWidgets('Android entry offers scanning and connection card renders QR', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer(overrides: [lanSyncGatewayProvider.overrideWithValue(const _EmptyGateway())]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: LanSyncPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('lan-sync-overview')), findsOneWidget);
    expect(find.byKey(const Key('lan-sync-receive-qr')), findsOneWidget);
    final pairingScanButton = find.byKey(const Key('device-sync-scan-pairing'));
    expect(pairingScanButton, findsOneWidget);
    await tester.ensureVisible(pairingScanButton);
    await tester.tap(pairingScanButton);
    await tester.pumpAndSettle();

    final pairingScanner = tester.widget<LanSyncQrScannerPage>(find.byType(LanSyncQrScannerPage));
    expect(pairingScanner.purpose, LanSyncQrScannerPurpose.pairing);
    await tester.tap(find.byKey(const Key('lan-sync-scanner-close')));
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: LanSyncConnectionQrCard(
            offer: LanSyncConnectionOffer(sessionId: 'session_12345678', port: 47231, addresses: <String>['192.168.1.20', '10.10.0.8']),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('lan-sync-sender-qr')), findsOneWidget);
    expect(find.byKey(const Key('lan-sync-sender-address')), findsOneWidget);
    expect(find.byKey(const Key('lan-sync-sender-address-1')), findsOneWidget);
    expect(find.textContaining('并发测试并自动选择'), findsOneWidget);
  });
}

final class _EmptyGateway implements LanSyncGateway {
  const _EmptyGateway();

  @override
  Future<LanSyncManifest> createManifest() async =>
      const LanSyncManifest(plugins: <LanSyncPluginDescriptor>[], shelfItems: <LanSyncShelfItem>[], skippedShelfItems: 0);

  @override
  Future<void> cancelPluginImports() async {}

  @override
  Future<void> preparePluginImports(List<LanSyncPluginDescriptor> plugins, {Set<String> forceUpgradePluginIds = const <String>{}}) async {}

  @override
  Future<Stream<List<int>>> openPluginArchive(LanSyncPluginDescriptor plugin) async => const Stream<List<int>>.empty();

  @override
  Future<LanSyncImportPreview> previewImport(LanSyncManifest manifest, {bool force = false}) => throw UnimplementedError();

  @override
  Future<void> importPluginArchive(LanSyncPluginDescriptor plugin, Stream<List<int>> bytes) => throw UnimplementedError();

  @override
  Future<LanSyncPluginImportResult> finishPluginImports() => throw UnimplementedError();

  @override
  Future<LanSyncApplyResult> applyImport({
    required LanSyncManifest manifest,
    required Map<String, LanSyncConflictChoice> conflictChoices,
    required Set<String> availablePluginIds,
    required LanSyncPluginImportResult pluginResult,
    bool force = false,
  }) => throw UnimplementedError();
}
