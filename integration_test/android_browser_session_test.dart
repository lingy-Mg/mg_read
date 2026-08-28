/// Android packaged-artifact acceptance for the host-owned browser session.
///
/// This test uses a self-owned HTTPS fixture endpoint and never automates a
/// third-party challenge. The visible HTTP case only verifies that the host can
/// complete its normal browser preparation before the direct HTTP request.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android WebView session supports same-origin fetch and HTTP', (
    WidgetTester tester,
  ) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);

    final webview = await runtime.invoke(const SourceSearchInvocation(
      pluginId: 'org.mgread.browser-session-fixture',
      query: 'android-webview',
    ));
    expect(webview.items.single.title, 'webview:200:not-required');

    final http = await runtime.invoke(const SourceSearchInvocation(
      pluginId: 'org.mgread.browser-session-fixture',
      query: 'android-http',
    ));
    expect(http.items.single.title, 'http:200:verified');
  });
}
