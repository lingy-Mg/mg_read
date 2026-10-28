/// Device regression for Android Core restarts and discovery after updates.
/// Run in an isolated MGREAD_APPLICATION_ID_SUFFIX app with a bundled fixture
/// supplied through MGREAD_TEST_ARTIFACT_BASE64; never clears production data.
/// MGREAD_TEST_DIRECT_IMPORTS=true enables the package's local-file test entry.
/// MGREAD_TEST_ANDROID_NODE_PROCESS selects the optional arm64 Node service.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const encoded = String.fromEnvironment('MGREAD_TEST_ARTIFACT_BASE64');
  const pluginId = 'org.mgread.android-runtime-fixture';
  const nodeProcess = bool.fromEnvironment('MGREAD_TEST_ANDROID_NODE_PROCESS');
  const runtimeKind = nodeProcess ? 'android-node-process' : 'android-javet';

  setUpAll(() async {
    await const MethodChannel(
      'mgread_plugin_runtime/android_backend',
    ).invokeMethod<void>('select', {'backend': nodeProcess ? 'nodeProcess' : 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
  });

  testWidgets('Android local and streamed updates leave discovery callable', (tester) async {
    await tester.pump();
    expect(encoded, isNotEmpty);
    final bytes = base64Decode(encoded);
    final artifact = PluginTransferArtifact(
      bytes: bytes.length,
      checksum: getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
      pluginId: pluginId,
      version: '1.0.0',
      format: PluginArtifactFormat.singleFile,
      provenance: PluginArtifactProvenance.installed,
      developmentFingerprint: null,
      developmentRevision: null,
    );
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    await runtime.configurePluginHttpProxy(null);
    expect((await runtime.invoke(const RuntimePingInvocation())).isHealthy, isTrue);
    expect((await runtime.invoke(const RuntimeStatusInvocation())).runtimeKind, runtimeKind);

    final directory = await Directory.systemTemp.createTemp('mgread-import-regression-');
    addTearDown(() => directory.delete(recursive: true));
    final local = await File('${directory.path}/fixture.mgplugin.js').writeAsBytes(bytes);
    await runtime.importLocalPluginForTesting(local.path);
    expect(await runtime.invoke(const SourceDiscoverInvocation(pluginId: pluginId)), isA<PluginDiscoveryDocumentResult>());

    for (var index = 0; index < 2; index++) {
      final imported = await runtime.importPluginArtifacts(
        [(artifact: artifact, bytes: Stream.value(bytes))],
        forceUpgradePluginIds: {pluginId},
      );
      expect(imported.single.status, PluginTransferImportStatus.installed);
      expect(await runtime.invoke(const SourceDiscoverInvocation(pluginId: pluginId)), isA<PluginDiscoveryDocumentResult>());
      final search = await runtime.invoke(const SourceSearchInvocation(pluginId: pluginId, query: 'javet-recovery', pageSize: 1));
      expect(search.items.single.title, 'fixture:javet-recovery');
      expect((await runtime.invoke(const RuntimePingInvocation())).isHealthy, isTrue);
    }
    binding.reportData = {
      'runtimeKind': runtimeKind,
      'coldStartHealthy': true,
      'completedImports': 3,
      'discoveryHealthy': true,
      'searchHealthy': true,
    };
  }, timeout: const Timeout(Duration(minutes: 3)));
}
