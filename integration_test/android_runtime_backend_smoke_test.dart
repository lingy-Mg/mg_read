/// Android backend process and version smoke test.
///
/// Both hosts ship in one APK. The test-only define seeds the same persisted
/// preference as the settings page before the process selects its backend.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const nodeProcess = bool.fromEnvironment('MGREAD_TEST_ANDROID_NODE_PROCESS');

  setUpAll(() async {
    await const MethodChannel(
      'mgread_plugin_runtime/android_backend',
    ).invokeMethod<void>('select', {'backend': nodeProcess ? 'nodeProcess' : 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
  });

  testWidgets('selected Android backend starts and answers Core requests', (tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    expect(ping.nodeVersion, nodeProcess ? '24.21.0' : '26.9.0');

    final status = await runtime.invoke(const RuntimeStatusInvocation());
    expect(status.isHealthy, isTrue);
    expect(status.platform, 'android');
    expect(status.arch, nodeProcess ? 'arm64' : isNotEmpty);
    expect(status.runtimeKind, nodeProcess ? 'android-node-process' : 'android-javet');
  });
}
