import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_general_setting_page.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  for (final (String settingId, String goldenName) in <(String, String)>[
    ('reading-settings', 'reading_settings_compact_light.png'),
    ('theme-appearance', 'appearance_settings_compact_light.png'),
    ('privacy-permissions', 'privacy_settings_compact_light.png'),
  ]) {
    testWidgets('matches $settingId compact light reference', (WidgetTester tester) async {
      final AppSettingsManager settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
      await settings.initialize();
      addTearDown(settings.close);
      await _setViewport(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsProvider.overrideWithValue(settings)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            home: ProfileGeneralSettingPage(settingId: settingId, onBackRequested: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$goldenName'));
    });
  }
}

Future<void> _setViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(AppDetailMetrics.viewportWidth, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
