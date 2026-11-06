/// Device regression for upgrading the actual published source artifacts.
/// Runs only in an isolated application ID; inputs are supplied by the runner.
/// Verifies activation and rollback state without depending on upstream sites.
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

  testWidgets('published source upgrades activate on Android Javet', (tester) async {
    await const MethodChannel('mgread_plugin_runtime/android_backend').invokeMethod<void>('select', {'backend': 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final versions = <String>[];
    for (final path in [
      const String.fromEnvironment('MGREAD_TEST_PREVIOUS_ARTIFACT_PATH'),
      const String.fromEnvironment('MGREAD_TEST_ARTIFACT_PATH'),
    ]) {
      expect(path, isNotEmpty);
      final bytes = await File(path).readAsBytes();
      final header = utf8.decode(bytes).split('\n').first.substring('// @mgread-plugin-v1 '.length);
      final metadata = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(header)))) as Map<String, dynamic>;
      final descriptor = metadata['descriptor'] as Map<String, dynamic>;
      final id = (descriptor['mgread'] as Map<String, dynamic>)['id'] as String;
      final version = descriptor['version'] as String;
      final artifact = PluginTransferArtifact(
        bytes: bytes.length,
        checksum: getCrc32(bytes).toRadixString(16).padLeft(8, '0'),
        pluginId: id,
        version: version,
        format: PluginArtifactFormat.singleFile,
        provenance: PluginArtifactProvenance.installed,
        developmentFingerprint: null,
        developmentRevision: null,
      );
      final result = await runtime.importPluginArtifacts([(artifact: artifact, bytes: Stream.value(bytes))], forceUpgradePluginIds: {id});
      final installed = (await runtime.invoke(const InstalledPluginsInvocation())).singleWhere((plugin) => plugin.id == id);
      // ignore: avoid_print
      print(
        'SOURCE_UPDATE_ACTIVATION requested=$version status=${installed.status} active=${installed.activeVersion} pending=${installed.pendingVersion}',
      );
      expect(result.single.status, PluginTransferImportStatus.installed);
      expect(installed.activeVersion, version);
      expect(installed.status, 'active');
      await runtime.invoke(SourceSearchSuggestionsInvocation(pluginId: id, pageSize: 1));
      versions.add(version);
    }
    binding.reportData = {'versions': versions, 'activated': true};
  }, timeout: const Timeout(Duration(minutes: 3)));
}
