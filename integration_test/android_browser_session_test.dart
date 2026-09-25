/// Android packaged-artifact acceptance for the host-owned WebView.
///
/// The fixture evaluates a local expression in the app process through the
/// published Source API, without relying on an external website.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android Source WebView executes in the host process', (WidgetTester tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);

    final webview = await runtime.invoke(
      const SourceSearchInvocation(pluginId: 'org.mgread.android-runtime-fixture', query: 'android-webview'),
    );
    expect(webview.items.single.title, 'webview:2');
  });
}
