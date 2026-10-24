/// Source-collection contract tests for ZIP validation and import selection.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/plugins/application/plugin_runtime_models.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';

void main() {
  test('parses single-file and archive Node entries and creates Runtime descriptors', () async {
    final bytes = _collection(<_Entry>[
      _Entry(id: 'org.example.a', version: '1.2.3', name: '来源 A', format: 'singleFile', content: utf8.encode('export default {};')),
      _Entry(id: 'org.example.b', version: '2.0.0', name: '来源 B', format: 'archive', content: utf8.encode('zip bytes')),
    ]);

    final parsed = parseSourceCollection(bytes);

    expect(parsed.plugins, hasLength(2));
    expect(parsed.plugins[0].artifact.format, PluginArtifactFormat.singleFile);
    expect(parsed.plugins[1].artifact.format, PluginArtifactFormat.archive);
    expect(parsed.plugins[0].artifact.engine, PluginEngine.node);
    expect(parsed.plugins[0].artifact.checksum, matches(RegExp(r'^[a-f0-9]{8}$')));
    expect(parsed.plugins[0].artifact.bytes, parsed.plugins[0].byteLength);
    expect(await parsed.plugins[0].openBytes().expand((chunk) => chunk).toList(), utf8.encode('export default {};'));
  });

  test('accepts an optional empty plugins directory entry', () {
    final parsed = parseSourceCollection(_collection(<_Entry>[_Entry(id: 'org.example.a')], includePluginsDirectory: true));
    expect(parsed.plugins, hasLength(1));
  });

  test('rejects path mismatch, duplicate IDs and SHA-256 mismatch', () {
    expect(
      () => parseSourceCollection(_collection(<_Entry>[_Entry(id: 'org.example.a', pathOverride: 'plugins/../escape.mgplugin.js')])),
      throwsA(isA<SourceCollectionImportException>()),
    );
    expect(
      () => parseSourceCollection(_collection(<_Entry>[_Entry(id: 'org.example.a'), _Entry(id: 'org.example.a', version: '2.0.0')])),
      throwsA(isA<SourceCollectionImportException>()),
    );
    expect(
      () => parseSourceCollection(_collection(<_Entry>[_Entry(id: 'org.example.a', shaOverride: List<String>.filled(64, '0').join())])),
      throwsA(isA<SourceCollectionImportException>()),
    );
  });

  test('prechecks entry count before reading payloads', () {
    final archive = Archive();
    archive.addFile(ArchiveFile.bytes('manifest.json', utf8.encode('{}')));
    for (var index = 0; index <= sourceCollectionMaxPlugins + 1; index++) {
      archive.addFile(ArchiveFile.bytes('extra-$index', <int>[1]));
    }
    final zipped = ZipEncoder().encodeBytes(archive);

    expect(() => parseSourceCollection(zipped), throwsA(isA<SourceCollectionImportException>()));
  });

  test('plan selection requires explicit replacement and blocks downgrades', () {
    final collection = SourceCollection(<SourceCollectionPlugin>[
      _plugin('org.example.new', '1.0.0'),
      _plugin('org.example.same', '1.0.0'),
      _plugin('org.example.upgrade', '2.0.0'),
      _plugin('org.example.downgrade', '1.0.0'),
    ]);
    final candidates = planSourceCollection(
      collection: collection,
      plan: <PluginTransferPlanItem>[
        _plan('org.example.new', '1.0.0', PluginTransferPlanAction.missing),
        _plan('org.example.same', '1.0.0', PluginTransferPlanAction.same, receiver: '1.0.0'),
        _plan('org.example.upgrade', '2.0.0', PluginTransferPlanAction.upgrade, receiver: '1.0.0'),
        _plan('org.example.downgrade', '1.0.0', PluginTransferPlanAction.receiverNewer, receiver: '2.0.0'),
      ],
      installed: <PluginRuntimePlugin>[
        _installed('org.example.same', '1.0.0'),
        _installed('org.example.upgrade', '1.0.0'),
        _installed('org.example.downgrade', '2.0.0'),
      ],
    );

    expect(candidates.map((item) => item.canImport), <bool>[true, true, true, false]);
    expect(sourceCollectionAvailableUpdates(candidates).map((item) => item.plugin.id), <String>['org.example.upgrade']);
    expect(sourceCollectionSelection(candidates, <String>{'org.example.new'}), isNotNull);
    expect(sourceCollectionSelection(candidates, <String>{'org.example.same'})!.forceUpgradePluginIds, <String>{'org.example.same'});
    expect(() => sourceCollectionSelection(candidates, <String>{'org.example.downgrade'}), throwsA(isA<SourceCollectionImportException>()));
  });
}

SourceCollectionPlugin _plugin(String id, String version) {
  final bytes = Uint8List.fromList(<int>[1, 2, 3]);
  return SourceCollectionPlugin(
    id: id,
    name: id,
    version: version,
    format: 'singleFile',
    byteLength: bytes.length,
    checksum: getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
    openBytes: () => Stream<List<int>>.value(bytes),
  );
}

PluginTransferPlanItem _plan(String id, String version, PluginTransferPlanAction action, {String? receiver}) =>
    PluginTransferPlanItem(action: action, pluginId: id, receiverVersion: receiver, version: version);

PluginRuntimePlugin _installed(String id, String version) => PluginRuntimePlugin(
  activeVersion: version,
  contentKinds: const <String>[],
  displayName: id,
  enabled: true,
  id: id,
  name: id,
  pendingVersion: null,
  status: 'active',
);

class _Entry {
  _Entry({
    required this.id,
    this.version = '1.0.0',
    this.name = '来源',
    this.format = 'singleFile',
    List<int>? content,
    this.pathOverride,
    this.shaOverride,
  }) : content = Uint8List.fromList(content ?? <int>[1, 2, 3]);

  final String id;
  final String version;
  final String name;
  final String format;
  final Uint8List content;
  final String? pathOverride;
  final String? shaOverride;
}

Uint8List _collection(List<_Entry> entries, {bool includePluginsDirectory = false}) {
  final zip = Archive();
  if (includePluginsDirectory) zip.addFile(ArchiveFile.directory('plugins/'));
  final rows = <Map<String, Object?>>[];
  for (final entry in entries) {
    final suffix = entry.format == 'archive' ? '.mgplugin' : '.mgplugin.js';
    final path = entry.pathOverride ?? 'plugins/${entry.id}-${entry.version}$suffix';
    zip.addFile(ArchiveFile.bytes(path, entry.content));
    rows.add(<String, Object?>{
      'id': entry.id,
      'name': entry.name,
      'version': entry.version,
      'format': entry.format,
      'path': path,
      'bytes': entry.content.length,
      'sha256': entry.shaOverride ?? sha256.convert(entry.content).toString(),
    });
  }
  zip.addFile(
    ArchiveFile.bytes(
      'manifest.json',
      utf8.encode(jsonEncode(<String, Object?>{'format': 'mgread-source-collection', 'schemaVersion': 1, 'plugins': rows})),
    ),
  );
  return Uint8List.fromList(ZipEncoder().encodeBytes(zip));
}
