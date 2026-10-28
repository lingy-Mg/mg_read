/// Device regression for live system routes in both Android Node backends.
/// An isolated test package and local CONNECT fixtures leave the user's VPN and
/// production app untouched. Injected route events exercise the app's real
/// connection provider and the Runtime's actual HTTP transport.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/network_proxy/application/flutter_network_proxy_manager.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const node = bool.fromEnvironment('MGREAD_TEST_ANDROID_NODE_PROCESS');
  testWidgets('proxy replacement recovers HTTP without restarting either backend', (tester) async {
    await const MethodChannel(
      'mgread_plugin_runtime/android_backend',
    ).invokeMethod<void>('select', {'backend': node ? 'nodeProcess' : 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
    // Verify the real platform stream initializes, independently of injected routes.
    final platform = await watchSystemProxyEnvironment().first.timeout(const Duration(seconds: 5));
    expect(platform['NO_PROXY'], contains('127.0.0.1'));
    final platformListener = watchSystemProxyEnvironment().listen((_) {});
    addTearDown(platformListener.cancel);
    expect((await watchSystemProxyEnvironment().first.timeout(const Duration(seconds: 5)))['NO_PROXY'], contains('127.0.0.1'));
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final dir = await Directory.systemTemp.createTemp('proxy-regression');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File(
      '${dir.path}/fixture.mgplugin.js',
    ).writeAsBytes(base64Decode(const String.fromEnvironment('MGREAD_TEST_ARTIFACT_BASE64')));
    await runtime.importLocalPluginForTesting(file.path);
    final first = await _proxy('first');
    final second = await _proxy('second');
    addTearDown(first.close);
    addTearDown(second.close);
    final routes = StreamController<Map<String, String>>();
    addTearDown(routes.close);
    final manager = FlutterNetworkProxyManager();
    final container = ProviderContainer(
      overrides: [
        pluginRuntimeFacadeProvider.overrideWithValue(runtime),
        configuredFlutterNetworkProxyManagerProvider.overrideWithValue(manager),
        systemProxyEnvironmentProvider.overrideWith((ref) => routes.stream),
      ],
    );
    addTearDown(container.dispose);
    final keepAlive = container.listen(pluginRuntimeConnectionProvider, (_, _) {}, fireImmediately: true);
    addTearDown(keepAlive.close);
    await container.read(pluginRuntimeConnectionProvider.future);
    Future<void> route(String? endpoint) async {
      final ready = Completer<void>();
      final subscription = container.listen(pluginRuntimeConnectionProvider, (_, state) {
        if (state.hasError && !ready.isCompleted) ready.completeError(state.error!, state.stackTrace!);
        if (!state.isLoading && state.hasValue && !ready.isCompleted) ready.complete();
      });
      routes.add({'HTTP_PROXY': ?endpoint, 'HTTPS_PROXY': ?endpoint});
      try {
        await ready.future.timeout(const Duration(seconds: 40));
      } finally {
        subscription.close();
      }
    }

    Future<String> fetch() async => (await runtime.invoke(
      const SourceSearchInvocation(pluginId: 'org.mgread.android-runtime-fixture', query: 'android-http-proxy', pageSize: 1),
    )).items.single.title;
    await route('http://127.0.0.1:${first.port}');
    expect(await fetch(), 'first');
    await first.close();
    await route('http://127.0.0.1:${second.port}');
    expect(await fetch(), 'second');
    manager.update(
      NetworkProxySettings(
        protocol: NetworkProxyProtocol.http,
        host: '127.0.0.1',
        port: second.port,
        enabled: const {NetworkProxyTraffic.sourceHttp: true},
      ),
    );
    await route('http://127.0.0.1:${first.port}');
    expect(await fetch(), 'second');
    await route(null);
    expect(await fetch(), 'second');
    expect((await runtime.invoke(const RuntimeStatusInvocation())).runtimeKind, node ? 'android-node-process' : 'android-javet');
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<ServerSocket> _proxy(String label) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    var pending = '';
    socket.listen((bytes) {
      pending += ascii.decode(bytes);
      while (pending.contains('\r\n\r\n')) {
        final end = pending.indexOf('\r\n\r\n') + 4;
        final request = pending.substring(0, end);
        pending = pending.substring(end);
        if (request.startsWith('CONNECT ')) {
          socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        } else {
          socket.write('HTTP/1.1 200 OK\r\nContent-Length: ${label.length}\r\nConnection: close\r\n\r\n$label');
          unawaited(socket.flush().then((_) => socket.close()));
        }
      }
    }, onError: (Object _) => socket.destroy());
  });
  return server;
}
