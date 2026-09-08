/// MuMu 从 Windows 接收真实插件制品、书架元信息和阅读进度的集成验收。
library;

import 'dart:io';

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MuMu installs the Windows plugin and persists bookshelf metadata and progress', (tester) async {
    expect(_windowsAddress, isNotEmpty);
    expect(_windowsPort, inInclusiveRange(1, 65535));
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final dataRoot = await Directory.systemTemp.createTemp('mgread-cross-device-runtime-');
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

    expect(summary.receivedBooks, 1);
    expect(summary.receivedPlugins, 1);
    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    final plugin = installed.singleWhere((item) => item.id == 'org.mgread.discovery-demo');
    expect(plugin.status, 'active');
    expect(plugin.activeVersion, '0.1.2');
    final shelf = await library.listLibrary(const LibraryQuery(limit: 10));
    final item = shelf.items.singleWhere((value) => value.source.remoteContentId == 'book:cross-device-runtime');
    expect(item.title, '跨设备同步测试书籍');
    final progress = await library.loadProgress(item.id);
    expect(progress, isA<LibraryReadingProgress>());
    final readingProgress = progress! as LibraryReadingProgress;
    expect(readingProgress.chapterId, 'chapter:2');
    expect(readingProgress.characterOffset, 17);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
