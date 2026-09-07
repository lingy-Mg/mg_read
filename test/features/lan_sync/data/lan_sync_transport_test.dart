/// 临时扫码同步通过真实 HTTP 服务端/客户端验证，不保留旧 TCP 帧测试。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('temporary HTTP sync pairs, reads manifest and transfers selected artifact', () async {
    final bytes = utf8.encode('http artifact');
    final plugin = LanSyncPluginDescriptor(
      id: 'source.http',
      version: '1.0.0',
      bytes: bytes.length,
      artifactFormat: LanSyncPluginArtifactFormat.archive,
      sha256: sha256.convert(bytes).toString(),
      transferable: true,
    );
    final sender = await LanSyncSenderService.start(
      manifest: LanSyncManifest(plugins: [plugin], shelfItems: const [], skippedShelfItems: 0),
      openPlugin: (_) async => Stream.value(bytes),
    );
    addTearDown(sender.close);
    final receiver = await LanSyncReceiverConnection.connect(
      LanSyncPeer(
        sessionId: sender.sessionId,
        label: 'sender',
        address: sender.addresses.first,
        port: sender.port,
        expiresAtUtc: DateTime.now().toUtc().add(const Duration(minutes: 1)),
      ),
    );
    addTearDown(receiver.close);
    final manifest = await receiver.confirmAndReadManifest();
    expect(manifest.plugins.single.id, plugin.id);
    final received = <int>[];
    await receiver.receivePlugins(
      pluginIds: {plugin.id},
      importPlugin: (_, stream) async => received.addAll(await stream.expand((chunk) => chunk).toList()),
    );
    expect(received, bytes);
  });

  test('address selection excludes virtual interfaces and duplicates', () {
    expect(
      selectLanSyncCandidateAddresses(const [
        LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '192.168.1.8'),
        LanSyncNetworkAddress(interfaceName: 'Ethernet', address: '192.168.1.8'),
        LanSyncNetworkAddress(interfaceName: 'vEthernet (WSL)', address: '172.20.0.1'),
      ]),
      ['192.168.1.8'],
    );
  });
}
