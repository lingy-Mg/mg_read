/// MuMu Android 端跨设备配对同步客户端。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import '../test/features/lan_sync/data/paired_sync_cross_device_support.dart';

const String _windowsAddress = String.fromEnvironment('MGREAD_CROSS_DEVICE_ADDRESS');
const int _windowsPort = int.fromEnvironment('MGREAD_CROSS_DEVICE_PORT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MuMu completes bidirectional HTTP sync with Windows', (tester) async {
    expect(_windowsAddress, isNotEmpty);
    expect(_windowsPort, inInclusiveRange(1, 65535));
    final gateway = CrossDeviceSyncGateway(side: 'android', pluginIds: const <String>['org.example.android.one']);
    final session = await PairedSyncClientSession.connectAny(
      endpoints: <PairedSyncEndpoint>[
        PairedSyncEndpoint(
          address: _windowsAddress,
          deviceId: crossDeviceWindowsIdentity.deviceId,
          expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 2)),
          label: crossDeviceWindowsIdentity.label,
          port: _windowsPort,
        ),
      ],
      identity: crossDeviceAndroidIdentity,
      peer: crossDevicePeer(crossDeviceWindowsIdentity, PairedDevicePlatform.windows),
      sharedSecret: crossDeviceSecret(),
    );

    final summary = await session.run(gateway: gateway);

    expect(summary.receivedBooks, 1);
    expect(summary.receivedPlugins, 3);
    expect(summary.sentBooks, 1);
    expect(summary.sentPlugins, 1);
    expect(gateway.appliedShelfItems.single.remoteContentId, 'windows-book');
    expect(gateway.appliedShelfItems.single.progress?.chapterId, 'windows-chapter-2');
    expect(gateway.importedPluginIds, <String>{'org.example.windows.one', 'org.example.windows.two', 'org.example.windows.three'});
  });
}
