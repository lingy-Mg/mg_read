/// 阅读和外观通用设置页测试。
///
/// 只验证页面展示与现有设置持久化，不替代阅读器或平台权限测试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_general_setting_page.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('reading and player settings only present controls owned by this page', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'reading-settings'));
    await tester.pumpAndSettle();

    expect(find.descendant(of: find.byKey(const Key('secondary-placeholder-top-bar')), matching: find.text('阅读器与播放器')), findsOneWidget);
    expect(find.byKey(const Key('reading-settings-preview')), findsNothing);
    expect(find.text('书架目录更新'), findsNothing);
    expect(find.text('字体与字号'), findsNothing);
    expect(find.text('应用内播放条'), findsNothing);
    final Finder scrollable = find.descendant(
      of: find.byKey(const Key('profile-general-setting-reading-settings')),
      matching: find.byType(Scrollable),
    );
    expect(find.text('小说阅读'), findsOneWidget);
    expect(find.text('音频播放器'), findsOneWidget);
    expect(find.text('功能建设中'), findsNothing);

    final Finder preloadIncrease = find.byKey(const Key('novel-preload-count-increase'));
    await tester.scrollUntilVisible(preloadIncrease, 200, scrollable: scrollable);
    await tester.tap(preloadIncrease);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.novelPreloadChapterCount), 2);

    final Finder continueBehavior = find.byKey(const Key('audio-exit-behavior-continue'));
    await tester.scrollUntilVisible(continueBehavior, 300, scrollable: scrollable);
    await tester.drag(scrollable, const Offset(0, -140));
    await tester.pumpAndSettle();
    await tester.tap(continueBehavior);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.audioExitBehavior), 'continue');

    final Finder squareMiniPlayer = find.byKey(const Key('audio-mini-player-style-square'));
    await tester.scrollUntilVisible(squareMiniPlayer, 300, scrollable: scrollable);
    await tester.tap(squareMiniPlayer);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.audioMiniPlayerStyle), 'square');

    final rememberPosition = find.byKey(const Key('profile-audio-remember-position'));
    await tester.scrollUntilVisible(rememberPosition, 200, scrollable: scrollable);
    expect(tester.widget<SwitchListTile>(rememberPosition).value, isTrue);
    await tester.tap(rememberPosition);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.audioRememberPosition), isFalse);
    expect(tester.widget<SwitchListTile>(rememberPosition).value, isFalse);

    expect(settings.get(AppSettingKeys.bookshelfCatalogRefreshIntervalHours), 24);
  });

  testWidgets('appearance settings persists the real shelf layout preference', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-appearance'));
    await tester.pumpAndSettle();

    final Finder scrollable = find.descendant(
      of: find.byKey(const Key('profile-general-setting-theme-appearance')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.byKey(const Key('appearance-settings-preview')), 160, scrollable: scrollable);
    expect(find.byKey(const Key('appearance-settings-preview')), findsOneWidget);
    await tester.scrollUntilVisible(find.text('卡片'), 200, scrollable: scrollable);
    await tester.tap(find.text('卡片'));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.homeLayoutMode), 'card');

    await tester.scrollUntilVisible(find.text('封面内叠加'), 200, scrollable: scrollable);
    await tester.tap(find.text('封面内叠加'));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.homeCoverMetadataMode), 'insideCover');
  });

  testWidgets('appearance settings persists the host theme color', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-appearance'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('appearance-theme-color-blue')));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.themeColor), 'blue');
  });

  testWidgets('appearance settings persists the independent night theme color', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-appearance'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('appearance-dark-theme-color-coolBlack')),
      160,
      scrollable: find.descendant(of: find.byKey(const Key('profile-general-setting-theme-appearance')), matching: find.byType(Scrollable)),
    );
    await Scrollable.ensureVisible(tester.element(find.byKey(const Key('appearance-dark-theme-color-coolBlack'))), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('appearance-dark-theme-color-coolBlack')));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.darkThemeColor), 'coolBlack');
  });

  testWidgets('appearance settings persists the host day and night mode', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-appearance'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('appearance-theme-mode')), findsOneWidget);
    await tester.tap(find.byKey(const Key('appearance-theme-mode-dark')));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.themeMode), 'dark');
  });
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
