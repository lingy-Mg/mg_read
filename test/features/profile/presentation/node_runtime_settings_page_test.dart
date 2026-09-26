/// Verifies deferred activation, persistence failures and restart interaction.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_restart.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/node_runtime_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mgread_plugin_runtime/android_backend');
  late String persisted;
  late bool supported;
  late bool failSave;
  late bool failRestart;
  late int restarts;
  late AndroidNodeRuntimeSettings settings;

  setUp(() {
    persisted = 'javet';
    supported = true;
    failSave = false;
    failRestart = false;
    restarts = 0;
    settings = AndroidNodeRuntimeSettings();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read') return {'selected': persisted, 'supportsNodeProcess': supported};
      if (failSave) throw PlatformException(code: 'backend_save_failed');
      persisted = (call.arguments as Map)['backend'] as String;
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  Future<void> mount(WidgetTester tester) async {
    await settings.initialize();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          androidNodeRuntimeSettingsProvider.overrideWithValue(settings),
          appRestartProvider.overrideWithValue(() async {
            restarts++;
            if (failRestart) throw StateError('restart failed');
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NodeRuntimeSettingsPage(onBackRequested: () {}),
        ),
      ),
    );
  }

  testWidgets('save prompts, later keeps active host, next cold start restores selection', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('node-runtime-nodeProcess')));
    await tester.pumpAndSettle();
    expect(find.text('重启后生效'), findsOneWidget);
    expect(persisted, 'nodeProcess');
    expect(settings.active, AndroidNodeBackend.javet);
    await tester.tap(find.text('稍后重启'));
    await tester.pumpAndSettle();
    expect(restarts, 0);
    expect(find.byKey(const Key('node-runtime-pending')), findsOneWidget);
    await settings.initialize();
    expect(settings.active, AndroidNodeBackend.javet);
    final nextProcess = AndroidNodeRuntimeSettings();
    await nextProcess.initialize();
    expect(nextProcess.active, AndroidNodeBackend.nodeProcess);
    expect(nextProcess.restartRequired, isFalse);
    await nextProcess.select(AndroidNodeBackend.javet);
    final thirdProcess = AndroidNodeRuntimeSettings();
    await thirdProcess.initialize();
    expect(thirdProcess.active, AndroidNodeBackend.javet);
  });

  testWidgets('immediate restart is explicit and save precedes it', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('node-runtime-nodeProcess')));
    await tester.pumpAndSettle();
    expect(restarts, 0);
    await tester.tap(find.widgetWithText(FilledButton, '立即重启').last);
    await tester.pump();
    expect(restarts, 1);
    expect(persisted, 'nodeProcess');
  });

  testWidgets('selecting active host cancels pending switch and same choice does nothing', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('node-runtime-javet')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byKey(const Key('node-runtime-nodeProcess')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后重启'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('node-runtime-javet')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node-runtime-pending')), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(persisted, 'javet');
  });

  testWidgets('failed persistence does not prompt or change selection', (tester) async {
    failSave = true;
    await mount(tester);
    await tester.tap(find.byKey(const Key('node-runtime-nodeProcess')));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试。'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(settings.selected, AndroidNodeBackend.javet);
    expect(restarts, 0);
  });

  testWidgets('unsupported device disables Node process and recovers stale preference', (tester) async {
    supported = false;
    persisted = 'nodeProcess';
    await mount(tester);
    expect(settings.active, AndroidNodeBackend.javet);
    expect(tester.widget<ListTile>(find.byKey(const Key('node-runtime-nodeProcess'))).enabled, isFalse);
    await expectLater(settings.select(AndroidNodeBackend.nodeProcess), throwsUnsupportedError);
  });

  testWidgets('restart failure keeps saved choice and offers retry', (tester) async {
    failRestart = true;
    await mount(tester);
    await tester.tap(find.byKey(const Key('node-runtime-nodeProcess')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '立即重启').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('node-runtime-error')), findsOneWidget);
    expect(settings.restartRequired, isTrue);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '立即重启')).onPressed, isNotNull);
  });
}
