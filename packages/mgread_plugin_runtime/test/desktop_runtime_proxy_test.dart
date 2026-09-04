import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'test_paths.dart';

void main() {
  test(
    'plugin HTTP proxy is retained before startup and applied through the Runtime control plane',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
      );
      addTearDown(runtime.debugDispose);

      await runtime.configurePluginHttpProxy(Uri.parse('http://127.0.0.1:1'));
      final ping = await runtime.invoke(const RuntimePingInvocation());
      await runtime.configurePluginHttpProxy(null);

      expect(ping.isHealthy, isTrue);
      expect(runtime.debugDesktopProcessStartCount, 1);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'Node environment proxy preference restarts an already-running desktop Runtime',
    () async {
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
      );
      addTearDown(runtime.debugDispose);

      expect(
        (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
        isTrue,
      );
      expect(runtime.debugDesktopProcessStartCount, 1);

      await runtime.configureNodeEnvironmentProxy(true);
      expect(
        (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
        isTrue,
      );
      expect(runtime.debugDesktopProcessStartCount, 2);

      await runtime.configureNodeEnvironmentProxy(false);
      expect(
        (await runtime.invoke(const RuntimePingInvocation())).isHealthy,
        isTrue,
      );
      expect(runtime.debugDesktopProcessStartCount, 3);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
