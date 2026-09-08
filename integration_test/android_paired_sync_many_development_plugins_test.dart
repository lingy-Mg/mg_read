/// Android 真机从 Windows 接收整批真实开发插件的集成验收。
///
/// 接收、校验、批次安装、Runtime 重启与 installed catalog 查询均走生产实现。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import '../test/features/lan_sync/data/paired_sync_cross_device_support.dart';

const String _windowsAddress = String.fromEnvironment('MGREAD_CROSS_DEVICE_ADDRESS');
const int _windowsPort = int.fromEnvironment('MGREAD_CROSS_DEVICE_PORT');
const int _expectedPluginCount = int.fromEnvironment('MGREAD_EXPECTED_PLUGIN_COUNT');
const String _expectedPluginIdsText = String.fromEnvironment('MGREAD_EXPECTED_PLUGIN_IDS');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android installs every Windows development plugin', (tester) async {
    expect(_windowsAddress, isNotEmpty);
    expect(_windowsPort, inInclusiveRange(1, 65535));
    expect(_expectedPluginCount, greaterThanOrEqualTo(50));
    final expectedPluginIds = _expectedPluginIdsText.split(',').where((id) => id.isNotEmpty).toSet();
    expect(expectedPluginIds, hasLength(_expectedPluginCount));

    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final dataRoot = await Directory.systemTemp.createTemp('mgread-many-development-sync-android-');
    final library = await ContentLibrary.open(dataRoot: dataRoot);
    addTearDown(() async {
      await library.close();
      await dataRoot.delete(recursive: true);
    });
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

    final summary = await session.run(gateway: MgReadLanSyncGateway(library, runtime), operation: PairedSyncOperation.pull);

    expect(summary.receivedPlugins, _expectedPluginCount);
    expect(summary.receivedBooks, 0);
    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    final installedById = <String, InstalledPlugin>{for (final plugin in installed) plugin.id: plugin};
    final missing = expectedPluginIds.difference(installedById.keys.toSet());
    expect(missing, isEmpty);
    for (final pluginId in expectedPluginIds) {
      final plugin = installedById[pluginId]!;
      expect(plugin.status, 'active', reason: pluginId);
      expect(plugin.activeVersion, contains('-devsync.'), reason: pluginId);
    }
    debugPrint(
      'MGREAD_MANY_DEVELOPMENT_ANDROID_SUCCESS=true '
      'receivedPlugins=${summary.receivedPlugins} '
      'verifiedPlugins=${expectedPluginIds.length}',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
