/// Device regression for Javet Core instantiation and shared streamed imports.
/// Run in an isolated MGREAD_APPLICATION_ID_SUFFIX app with a bundled fixture
/// supplied through MGREAD_TEST_ARTIFACT_BASE64; never clears production data.
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const encoded = String.fromEnvironment('MGREAD_TEST_ARTIFACT_BASE64');
  const pluginId = 'org.mgread.android-runtime-fixture';

  setUpAll(() async {
    await const MethodChannel('mgread_plugin_runtime/android_backend').invokeMethod<void>('select', {'backend': 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
  });

  testWidgets('Javet cold startup and two import Core restarts remain healthy', (tester) async {
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
    expect((await runtime.invoke(const RuntimeStatusInvocation())).runtimeKind, 'android-javet');

    for (var index = 0; index < 2; index++) {
      final imported = await runtime.importPluginArtifacts(
        [(artifact: artifact, bytes: Stream.value(bytes))],
        forceUpgradePluginIds: {pluginId},
      );
      expect(imported.single.status, PluginTransferImportStatus.installed);
      final search = await runtime.invoke(const SourceSearchInvocation(pluginId: pluginId, query: 'javet-recovery', pageSize: 1));
      expect(search.items.single.title, 'fixture:javet-recovery');
      expect((await runtime.invoke(const RuntimePingInvocation())).isHealthy, isTrue);
    }
    binding.reportData = {'runtimeKind': 'android-javet', 'coldStartHealthy': true, 'completedImports': 2, 'searchHealthy': true};
  }, timeout: const Timeout(Duration(minutes: 3)));
}
