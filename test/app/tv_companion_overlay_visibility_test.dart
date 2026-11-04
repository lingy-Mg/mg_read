/// TV companion stays in settings instead of floating over application routes.
/// Exercises both settings entries with the production navigator and isolated ports.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_page.dart';

import 'mg_read_app_test_support.dart';

void main() {
  const renderingChannel = MethodChannel('mgread/rendering_settings');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      renderingChannel,
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(renderingChannel, null);
  });

  for (final tvMode in [false, true]) {
    testWidgets('companion opens from settings without a floating entry with TV=$tvMode', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = await createTestAppSettings();
      addTearDown(settings.close);
      await settings.set(AppSettingKeys.tvMode, tvMode);
      await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
      await tester.pumpWidget(testMgReadApp(settings));
      await tester.pumpAndSettle();
      _expectNoFloatingEntry();

      final navigator = appRootNavigatorKey.currentState!;
      final dialog = showDialog<void>(
        context: navigator.context,
        builder: (_) => const AlertDialog(
          title: Text('筛选'),
          actions: [TextButton(onPressed: null, child: Text('完成'))],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      _expectNoFloatingEntry();
      navigator.pop();
      await tester.pumpAndSettle();
      await dialog;
      _expectNoFloatingEntry();

      final child = navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('设置子页面'))));
      await tester.pumpAndSettle();
      expect(find.text('设置子页面'), findsOneWidget);
      _expectNoFloatingEntry();
      navigator.pop();
      await tester.pumpAndSettle();
      await child;
      _expectNoFloatingEntry();

      const ProfileRoute().go(navigator.context);
      await tester.pumpAndSettle();
      final entry = find.byKey(Key(tvMode ? 'tv-setting-tv-companion' : 'profile-setting-tv-companion'));
      if (tvMode) {
        await tester.tap(find.byKey(const Key('tv-settings-section-3')));
      } else {
        await tester.drag(find.byKey(const Key('profile-page-content')), const Offset(0, -450));
      }
      await tester.pumpAndSettle();
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(find.text('手机辅助 TV'), findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(CompanionPage), findsOneWidget);
      expect(find.text(tvMode ? 'TV 接收状态' : '发现 TV'), findsOneWidget);
      _expectNoFloatingEntry();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(CompanionPage), findsNothing);
      _expectNoFloatingEntry();
      expect(tester.takeException(), isNull);
    });
  }
}

void _expectNoFloatingEntry() {
  expect(find.widgetWithText(FilledButton, '连接 TV'), findsNothing);
  expect(find.widgetWithText(FilledButton, '手机连接'), findsNothing);
}
