/// Covers legacy Facade decoding and the management page's production projection.
library;

import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mgread_plugin_runtime/android');
  const progress = MethodChannel('mgread_plugin_runtime/android/progress');

  for (final variant in ['missing', 'null', 'provided']) {
    test('inspect preserves $variant source homepage through the Facade', () async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(progress, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'dispose') return null;
        final method = (call.arguments as Map)['method'];
        final Object result = switch (method) {
          'runtime.ping' => {'ok': true, 'nodeVersion': '26.9.0', 'runtimeVersion': 'fixture'},
          'plugins.recovery.consume.v1' => {'quarantinedCount': 0},
          'plugins.list.v1' => [
            {
              'id': 'org.test.legacy',
              'name': 'legacy',
              'displayName': 'Legacy',
              'activeVersion': '1.0.0',
              'pendingVersion': null,
              'enabled': true,
              'status': 'active',
              'iconUrl': null,
              'contentKinds': ['novel'],
              if (variant != 'missing') 'sourceUrl': variant == 'null' ? null : 'https://source.example/',
            },
          ],
          _ => throw StateError('Unexpected Runtime method: $method'),
        };
        return jsonEncode({'ok': true, 'result': result});
      });
      final runtime = PluginRuntime.androidForTesting();
      addTearDown(() async {
        await runtime.debugDispose();
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(progress, null);
      });
      final connection = await MgReadPluginRuntimeGateway(runtime: runtime).inspect();
      expect(connection.isHealthy, isTrue);
      expect(connection.plugins.single.sourceUrl, variant == 'provided' ? 'https://source.example/' : null);
      expect(connection.plugins.single.enabled, isTrue);
    });
  }
}
