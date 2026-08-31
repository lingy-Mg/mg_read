import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';
import 'package:mg_read/features/lan_sync/presentation/paired_device_widgets.dart';

void main() {
  const deviceId = 'desktop_device_123456';

  testWidgets('online device exposes bidirectional, pull, and push operations', (tester) async {
    final operations = <PairedSyncOperation>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PairedDevicesSection(
              state: DeviceSyncState(started: true, devices: <PairedDevice>[_device(deviceId)], onlineDeviceIds: const <String>{deviceId}),
              supportsScanner: false,
              onBeginPairing: () {},
              onApprovePairing: () {},
              onRejectPairing: () {},
              onCancelPairing: () {},
              onSync: (_, operation) => operations.add(operation),
              onManage: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('device-sync-bidirectional-$deviceId')));
    await tester.tap(find.byKey(const Key('device-sync-pull-$deviceId')));
    await tester.tap(find.byKey(const Key('device-sync-push-$deviceId')));

    expect(operations, const <PairedSyncOperation>[PairedSyncOperation.bidirectional, PairedSyncOperation.pull, PairedSyncOperation.push]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistent direction policy disables a forbidden manual operation', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: PairedDevicesSection(
            state: DeviceSyncState(
              started: true,
              devices: <PairedDevice>[_device(deviceId, mode: PairedSyncMode.receiveOnly)],
              onlineDeviceIds: const <String>{deviceId},
            ),
            supportsScanner: false,
            onBeginPairing: () {},
            onApprovePairing: () {},
            onRejectPairing: () {},
            onCancelPairing: () {},
            onSync: (_, _) {},
            onManage: (_) {},
          ),
        ),
      ),
    );

    expect(tester.widget<OutlinedButton>(find.byKey(const Key('device-sync-pull-$deviceId'))).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('device-sync-push-$deviceId'))).onPressed, isNull);
    expect(tester.widget<FilledButton>(find.byKey(const Key('device-sync-bidirectional-$deviceId'))).onPressed, isNull);
  });
}

PairedDevice _device(String deviceId, {PairedSyncMode mode = PairedSyncMode.bidirectional}) => PairedDevice(
  autoSync: true,
  createdAtUtc: DateTime.utc(2026, 8, 31),
  deviceId: deviceId,
  label: '开发电脑',
  mode: mode,
  platform: PairedDevicePlatform.windows,
  syncBookshelf: true,
  syncPlugins: true,
);
