/// Windows 使用真实 Runtime 向 Android 推送整批开发插件的跨设备宿主。
///
/// 测试 Runtime 使用独立临时数据根，但扫描仓库真实 `plugins/sources`；
/// HTTP v4、开发插件 deferred offer、已激活制品复用和制品上传均走生产实现。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/lan_sync/data/mg_read_lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/paired_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import 'paired_sync_cross_device_support.dart';

const int _expectedPluginCount = int.fromEnvironment('MGREAD_EXPECTED_PLUGIN_COUNT');
const String _expectedPluginIdsText = String.fromEnvironment('MGREAD_EXPECTED_PLUGIN_IDS');

void main() {
  test('Windows sends every development plugin to Android', () async {
    expect(_expectedPluginCount, greaterThanOrEqualTo(50));
    final expectedPluginIds = _expectedPluginIdsText.split(',').where((id) => id.isNotEmpty).toSet();
    expect(expectedPluginIds, hasLength(_expectedPluginCount));

    final temporaryRoot = await Directory.systemTemp.createTemp('mgread-many-development-sync-host-');
    addTearDown(() => temporaryRoot.delete(recursive: true));
    final runtime = PluginRuntime.desktopForTesting(
      runtimeRepositoryRoot: Directory('packages/mg_read_node_runtime').absolute,
      runtimeDataRoot: Directory('${temporaryRoot.path}/runtime'),
      developmentPluginRoot: Directory('plugins/sources').absolute,
    );
    addTearDown(runtime.debugDispose);
    final library = await ContentLibrary.open(dataRoot: Directory('${temporaryRoot.path}/library'));
    addTearDown(library.close);

    final offers = await runtime.invoke(const PluginTransferOfferListInvocation());
    final developmentOffers = offers.where((offer) => offer.provenance == PluginArtifactProvenance.development).toList(growable: false);
    final offeredIds = developmentOffers.map((offer) => offer.pluginId).toSet();
    expect(developmentOffers, hasLength(_expectedPluginCount));
    expect(offeredIds, expectedPluginIds);
    expect(
      developmentOffers,
      everyElement(
        isA<PluginTransferOffer>()
            .having((offer) => offer.developmentFingerprint, 'developmentFingerprint', matches(RegExp(r'^[a-f0-9]{64}$')))
            .having((offer) => offer.developmentRevision, 'developmentRevision', greaterThan(0)),
      ),
    );

    final result = Completer<PairedSyncRunSummary>();
    final host = await PairedSyncHost.start(
      identity: crossDeviceWindowsIdentity,
      devices: CrossDevicePairedRepository(crossDevicePeer(crossDeviceAndroidIdentity, PairedDevicePlatform.android)),
      identityStore: CrossDeviceIdentityStore(crossDeviceWindowsIdentity, crossDeviceAndroidIdentity.deviceId),
      discoveryPort: 0,
      onIncoming: (session) async {
        try {
          result.complete(await session.run(gateway: MgReadLanSyncGateway(library, runtime)));
        } on Object catch (error, stackTrace) {
          result.completeError(error, stackTrace);
        }
      },
    );
    addTearDown(host.close);
    debugPrint('MGREAD_MANY_DEVELOPMENT_PORT=${host.port}');
    debugPrint('MGREAD_MANY_DEVELOPMENT_OFFERS=${developmentOffers.length}');
    debugPrint('MGREAD_MANY_DEVELOPMENT_IDS=${offeredIds.join(',')}');

    final summary = await result.future.timeout(const Duration(minutes: 18));

    expect(summary.sentPlugins, _expectedPluginCount);
    expect(summary.sentBooks, 0);
    expect(summary.receivedPlugins, 0);
    expect(summary.receivedBooks, 0);
    debugPrint(
      'MGREAD_MANY_DEVELOPMENT_WINDOWS_SUCCESS=true '
      'sentPlugins=${summary.sentPlugins}',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));
}
