/// Confirms one production Android Facade can run Node and native sources.
/// Test packages are staged in unique app-private inbox paths by the runner.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const nodePath = String.fromEnvironment('MGREAD_TEST_NODE_IMPORT_PATH');
  const nativePath = String.fromEnvironment('MGREAD_TEST_NATIVE_IMPORT_PATH');
  const nodeId = 'org.mgread.android-runtime-fixture';
  const nativeId = 'org.mgread.aisishuwu.native';

  testWidgets('one Android App runs both source engines', (tester) async {
    await tester.pump();
    expect(nodePath, isNotEmpty);
    expect(nativePath, isNotEmpty);
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    expect(runtime.supportsNativeSources, isTrue);

    await runtime.importLocalPluginForTesting(nodePath);
    await runtime.importLocalPluginForTesting(nativePath);

    final status = await runtime.invoke(const RuntimeStatusInvocation());
    expect(status.runtimeKind, 'android-javet');
    expect(status.nativeStatus?.runtimeKind, 'native-rust');
    expect(status.isHealthy, isTrue);
    expect(status.nativeStatus?.isHealthy, isTrue);

    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    expect(installed.singleWhere((item) => item.id == nodeId).engine, PluginEngine.node);
    expect(installed.singleWhere((item) => item.id == nativeId).engine, PluginEngine.native);

    final nodeSearch = await runtime.invoke(const SourceSearchInvocation(pluginId: nodeId, query: 'hybrid', pageSize: 1));
    expect(nodeSearch.items.single.title, 'fixture:hybrid');
    final nativeCache = await runtime.invoke(const PluginCacheUsageInvocation(pluginId: nativeId));
    final transfers = await runtime.invoke(const PluginTransferListInvocation());
    expect(transfers.singleWhere((item) => item.pluginId == nativeId).engine, PluginEngine.native);

    binding.reportData = <String, Object?>{
      'nodeRuntime': status.runtimeKind,
      'nativeRuntime': status.nativeStatus?.runtimeKind,
      'nodeSource': nodeId,
      'nativeSource': nativeId,
      'nodeSearchCount': nodeSearch.items.length,
      'nativeCacheEntries': nativeCache.length,
      'nativeTransferListed': true,
    };
  });
}
