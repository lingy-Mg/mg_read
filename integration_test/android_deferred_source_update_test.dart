/// Two-launch device acceptance for deferred source updates using real artifacts.
/// The runner uses an isolated application ID, stages the two private input files,
/// runs once, stops that test app, then runs the same APK again with its data.
/// The marker lives beside the private inputs; Android clears code_cache (the
/// Dart system-temp directory) when the driver reinstalls the same test APK.
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
  testWidgets('source updates stay deferred across Core restarts and activate on the next app launch', (tester) async {
    await const MethodChannel('mgread_plugin_runtime/android_backend').invokeMethod<void>('select', {'backend': 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
    final runtime = PluginRuntime();
    final previous = await _input(const String.fromEnvironment('MGREAD_TEST_PREVIOUS_ARTIFACT_PATH'));
    final next = await _input(const String.fromEnvironment('MGREAD_TEST_ARTIFACT_PATH'));
    final inputDirectory = File(const String.fromEnvironment('MGREAD_TEST_ARTIFACT_PATH')).parent;
    final marker = File('${inputDirectory.path}/mgread-deferred-source-update.json');
    Future<InstalledPlugin> installed() async =>
        (await runtime.invoke(const InstalledPluginsInvocation())).singleWhere((plugin) => plugin.id == next.artifact.pluginId);
    if (await marker.exists()) {
      final plugin = await installed();
      expect(plugin.activeVersion, next.artifact.version);
      expect(plugin.pendingVersion, isNull);
      expect(plugin.status, 'active');
      await runtime.invoke(SourceSearchSuggestionsInvocation(pluginId: plugin.id, pageSize: 1));
      await marker.delete();
      binding.reportData = {'phase': 'next-launch', 'activeVersion': plugin.activeVersion, 'activated': true};
      // ignore: avoid_print
      print('DEFERRED_SOURCE_UPDATE_NEXT_LAUNCH_PASS active=${plugin.activeVersion}');
      return;
    }
    await runtime.importPluginArtifacts([previous], forceUpgradePluginIds: {previous.artifact.pluginId});
    await runtime.stagePluginUpdates([next]);
    expect((await installed()).activeVersion, previous.artifact.version);
    await runtime.importPluginArtifacts(
      [await _input(const String.fromEnvironment('MGREAD_TEST_PREVIOUS_ARTIFACT_PATH'))],
      forceUpgradePluginIds: {previous.artifact.pluginId},
    );
    expect((await installed()).activeVersion, previous.artifact.version);
    await marker.writeAsString(jsonEncode({'version': next.artifact.version}), flush: true);
    binding.reportData = {'phase': 'staged', 'activeVersion': previous.artifact.version, 'stagedVersion': next.artifact.version};
    // ignore: avoid_print
    print('DEFERRED_SOURCE_UPDATE_STAGED_PASS active=${previous.artifact.version} staged=${next.artifact.version}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<({PluginTransferArtifact artifact, Stream<List<int>> bytes})> _input(String path) async {
  expect(path, isNotEmpty);
  final bytes = await File(path).readAsBytes();
  final header = utf8.decode(bytes).split('\n').first.substring('// @mgread-plugin-v1 '.length);
  final metadata = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(header)))) as Map<String, dynamic>;
  final descriptor = metadata['descriptor'] as Map<String, dynamic>;
  return (
    artifact: PluginTransferArtifact(
      bytes: bytes.length,
      checksum: getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
      pluginId: (descriptor['mgread'] as Map<String, dynamic>)['id'] as String,
      version: descriptor['version'] as String,
      format: PluginArtifactFormat.singleFile,
      provenance: PluginArtifactProvenance.installed,
      developmentFingerprint: null,
      developmentRevision: null,
    ),
    bytes: Stream.value(bytes),
  );
}
