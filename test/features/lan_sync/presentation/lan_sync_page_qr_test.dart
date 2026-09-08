import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_qr_payload.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_qr_scanner_page.dart';

void main() {
  testWidgets('Android entry offers scanning and connection card renders QR', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer(
      overrides: [
        lanSyncGatewayProvider.overrideWithValue(const _EmptyGateway()),
        appUpdateServiceProvider.overrideWithValue(const _TestAppUpdateService()),
      ],
    );
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
    final scrollable = find.descendant(of: find.byKey(const Key('lan-sync-content')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('lan-sync-receive-qr')), 240, scrollable: scrollable);
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

    final appScanButton = find.byKey(const Key('app-transfer-scan'));
    await tester.scrollUntilVisible(appScanButton, 240, scrollable: scrollable);
    await tester.tap(appScanButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final appScanner = tester.widget<LanSyncQrScannerPage>(find.byType(LanSyncQrScannerPage));
    expect(appScanner.purpose, LanSyncQrScannerPurpose.appTransfer);
    await tester.tap(find.byKey(const Key('lan-sync-scanner-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await container.read(appTransferControllerProvider.notifier).cancel();
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

final class _TestAppUpdateService implements AppUpdateService {
  const _TestAppUpdateService();

  @override
  Future<AppVersionInfo> currentVersion() async =>
      const AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.0.0', buildNumber: 1);

  @override
  Future<List<AppPackageOffer>> availablePackages() async => const <AppPackageOffer>[];

  @override
  Future<void> ensureInstallPermission() async {}

  @override
  Future<void> launchInstaller(File package, AppPackageDescriptor descriptor) => throw UnimplementedError();

  @override
  Future<PreparedAppPackage> preparePackage(AppUpdatePlatform platform) => throw UnimplementedError();
}
