/// Real desktop Node imports verify one restart, >32 sources and activation failures.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

void main() {
  test('40 streamed sources activate in one desktop restart', () async {
    final fixture = await _batch(40);
    final runtime = fixture.runtime;
    final started = Stopwatch()..start();
    final result = await runtime.importPluginArtifacts(fixture.artifacts);
    expect(result, hasLength(40));
    expect(
      result.every(
        (item) => item.status == PluginTransferImportStatus.installed,
      ),
      isTrue,
    );
    expect(runtime.debugDesktopProcessStartCount, 2);
    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    expect(installed, hasLength(40));
    expect(
      installed.every(
        (item) => item.status == 'active' && item.pendingVersion == null,
      ),
      isTrue,
    );
    final search = await runtime.invoke(
      SourceSearchInvocation(pluginId: installed.first.id, query: 'ready'),
    );
    expect(search.items, isEmpty);
    // This is a fixture measurement, not a LAN/device throughput benchmark.
    // ignore: avoid_print
    print(
      '40-source desktop Facade transfer + restart: ${started.elapsedMilliseconds} ms',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'a quarantined candidate is returned as failed after the restart',
    () async {
      final fixture = await _batch(
        1,
        activation: 'throw new Error("activation failed");',
      );
      final result = await fixture.runtime.importPluginArtifacts(
        fixture.artifacts,
      );
      expect(result.single.status, PluginTransferImportStatus.failed);
      final installed = await fixture.runtime.invoke(
        const InstalledPluginsInvocation(),
      );
      expect(installed.single.status, 'quarantined');
      expect(fixture.runtime.debugDesktopProcessStartCount, 2);
    },
  );

  test(
    'failed forced replacement cannot masquerade as the same active version',
    () async {
      final original = await _batch(1);
      expect(
        (await original.runtime.importPluginArtifacts(
          original.artifacts,
        )).single.status,
        PluginTransferImportStatus.installed,
      );
      final replacement = await _batch(
        1,
        activation: 'throw new Error("replacement failed");',
      );
      final result = await original.runtime.importPluginArtifacts(
        replacement.artifacts,
        forceUpgradePluginIds: {replacement.artifacts.single.artifact.pluginId},
      );
      expect(result.single.status, PluginTransferImportStatus.failed);
      expect(
        (await original.runtime.invoke(
          const InstalledPluginsInvocation(),
        )).single.status,
        'quarantined',
      );
    },
  );
}

typedef _Artifact = ({
  PluginTransferArtifact artifact,
  Stream<List<int>> bytes,
});

Future<({PluginRuntime runtime, List<_Artifact> artifacts})> _batch(
  int count, {
  String activation = '',
}) async {
  final root = await Directory.systemTemp.createTemp('mgread-facade-batch-');
  final repository = nodeRuntimeRepositoryRoot;
  final node = File.fromUri(
    repository.uri.resolve(
      Platform.isMacOS
          ? 'tools/node-v26.10.0-darwin-arm64/bin/node'
          : 'tools/node-v26.10.0-win-x64/node.exe',
    ),
  );
  final runtime = PluginRuntime.desktopForTesting(
    runtimeRepositoryRoot: repository,
    runtimeDataRoot: Directory.fromUri(root.uri.resolve('runtime-data/')),
  );
  addTearDown(() async {
    await runtime.debugDispose();
    // Runtime versions are read-only; Node's force removal handles Windows
    // attributes for this test-owned temporary directory.
    final removed = await Process.run(node.path, <String>[
      '--input-type=module',
      '--eval',
      'import { rm } from "node:fs/promises"; await rm(process.argv[1], {recursive:true, force:true});',
      root.path,
    ]);
    expect(removed.exitCode, 0, reason: '${removed.stderr}');
  });
  final generated = await Process.run(node.path, <String>[
    File.fromUri(
      repository.uri.resolve('test/fixtures/transfer-batch.mjs'),
    ).path,
    root.path,
    '$count',
    activation,
  ]);
  expect(generated.exitCode, 0, reason: '${generated.stderr}');
  final records = jsonDecode(generated.stdout as String) as List<dynamic>;
  final artifacts = <_Artifact>[];
  for (final value in records) {
    final record = value as Map<String, dynamic>;
    final artifact = record['artifact'] as Map<String, dynamic>;
    artifacts.add((
      artifact: PluginTransferArtifact(
        bytes: artifact['bytes'] as int,
        checksum: artifact['checksum'] as String,
        pluginId: artifact['id'] as String,
        version: artifact['version'] as String,
        format: PluginArtifactFormat.singleFile,
        provenance: PluginArtifactProvenance.installed,
        developmentFingerprint: null,
        developmentRevision: null,
      ),
      bytes: File(record['path'] as String).openRead(),
    ));
  }
  return (runtime: runtime, artifacts: artifacts);
}
