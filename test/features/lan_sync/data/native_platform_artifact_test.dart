/// Verifies that native LAN artifacts contain only the receiver's libraries,
/// with a matching manifest and transfer checksum, including the QR HTTP path.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/data/native_platform_artifact.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

void main() {
  final windows = List<int>.filled(600, 1);
  final arm64 = List<int>.filled(700, 2);
  final androidX64 = List<int>.filled(800, 3);
  final binaries = <String, List<int>>{'windows-x86_64': windows, 'android-arm64-v8a': arm64, 'android-x86_64': androidX64};
  final paths = <String, String>{
    'windows-x86_64': 'native/windows-x86_64/source.dll',
    'android-arm64-v8a': 'native/android-arm64-v8a/libsource.so',
    'android-x86_64': 'native/android-x86_64/libsource.so',
  };
  final manifest = <String, Object?>{
    'format': 'mgread-native',
    'engine': 'native',
    'abi': 1,
    'id': 'source.native',
    'name': 'Native fixture',
    'version': '1.0.0',
    'description': '',
    'contentKinds': ['novel'],
    'capabilities': ['search'],
    'targets': {
      for (final entry in binaries.entries) entry.key: {'path': paths[entry.key], 'sha256': sha256.convert(entry.value).toString()},
    },
  };
  final package = Archive()..add(ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))));
  for (final entry in binaries.entries) {
    package.add(ArchiveFile.bytes(paths[entry.key]!, entry.value));
  }
  final original = ZipEncoder().encodeBytes(package);
  final descriptor = LanSyncPluginDescriptor(
    id: 'source.native',
    version: '1.0.0',
    bytes: original.length,
    artifactFormat: LanSyncPluginArtifactFormat.archive,
    checksum: lanSyncChecksum(original),
    transferable: true,
    engine: LanSyncPluginEngine.native,
  );

  for (final platform in ['windows', 'android']) {
    test('native $platform transfer contains only matching binaries', () async {
      final result = await nativeArtifactForPlatform(
        LanSyncMaterializedPlugin(descriptor: descriptor, bytes: Stream.value(original)),
        platform,
      );
      final bytes = await result.bytes.expand((chunk) => chunk).toList();
      final zip = ZipDecoder().decodeBytes(bytes, verify: true);
      final resultManifest = jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content)) as Map<String, dynamic>;
      final targets = resultManifest['targets'] as Map<String, dynamic>;
      expect(targets.keys, everyElement(startsWith('$platform-')));
      expect(targets.length, platform == 'windows' ? 1 : 2);
      expect(zip.length, targets.length + 1);
      expect(bytes.length, result.descriptor.bytes);
      expect(lanSyncChecksum(bytes), result.descriptor.checksum);
      expect(bytes.length, lessThan(original.length));
      final alreadyFiltered = await nativeArtifactForPlatform(
        LanSyncMaterializedPlugin(descriptor: result.descriptor, bytes: Stream.value(bytes)),
        platform,
      );
      expect(await alreadyFiltered.bytes.expand((chunk) => chunk).toList(), bytes);
    });
  }

  test('QR selection sends the receiving Windows archive', () async {
    final sender = await LanSyncSenderService.start(
      manifest: LanSyncManifest(plugins: [descriptor], shelfItems: const [], skippedShelfItems: 0),
      openPlugin: (_) async => Stream.value(original),
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
    await receiver.confirmAndReadManifest();
    LanSyncPluginDescriptor? prepared;
    List<int>? received;
    await receiver.receivePlugins(
      pluginIds: {descriptor.id},
      preparePlugins: (plugins) async => prepared = plugins.single,
      importPlugin: (plugin, stream) async {
        received = await stream.expand((chunk) => chunk).toList();
        expect(plugin.bytes, prepared!.bytes);
      },
    );
    final zip = ZipDecoder().decodeBytes(received!, verify: true);
    final resultManifest = jsonDecode(utf8.decode(zip.findFile('manifest.json')!.content)) as Map<String, dynamic>;
    expect((resultManifest['targets'] as Map<String, dynamic>).keys, ['windows-x86_64']);
    expect(prepared!.bytes, lessThan(descriptor.bytes));
  }, skip: !Platform.isWindows);
}
