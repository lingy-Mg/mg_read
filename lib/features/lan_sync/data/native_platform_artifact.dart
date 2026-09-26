/// Builds a small native source archive for the receiving platform at transfer
/// time. The installed portable archive remains intact so another platform can
/// be served later; only the selected target binaries cross the LAN.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_checksum.dart';
import 'package:mg_read/features/lan_sync/data/lan_sync_transport.dart';
import 'package:mg_read/features/lan_sync/domain/lan_sync_models.dart';

Future<LanSyncMaterializedPlugin> nativeArtifactForPlatform(LanSyncMaterializedPlugin source, String platform) async {
  final descriptor = source.descriptor;
  if (descriptor.engine != LanSyncPluginEngine.native) return source;
  if (platform != 'windows' && platform != 'android') {
    throw const LanSyncTransportException('lan_sync_plugin_platform_unavailable');
  }
  final input = BytesBuilder(copy: false);
  await for (final chunk in source.bytes) {
    input.add(chunk);
    if (input.length > descriptor.bytes) {
      throw const LanSyncTransportException('lan_sync_plugin_size_mismatch');
    }
  }
  final original = input.takeBytes();
  if (original.length != descriptor.bytes || lanSyncChecksum(original) != descriptor.checksum) {
    throw const LanSyncTransportException('lan_sync_plugin_hash_mismatch');
  }

  try {
    final archive = ZipDecoder().decodeBytes(original, verify: true);
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) throw const FormatException('native_manifest_missing');
    final manifest = jsonDecode(utf8.decode(manifestFile.content));
    if (manifest is! Map<String, dynamic> || manifest['engine'] != 'native' || manifest['format'] != 'mgread-native') {
      throw const FormatException('native_manifest_invalid');
    }
    final allTargets = manifest['targets'];
    if (allTargets is! Map<String, dynamic>) throw const FormatException('native_targets_invalid');
    final selected = <String, dynamic>{};
    final output = Archive();
    for (final entry in allTargets.entries) {
      if (!entry.key.startsWith('$platform-')) continue;
      final target = entry.value;
      if (target is! Map<String, dynamic> || target['path'] is! String || target['sha256'] is! String) {
        throw const FormatException('native_target_invalid');
      }
      final path = target['path'] as String;
      final file = archive.findFile(path);
      if (file == null || sha256.convert(file.content).toString() != target['sha256']) {
        throw const FormatException('native_target_checksum_invalid');
      }
      selected[entry.key] = target;
    }
    if (selected.isEmpty) throw const LanSyncTransportException('lan_sync_plugin_platform_unavailable');
    if (selected.length == allTargets.length) {
      return LanSyncMaterializedPlugin(descriptor: descriptor, bytes: Stream<List<int>>.value(original));
    }
    manifest['targets'] = selected;
    output.add(ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))));
    for (final target in selected.values) {
      final path = target['path'] as String;
      output.add(ArchiveFile.bytes(path, archive.findFile(path)!.content));
    }
    final bytes = ZipEncoder().encodeBytes(output, level: DeflateLevel.bestCompression, modified: DateTime.utc(1980));
    return LanSyncMaterializedPlugin(
      descriptor: LanSyncPluginDescriptor(
        id: descriptor.id,
        version: descriptor.version,
        bytes: bytes.length,
        artifactFormat: descriptor.artifactFormat,
        checksum: lanSyncChecksum(bytes),
        transferable: descriptor.transferable,
        deferred: false,
        developmentFingerprint: descriptor.developmentFingerprint,
        developmentRevision: descriptor.developmentRevision,
        displayName: descriptor.displayName,
        provenance: descriptor.provenance,
        engine: descriptor.engine,
        reason: descriptor.reason,
      ),
      bytes: Stream<List<int>>.value(bytes),
    );
  } on LanSyncTransportException {
    rethrow;
  } on Object catch (error) {
    throw LanSyncTransportException('lan_sync_plugin_archive_invalid', reason: error.toString());
  }
}
