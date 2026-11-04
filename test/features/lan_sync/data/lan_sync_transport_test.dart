/// 临时扫码同步通过真实 HTTP 服务端/客户端验证，不保留旧 TCP 帧测试。
library;

import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  test('temporary HTTP sync transfers TXT originals and custom covers with verified hashes', () async {
    final bytes = utf8.encode('第一章\n二维码传输原书');
    final coverExpected = <int>[137, 80, 78, 71, 13, 10, 26, 10, 2, 3];
    final document = LanSyncLocalDocumentDescriptor(
      documentId: 'local-document-1',
      rawSha256: crypto.sha256.convert(bytes).toString(),
      originalBytes: bytes.length,
      format: 'txt',
      title: '本地书',
      options: const <String, Object?>{},
      coverSha256: crypto.sha256.convert(coverExpected).toString(),
      coverBytes: coverExpected.length,
      coverMimeType: 'image/png',
    );
    final sender = await LanSyncSenderService.start(
      manifest: LanSyncManifest(
        plugins: const <LanSyncPluginDescriptor>[],
        shelfItems: const <LanSyncShelfItem>[],
        skippedShelfItems: 0,
        localDocuments: <LanSyncLocalDocumentDescriptor>[document],
      ),
      openPlugin: (_) async => const Stream<List<int>>.empty(),
      openLocalDocument: (_, {required bool cover}) async => Stream<List<int>>.value(cover ? coverExpected : bytes),
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
    expect(manifest.localDocuments.single.rawSha256, document.rawSha256);
    final receivedOriginal = <int>[];
    final receivedCover = <int>[];
    final done = sender.events.firstWhere((event) => event is LanSyncSenderDone);
    final receiving = receiver.receivePlugins(
      pluginIds: const <String>{},
      localDocumentIds: <String>{document.documentId},
      importPlugin: (_, _) async {},
      importLocalDocument: (descriptor, stream, {coverBytes, coverMimeType}) async {
        expect(descriptor.documentId, document.documentId);
        expect(coverMimeType, 'image/png');
        receivedOriginal.addAll(await stream.expand((chunk) => chunk).toList());
        receivedCover.addAll(await coverBytes!.expand((chunk) => chunk).toList());
      },
    );
    await receiving;
    await done;
    expect(receivedOriginal, bytes);
    expect(receivedCover, coverExpected);
  });

  test('temporary HTTP sync pairs, reads manifest and transfers selected artifact', () async {
    final bytes = utf8.encode('http artifact');
    final plugin = LanSyncPluginDescriptor(
      id: 'source.http',
      version: '1.0.0',
      bytes: bytes.length,
      artifactFormat: LanSyncPluginArtifactFormat.archive,
      checksum: lanSyncChecksum(bytes),
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
    final senderDone = sender.events.firstWhere((event) => event is LanSyncSenderDone);
    final importStarted = Completer<void>();
    final releaseImport = Completer<void>();
    final verificationProgress = <List<int>>[];
    final writeProgress = <List<int>>[];
    final receiving = receiver.receivePlugins(
      pluginIds: {plugin.id},
      importPlugin: (_, stream) async {
        received.addAll(await stream.expand((chunk) => chunk).toList());
        importStarted.complete();
        await releaseImport.future;
      },
      onVerificationProgress: (_, completed, total) => verificationProgress.add(<int>[completed, total]),
      onWriteProgress: (_, completed, total) => writeProgress.add(<int>[completed, total]),
    );
    await importStarted.future;
    await senderDone;
    releaseImport.complete();
    await receiving;
    expect(received, bytes);
    expect(verificationProgress.last, <int>[bytes.length, bytes.length]);
    expect(writeProgress.last, <int>[bytes.length, bytes.length]);
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
