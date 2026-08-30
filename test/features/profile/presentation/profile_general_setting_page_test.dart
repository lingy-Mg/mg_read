/// 阅读、外观和隐私通用设置页测试。
///
/// 只验证页面展示与现有设置持久化，不替代阅读器或平台权限测试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/about_document_page.dart';
import 'package:mg_read/features/profile/presentation/profile_general_setting_page.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('reading settings presents real reader-owned capabilities', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'reading-settings'));
    await tester.pumpAndSettle();

    expect(find.text('阅读播放设置'), findsOneWidget);
    expect(find.byKey(const Key('reading-settings-preview')), findsOneWidget);
    final Finder scrollable = find.descendant(
      of: find.byKey(const Key('profile-general-setting-reading-settings')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(find.text('字体与字号'), 200, scrollable: scrollable);
    expect(find.text('字体与字号'), findsOneWidget);
    expect(find.text('翻页与滚动'), findsOneWidget);
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
  });

  testWidgets('appearance settings persists the real shelf layout preference', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'theme-appearance'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('appearance-settings-preview')), findsOneWidget);
    await tester.tap(find.text('卡片'));
    await tester.pumpAndSettle();

    expect(settings.get(AppSettingKeys.homeLayoutMode), 'card');
  });

  testWidgets('privacy settings controls diagnostics and opens the policy', (WidgetTester tester) async {
    final AppSettingsManager settings = await _settings();
    addTearDown(settings.close);
    await tester.pumpWidget(_host(settings, settingId: 'privacy-permissions'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.diagnosticsEnabled), isTrue);

    await tester.tap(find.byKey(const Key('privacy-policy-action')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutDocumentPage), findsOneWidget);
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
