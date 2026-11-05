/// Verifies app-wide TV orientation on startup, live toggles and root cleanup.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import 'package:mg_read/features/media/application/source_media_system_ui_controller.dart';

import 'mg_read_app_test_support.dart';

void main() {
  final orientationRequests = <Object?>[];
  final systemUiRequests = <Object?>[];
  const landscape = <String>['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'];

  setUp(() {
    orientationRequests.clear();
    systemUiRequests.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') orientationRequests.add(call.arguments);
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') systemUiRequests.add(call.arguments);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('saved TV mode locks landscape on a portrait tablet and releases on root disposal', (tester) async {
    tester.view.physicalSize = const Size(800, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, true);

    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    expect(orientationRequests, <Object?>[landscape]);
    expect(systemUiRequests, <Object?>['SystemUiMode.edgeToEdge']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(orientationRequests, <Object?>[landscape, <String>[]]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('live TV toggles lock landscape and restore the system orientation default', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    expect(orientationRequests, isEmpty);

    await settings.set(AppSettingKeys.tvMode, true);
    await tester.pumpAndSettle();
    await settings.set(AppSettingKeys.themeMode, 'light');
    await tester.pumpAndSettle();
    expect(orientationRequests, <Object?>[landscape]);

    await settings.set(AppSettingKeys.tvMode, false);
    await tester.pumpAndSettle();
    expect(orientationRequests, <Object?>[landscape, <String>[]]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media cleanup preserves the root TV landscape constraint', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, true);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    final media = SourceMediaSystemUiLease();
    await media.setMode(SourceMediaSystemUiMode.portraitImmersive);
    await media.releaseAndClose();
    expect(orientationRequests, <Object?>[landscape, landscape, landscape]);
    expect(systemUiRequests, <Object?>['SystemUiMode.edgeToEdge', 'SystemUiMode.immersiveSticky', 'SystemUiMode.edgeToEdge']);

    await settings.set(AppSettingKeys.tvMode, false);
    await tester.pumpAndSettle();
    expect(orientationRequests.last, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV root destinations keep navigation below a visible tablet status bar', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: 32, left: 24, right: 24, bottom: 16);
    tester.view.viewPadding = FakeViewPadding(top: 32, left: 24, right: 24, bottom: 16);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    const renderingChannel = MethodChannel('mgread/rendering_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      renderingChannel,
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(renderingChannel, null));
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, true);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final router = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell))).read(appRouterProvider);

    for (final route in ['/', '/discover', '/search', '/profile']) {
      router.go(route);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const Key('app-nav-home'))).top, greaterThanOrEqualTo(32), reason: route);
      expect(tester.takeException(), isNull, reason: route);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
