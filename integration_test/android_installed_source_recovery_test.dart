/// Explicit device acceptance for installed sources after a Runtime upgrade.
/// Uses existing data without imports or deletion. Only IDs supplied by the
/// runner may be re-enabled; a discovery ID must also be supplied explicitly.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('installed legacy sources load and recover on the selected Android host', (tester) async {
    const recoveryIds = String.fromEnvironment('MGREAD_TEST_RECOVER_SOURCE_IDS');
    const discoveryId = String.fromEnvironment('MGREAD_TEST_DISCOVERY_SOURCE_ID');
    expect(recoveryIds, isNotEmpty);
    expect(discoveryId, isNotEmpty);
    await AndroidNodeRuntimeSettings.instance.initialize();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final before = await runtime.invoke(const InstalledPluginsInvocation());
    final recovered = <String>[];
    for (final id in recoveryIds.split(',')) {
      final installed = before.singleWhere((source) => source.id == id);
      expect(installed.engine, PluginEngine.node);
      expect(installed.sourceUrl, isNull);
      if (installed.status == 'quarantined') {
        await runtime.invoke(SetPluginEnabledInvocation(pluginId: id, enabled: true));
      } else {
        expect(installed.status, 'active');
      }
      try {
        await runtime.invoke(SourceSearchSuggestionsInvocation(pluginId: id, pageSize: 1));
      } on PluginRuntimeException catch (error) {
        // Upstream errors are distinct from failure to load an installed module.
        expect(error.code, isNot(isIn(['plugin_not_found', 'plugin_load_failed', 'plugin_disabled'])));
        debugPrint('MGREAD_LEGACY_SOURCE_NETWORK id=$id code=${error.code}');
      }
      final after = await runtime.invoke(const InstalledPluginsInvocation());
      expect(after.singleWhere((source) => source.id == id).status, 'active');
      recovered.add(id);
      debugPrint('MGREAD_LEGACY_SOURCE_LOADED id=$id');
    }
    final discovery = await runtime.invoke(SourceDiscoverInvocation(pluginId: discoveryId, pageSize: 8));
    expect(discovery, isA<PluginDiscoveryDocumentResult>());
    final components = (discovery as PluginDiscoveryDocumentResult).document.components;
    expect(components, isNotEmpty);
    final status = await runtime.invoke(const RuntimeStatusInvocation());
    binding.reportData = {
      'runtimeKind': status.runtimeKind,
      'recoveredSources': recovered,
      'discoverySource': discoveryId,
      'discoveryComponents': components.length,
      'installedCount': before.length,
    };
    debugPrint(
      'MGREAD_LEGACY_SOURCE_RECOVERY_PASS backend=${status.runtimeKind} sources=${recovered.length} discoveryComponents=${components.length}',
    );
  }, timeout: const Timeout(Duration(minutes: 8)));
}
