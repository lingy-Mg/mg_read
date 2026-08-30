/// 个人设置的占位二级与三级路由测试。
///
/// 职责：
/// - 验证设置入口、逐级返回和共享顶部栏的位置。
///
/// 注意：
/// - 使用 Finder 和稳定 Key，不替代 Android 实机验收。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/features/cache/presentation/cache_management_page.dart';
import 'package:mg_read/features/profile/presentation/about_document_page.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/contact_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';
import 'package:mg_read/features/profile/presentation/open_source_licenses_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/presentation/profile_setting_placeholder_page.dart';

import '../../../app/mg_read_app_test_support.dart';

void main() {
  testWidgets('single cache setting opens the unified cache management route', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-setting-downloads-cache')));
    await tester.pumpAndSettle();

    expect(find.byType(CacheManagementPage), findsOneWidget);
    expect(find.text('数据源网页与文件缓存'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('封面缓存'),
      220,
      scrollable: find.descendant(of: find.byKey(const Key('cache-management-content')), matching: find.byType(Scrollable)),
    );
    expect(find.text('封面缓存'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('漫画正文图片缓存'),
      220,
      scrollable: find.descendant(of: find.byKey(const Key('cache-management-content')), matching: find.byType(Scrollable)),
    );
    expect(find.text('漫画正文图片缓存'), findsOneWidget);
    expect(find.byKey(const Key('profile-setting-clear-cache')), findsNothing);
  });

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
    expect(find.text('阅读播放设置'), findsOneWidget);
    expect(find.byKey(const Key('reading-settings-preview')), findsOneWidget);
    expect(find.text('功能建设中'), findsNothing);
    expect(tester.getTopLeft(find.byKey(const Key('secondary-placeholder-top-bar'))).dy, 0);
    expect(find.byKey(const Key('secondary-placeholder-back')), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ProfileSettingPlaceholderPage), findsNothing);
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('about page excludes update and opens every completed detail route', (WidgetTester tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    final Finder profileScroll = find.byKey(const Key('profile-page-content'));
    await tester.drag(profileScroll, const Offset(0, -480));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于我们'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.byKey(const Key('about-action-update')), findsNothing);
    expect(find.byKey(const Key('about-action-agreement')), findsOneWidget);
    expect(find.byKey(const Key('about-action-privacy')), findsOneWidget);
    expect(find.byKey(const Key('about-action-licenses')), findsOneWidget);
    expect(find.byKey(const Key('about-action-contact')), findsOneWidget);

    await tester.tap(find.byKey(const Key('about-action-agreement')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutDocumentPage), findsOneWidget);
    expect(find.text('用户协议'), findsOneWidget);
    expect(find.textContaining('服务内容'), findsOneWidget);
    expect(find.text('功能建设中'), findsNothing);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('about-action-privacy')));
    await tester.pumpAndSettle();
    expect(find.byType(AboutDocumentPage), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    expect(find.textContaining('设备内数据'), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-detail-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('about-action-licenses')));
    await tester.pumpAndSettle();
    expect(find.byType(OpenSourceLicensesPage), findsOneWidget);
    expect(find.text('功能建设中'), findsNothing);

    await tester.tap(find.byKey(const Key('profile-detail-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('about-action-contact')));
    await tester.pumpAndSettle();
    expect(find.byType(ContactPage), findsOneWidget);
    expect(find.byKey(const Key('contact-open-feedback')), findsOneWidget);

    await tester.tap(find.byKey(const Key('contact-open-feedback')));
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackPage), findsOneWidget);
  });
}
