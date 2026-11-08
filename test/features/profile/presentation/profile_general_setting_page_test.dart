/// 阅读和外观通用设置页测试。
///
/// 只验证页面展示与现有设置持久化，不替代阅读器或平台权限测试。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_general_setting_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('TV remote opens a category child and restores focus on return', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: TvModeScope(
              enabled: true,
              onChanged: (_) {},
              child: TvRemoteShortcuts(child: child!),
            ),
          ),
          home: ProfileGeneralSettingPage(settingId: 'reading-settings', onBackRequested: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('profile-setting-audio-settings'));
    final focus = tester.widget<Focus>(find.descendant(of: entry, matching: find.byType(Focus)).first).focusNode!;
    focus.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-general-setting-audio-settings')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-general-setting-reading-settings')), findsOneWidget);
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(entry.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reading category opens separate pages and returns without losing saved values', (tester) async {
    final settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'reading-settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-preload-count-increase')), findsNothing);
    expect(find.byKey(const Key('audio-exit-behavior-continue')), findsNothing);
    expect(find.byKey(const Key('source-auto-update-check')), findsNothing);
    await tester.tap(find.byKey(const Key('profile-setting-novel-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-general-setting-novel-settings')), findsOneWidget);
    expect(find.byKey(const Key('profile-video-settings')), findsNothing);
    await tester.tap(find.byKey(const Key('novel-preload-count-increase')));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.novelPreloadChapterCount), 2);
    final refresh = find.byKey(const Key('bookshelf-auto-catalog-refresh'));
    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.bookshelfCatalogAutoRefreshEnabled), isFalse);
    await tester.tap(find.byKey(const Key('secondary-placeholder-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-general-setting-reading-settings')), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-setting-audio-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('novel-preload-count-increase')), findsNothing);
    final scrollable = find.descendant(
      of: find.byKey(const Key('profile-general-setting-audio-settings')),
      matching: find.byType(Scrollable),
    );
    final continueBehavior = find.byKey(const Key('audio-exit-behavior-continue'));
    await tester.ensureVisible(continueBehavior);
    await tester.tap(continueBehavior);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.audioExitBehavior), 'continue');
    final square = find.byKey(const Key('audio-mini-player-style-square'));
    await tester.scrollUntilVisible(square, 200, scrollable: scrollable);
    await tester.tap(square);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.audioMiniPlayerStyle), 'square');
    final remember = find.byKey(const Key('profile-audio-remember-position'));
    await tester.scrollUntilVisible(remember, 200, scrollable: scrollable);
    await tester.tap(remember);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.audioRememberPosition), isFalse);
    expect(settings.get(AppSettingKeys.novelPreloadChapterCount), 2);
    expect(settings.get(AppSettingKeys.bookshelfCatalogRefreshIntervalHours), 24);
  });

  testWidgets('source updates live under data and storage and save independently', (tester) async {
    final settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'data-storage'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-auto-update-check')), findsNothing);
    await tester.tap(find.byKey(const Key('profile-setting-source-updates')));
    await tester.pumpAndSettle();
    final control = find.byKey(const Key('source-auto-update-check'));
    final before = settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled);
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.sourceAutoUpdateCheckEnabled), !before);
    expect(find.byKey(const Key('bookshelf-auto-catalog-refresh')), findsNothing);
  });

  testWidgets('appearance settings persists the real shelf layout preference', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'bookshelf-settings'));
    await tester.pumpAndSettle();

    expect(find.text('暖光视觉'), findsNothing);
    expect(find.byKey(const Key('appearance-theme-mode')), findsNothing);
    expect(find.byKey(const Key('appearance-theme-color-preview')), findsNothing);
    expect(find.byKey(const Key('appearance-tv-mode')), findsNothing);
    final Finder scrollable = find.descendant(
      of: find.byKey(const Key('profile-general-setting-bookshelf-settings')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('卡片'), 200, scrollable: scrollable);
    await tester.ensureVisible(find.byKey(const Key('appearance-layout-mode-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('卡片'));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.homeLayoutMode), 'card');

    await tester.scrollUntilVisible(find.text('封面内叠加'), 200, scrollable: scrollable);
    await tester.ensureVisible(find.byKey(const Key('appearance-cover-metadata-mode-insideCover')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('封面内叠加'));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.homeCoverMetadataMode), 'insideCover');
  });

  testWidgets('appearance settings persists the host theme color', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-colors'));
    await tester.pumpAndSettle();

    final blue = find.byKey(const Key('appearance-theme-color-blue'));
    await tester.ensureVisible(blue);
    await tester.tap(blue);
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.themeColor), 'blue');
    final previewContext = tester.element(find.byKey(const Key('appearance-theme-color-preview')));
    expect(AppThemeTokens.of(previewContext).accent, AppThemeColor.blue.accent);
  });

  testWidgets('appearance settings persists the independent night theme color', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-colors'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('appearance-dark-theme-color-coolBlack')),
      160,
      scrollable: find.descendant(of: find.byKey(const Key('profile-general-setting-theme-colors')), matching: find.byType(Scrollable)),
    );
    await Scrollable.ensureVisible(tester.element(find.byKey(const Key('appearance-dark-theme-color-coolBlack'))), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('appearance-dark-theme-color-coolBlack')));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.darkThemeColor), 'coolBlack');
    final previewContext = tester.element(find.byKey(const Key('appearance-dark-theme-color-preview')));
    expect(AppThemeTokens.of(previewContext).accent, AppDarkThemeColor.coolBlack.accent);
  });

  testWidgets('appearance settings persists the host day and night mode', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'display-settings'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('appearance-theme-mode')), findsOneWidget);
    await tester.tap(find.byKey(const Key('appearance-theme-mode-dark')));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.themeMode), 'dark');
  });

  for (final (size, scale, tv) in <(Size, double, bool)>[
    (const Size(320, 640), 1.6, false),
    (const Size(1280, 720), 1, true),
    (const Size(640, 360), 1.6, true),
  ]) {
    testWidgets('appearance remains usable at $size scale $scale TV $tv', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = await _settings();
      addTearDown(settings.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsProvider.overrideWithValue(settings)],
          child: MaterialApp(
            theme: AppTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: TvModeScope(enabled: tv, onChanged: (_) {}, child: child!),
            ),
            home: ProfileGeneralSettingPage(settingId: 'bookshelf-settings', onBackRequested: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final scrollable = find.descendant(
        of: find.byKey(const Key('profile-general-setting-bookshelf-settings')),
        matching: find.byType(Scrollable),
      );
      final badge = find.byKey(const Key('bookshelf-unread-badge'));
      await tester.scrollUntilVisible(badge, 160, scrollable: scrollable);
      await tester.ensureVisible(badge);
      await tester.pumpAndSettle();
      await tester.tap(badge);
      await tester.pumpAndSettle();
      expect(settings.get(AppSettingKeys.bookshelfUnreadBadgeEnabled), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<AppSettingsManager> _settings() async {
  final AppSettingsManager settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
  await settings.initialize();
  return settings;
}

Widget _host(AppSettingsManager settings, {required String settingId}) => ProviderScope(
  overrides: [appSettingsProvider.overrideWithValue(settings)],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: ProfileGeneralSettingPage(settingId: settingId, onBackRequested: () {}),
  ),
);
