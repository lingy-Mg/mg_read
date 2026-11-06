/// 外观页验证日夜配色、宽屏并排和书架分组的真实字体截图。
/// 这些基线只覆盖 Flutter 布局，不替代设备和物理遥控器验收。
library;

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

  for (final (name, size, dark, shelf) in <(String, Size, bool, bool)>[
    ('appearance_settings_compact_dark.png', const Size(390, 900), true, false),
    ('appearance_settings_wide_light.png', const Size(1280, 900), false, false),
    ('appearance_settings_shelf_light.png', const Size(390, 900), false, true),
  ]) {
    testWidgets('matches theme-appearance $name', (tester) async {
      final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
      await settings.initialize();
      addTearDown(settings.close);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsProvider.overrideWithValue(settings)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? AppTheme.dark() : AppTheme.light(),
            home: ProfileGeneralSettingPage(settingId: 'theme-appearance', onBackRequested: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (shelf) {
        await tester.ensureVisible(find.text('书架样式'));
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name'));
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
