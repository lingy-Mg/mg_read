import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android Runtime starts and exposes bundled plugins', (
    WidgetTester tester,
  ) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final facadeDiagnostics = <RuntimeDiagnostic>[];
    final diagnosticSubscription = runtime.diagnostics.listen(
      facadeDiagnostics.add,
    );
    addTearDown(diagnosticSubscription.cancel);
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    expect(ping.nodeVersion, isNotEmpty);

    final plugins = await runtime.invoke(const InstalledPluginsInvocation());
    final aisishuwu = plugins.singleWhere(
      (plugin) => plugin.id == 'org.mgread.aisishuwu',
    );
    expect(aisishuwu.status, 'active');

    final discovery = await runtime.invoke(
      const SourceDiscoverInvocation(
        pluginId: 'org.mgread.aisishuwu',
        pageSize: 20,
      ),
    );
    expect(discovery.sections, isNotEmpty);
    expect(discovery.sections.first.layout, PluginDiscoveryLayout.categories);
    expect(discovery.sections.first.categories, isNotEmpty);
    expect(
      facadeDiagnostics
          .where(
            (diagnostic) => diagnostic.code == 'runtime_facade_invoke_started',
          )
          .length,
      greaterThanOrEqualTo(2),
    );
    expect(
      facadeDiagnostics
          .where(
            (diagnostic) =>
                diagnostic.code == 'runtime_facade_invoke_completed',
          )
          .length,
      greaterThanOrEqualTo(2),
    );
  });
}
