import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';

import '../../../core/diagnostics/diagnostics_testkit.dart';

void main() {
  test('source list waits for the shared Runtime readiness result', () async {
    final diagnostics = DiagnosticsTestkit();
    addTearDown(diagnostics.dispose);
    final readiness = Completer<PluginRuntimeConnection>();
    final container = ProviderContainer(
      overrides: [
        diagnosticsManagerProvider.overrideWithValue(diagnostics.manager),
        pluginRuntimeConnectionProvider.overrideWith((ref) => readiness.future),
      ],
    );
    addTearDown(container.dispose);

    var completed = false;
    final sources = container
        .read(sourceContentGatewayProvider)
        .listSources()
        .then((value) {
          completed = true;
          return value;
        });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    readiness.complete(
      const PluginRuntimeConnection(
        isHealthy: true,
        nodeVersion: '24.16.0',
        runtimeVersion: '0.2.0-standard.1',
        plugins: <PluginRuntimePlugin>[
          PluginRuntimePlugin(
            activeVersion: '1.0.0',
            contentKinds: <String>['novel'],
            displayName: '已就绪书源',
            enabled: true,
            id: 'org.example.ready',
            name: 'ready',
            pendingVersion: null,
            status: 'active',
          ),
          PluginRuntimePlugin(
            activeVersion: null,
            contentKinds: <String>['manga'],
            displayName: '未激活书源',
            enabled: true,
            id: 'org.example.pending',
            name: 'pending',
            pendingVersion: '1.0.0',
            status: 'pendingActivation',
          ),
        ],
      ),
    );

    expect(await sources, hasLength(1));
    expect((await sources).single.id, 'org.example.ready');
  });
}
