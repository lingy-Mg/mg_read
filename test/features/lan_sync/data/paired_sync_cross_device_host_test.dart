/// Windows 端跨设备配对同步宿主。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import 'paired_sync_cross_device_support.dart';

void main() {
  test('Windows host completes bidirectional HTTP sync with Android', () async {
    final gateway = CrossDeviceSyncGateway(
      side: 'windows',
      pluginIds: const <String>['org.example.windows.one', 'org.example.windows.two', 'org.example.windows.three'],
    );
    final result = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: crossDeviceWindowsIdentity,
      devices: CrossDevicePairedRepository(crossDevicePeer(crossDeviceAndroidIdentity, PairedDevicePlatform.android)),
      identityStore: CrossDeviceIdentityStore(crossDeviceWindowsIdentity, crossDeviceAndroidIdentity.deviceId),
      discoveryPort: 0,
      onIncoming: (session) async {
        try {
          result.complete(await session.run(gateway: gateway));
        } on Object catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    // Parsed by the coordinating Android test command.
    debugPrint('MGREAD_CROSS_DEVICE_PORT=${host.port}');

    final summary = await result.future.timeout(const Duration(minutes: 6));

    expect(summary.receivedBooks, 1);
    expect(summary.receivedPlugins, 1);
    expect(summary.sentBooks, 1);
    expect(summary.sentPlugins, 3);
    expect(gateway.appliedShelfItems.single.remoteContentId, 'android-book');
    expect(gateway.appliedShelfItems.single.progress?.chapterId, 'android-chapter-2');
    expect(gateway.importedPluginIds, <String>{'org.example.android.one'});
    debugPrint('MGREAD_CROSS_DEVICE_WINDOWS_SUCCESS=true');
  }, timeout: const Timeout(Duration(minutes: 7)));
}
