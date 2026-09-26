/// Same-APK Android acceptance across three real process lifetimes.
/// Run only with a unique MGREAD_APPLICATION_ID_SUFFIX and fresh app data.
/// The settings page drives Javet -> Node process -> Javet; a flushed phase
/// file survives restart and emits a final marker to logcat for the host runner.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/node_runtime_settings_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings switch both Node hosts through a full app restart', (tester) async {
    const suffix = String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX');
    expect(suffix, isNotEmpty, reason: 'Never run restart acceptance in the normal installed app');
    final phaseFile = File('${(await getApplicationSupportDirectory()).path}/node-switch-phase.txt');
    final phase = await phaseFile.exists() ? int.parse(await phaseFile.readAsString()) : 0;
    expect(phase, inInclusiveRange(0, 2));
    await AndroidNodeRuntimeSettings.instance.initialize();
    final expected = phase == 1 ? AndroidNodeBackend.nodeProcess : AndroidNodeBackend.javet;
    expect(AndroidNodeRuntimeSettings.instance.active, expected);
    expect(AndroidNodeRuntimeSettings.instance.supportsNodeProcess, isTrue);
    final runtime = PluginRuntime();
    final status = await runtime.invoke(const RuntimeStatusInvocation());
    expect(status.isHealthy, isTrue);
    expect(status.runtimeKind, phase == 1 ? 'android-node-process' : 'android-javet');
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    debugPrint('MGREAD_NODE_SWITCH phase=$phase pid=$pid backend=${status.runtimeKind} healthy=true');
    if (phase == 2) {
      debugPrint('MGREAD_NODE_SWITCH_ROUNDTRIP_PASS');
      return;
    }

    await bootstrapMgReadApp(
      child: RepaintBoundary(
        key: const Key('node-switch-capture'),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NodeRuntimeSettingsPage(onBackRequested: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('node-switch-capture')));
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${phaseFile.parent.path}/node-switch-$name-$phase.png').writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      image.dispose();
    }

    await capture('page');
    final nextBackend = phase == 0 ? AndroidNodeBackend.nodeProcess : AndroidNodeBackend.javet;
    await tester.tap(find.byKey(Key('node-runtime-${nextBackend.name}')));
    await tester.pumpAndSettle();
    expect(find.text('重启后生效'), findsOneWidget);
    await capture('dialog');
    expect(AndroidNodeRuntimeSettings.instance.active, expected);
    expect(AndroidNodeRuntimeSettings.instance.selected, nextBackend);
    await phaseFile.writeAsString('${phase + 1}', flush: true);
    await tester.tap(find.widgetWithText(FilledButton, '立即重启').last);
    // This process must disappear; completing the wait is a failed restart.
    await tester.pump(const Duration(seconds: 15));
    fail('App did not restart after confirming the backend change');
  });
}
