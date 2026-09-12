import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/app_transfer_controller.dart';
import 'package:mg_read/features/lan_sync/domain/app_update_models.dart';
import 'package:mg_read/features/lan_sync/presentation/app_transfer_widgets.dart';
import 'package:mg_read/features/lan_sync/presentation/paired_device_widgets.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

void main() {
  testWidgets('temporary App confirmation shows both versions and normal upgrade', (tester) async {
    const local = AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.0.0', buildNumber: 10);
    const remote = AppVersionInfo(platform: AppUpdatePlatform.android, version: '1.1.0', buildNumber: 11);
    bool? forced;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AppTransferPanel(
              state: const AppTransferState(
                phase: AppTransferPhase.ready,
                role: AppTransferRole.receiver,
                message: '请核对版本并确认安装',
                localVersion: local,
                offeredVersion: remote,
                pairingCode: '123456',
              ),
              onScanQr: () {},
              onInstall: (value) => forced = value,
              onCancel: () {},
              onReset: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('1.0.0 (10)'), findsOneWidget);
    expect(find.text('1.1.0 (11)'), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
    await tester.tap(find.byKey(const Key('app-transfer-upgrade')));
    expect(forced, isFalse);
  });

  testWidgets('online paired device exposes upgrade or explicit force install from real versions', (tester) async {
    const deviceId = 'desktop_device_123456';
    final actions = <bool>[];
    Future<void> pump(AppVersionInfo remote) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PairedDevicesSection(
              state: DeviceSyncState(
                started: true,
                devices: <PairedDevice>[_device(deviceId)],
                onlineDeviceIds: const <String>{deviceId},
                localAppVersion: const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '2.0.0', buildNumber: 20),
                appOffersByDeviceId: <String, AppPackageOffer>{deviceId: AppPackageOffer(version: remote, available: true)},
              ),
              supportsScanner: false,
              onBeginPairing: () {},
              onApprovePairing: () {},
              onRejectPairing: () {},
              onCancelPairing: () {},
              onSync: (_, _) {},
              onAppUpdate: (_, force) => actions.add(force),
              onManage: (_) {},
            ),
          ),
        ),
      ),
    );

    await pump(const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '2.1.0', buildNumber: 21));
    expect(find.textContaining('有新版本'), findsOneWidget);
    await tester.tap(find.byKey(Key('device-sync-app-upgrade-$deviceId')));

    await pump(const AppVersionInfo(platform: AppUpdatePlatform.windows, version: '2.0.0', buildNumber: 20));
    await tester.tap(find.byKey(Key('device-sync-app-force-$deviceId')));
    expect(actions, <bool>[false, true]);
  });
}

PairedDevice _device(String deviceId) => PairedDevice(
  autoSync: true,
  createdAtUtc: DateTime.utc(2026, 9, 8),
  deviceId: deviceId,
  label: '开发电脑',
  mode: PairedSyncMode.bidirectional,
  platform: PairedDevicePlatform.windows,
  syncBookshelf: true,
  syncPlugins: true,
);
