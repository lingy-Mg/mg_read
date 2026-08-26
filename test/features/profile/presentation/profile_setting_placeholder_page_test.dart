/// 个人设置的占位二级与三级路由测试。
///
/// 职责：
/// - 验证设置入口、逐级返回和共享顶部栏的位置。
///
/// 注意：
/// - 使用 Finder 和稳定 Key，不替代 Android 实机验收。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';

import 'package:mg_read/features/profile/presentation/about_item_placeholder_page.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/presentation/profile_setting_placeholder_page.dart';

import '../../../app/mg_read_app_test_support.dart';

void main() {
  testWidgets('profile setting opens a real secondary placeholder route', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    final Finder profileScroll = find.byKey(const Key('profile-page-content'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-setting-reading-settings')),
      220,
      scrollable: find.descendant(of: profileScroll, matching: find.byType(Scrollable)),
    );
    await tester.tap(find.byKey(const Key('profile-setting-reading-settings')));
    await tester.pumpAndSettle();

    expect(find.byType(ProfileSettingPlaceholderPage), findsOneWidget);
    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.text('功能建设中'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('secondary-placeholder-top-bar'))).dy, AppSpacing.pageHeaderTopPadding);
    expect(find.byKey(const Key('secondary-placeholder-back')), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ProfileSettingPlaceholderPage), findsNothing);
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('about page opens a real third-level placeholder route', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    final Finder profileScroll = find.byKey(const Key('profile-page-content'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-setting-about')),
      220,
      scrollable: find.descendant(of: profileScroll, matching: find.byType(Scrollable)),
    );
    await tester.tap(find.byKey(const Key('profile-setting-about')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('about-action-update')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutItemPlaceholderPage), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('功能建设中'), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.tap(find.byKey(const Key('secondary-placeholder-back')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
  });
}
