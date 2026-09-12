import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_update_service.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';

void main() {
  testWidgets('main page keeps receiving in the unified scan flow and sends in sheets', (WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        lanSyncGatewayProvider.overrideWithValue(const _Gateway()),
        appUpdateServiceProvider.overrideWithValue(const _AppUpdateService()),
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

    expect(find.byKey(const Key('lan-sync-unified-scan')), findsNothing);
    expect(find.byKey(const Key('lan-sync-scan')), findsOneWidget);
    expect(find.text('设备同步'), findsOneWidget);
    expect(find.text('发送 App'), findsNWidgets(2));
    expect(find.text('临时发送'), findsOneWidget);
    expect(find.text('获取 App'), findsNothing);
    expect(find.text('接收数据'), findsNothing);

    await tester.tap(find.byKey(const Key('device-sync-add-device')));
    await tester.pumpAndSettle();
    expect(find.text('添加设备'), findsAtLeastNWidgets(2));
    expect(find.byKey(const Key('device-sync-show-pairing-code')), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    final temporarySend = find.byKey(const Key('lan-sync-temporary-transfer'));
    await tester.drag(find.byKey(const Key('lan-sync-content')), const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(temporarySend);
    await tester.pumpAndSettle();
    expect(find.text('临时发送数据'), findsOneWidget);
    expect(find.byKey(const Key('lan-sync-generate-transfer-code')), findsOneWidget);
  });
}

final class _Gateway implements LanSyncGateway {
  const _Gateway();

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

final class _AppUpdateService implements AppUpdateService {
  const _AppUpdateService();

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
