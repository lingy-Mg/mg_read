/// 个人资料详情页的布局与交互测试。
///
/// 职责：
/// - 验证详情页路由、固定顶部栏和本地反馈交互。
///
/// 注意：
/// - 测试固定浅色 Widget 几何，不宣称设备视觉验收。
///
library;

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/lan_sync/presentation/lan_sync_page.dart';
import 'package:mg_read/features/notifications/presentation/notifications_page.dart';

import '../../../app/mg_read_app_test_support.dart';

void main() {
  testWidgets('profile bell opens the notification route and back returns', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('通知'));
    await tester.pumpAndSettle();

    expect(find.byType(NotificationsPage), findsOneWidget);
    expect(find.text('暂无通知'), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.tap(find.byKey(const Key('notifications-back')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('profile opens typed about and feedback routes and back returns', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);

    final Finder profileScroll = find.byKey(const Key('profile-page-content'));
    final Finder profileScrollable = find.descendant(of: profileScroll, matching: find.byType(Scrollable));
    final Finder aboutAction = find.byKey(const Key('profile-setting-about'));
    await tester.scrollUntilVisible(aboutAction, 220, scrollable: profileScrollable);
    await tester.drag(profileScrollable, const Offset(0, -24));
    await tester.pumpAndSettle();
    await tester.tap(aboutAction);
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.text('统一阅读'), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);

    final Finder feedbackAction = find.byKey(const Key('profile-setting-feedback'));
    await tester.scrollUntilVisible(feedbackAction, 180, scrollable: profileScrollable);
    await tester.tap(feedbackAction);
    await tester.pumpAndSettle();
    expect(find.byType(FeedbackPage), findsOneWidget);
    expect(find.text('感谢您的反馈！'), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('profile opens the on-demand LAN sync page', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    final profileScroll = find.byKey(const Key('profile-page-content'));
    final action = find.byKey(const Key('profile-setting-data-backup'));
    await tester.scrollUntilVisible(
      action,
      220,
      scrollable: find.descendant(of: profileScroll, matching: find.byType(Scrollable)),
    );
    await tester.tap(action);
    await tester.pumpAndSettle();

    expect(find.byType(LanSyncPage), findsOneWidget);
    expect(find.text('发送数据'), findsOneWidget);
    expect(find.text('接收数据'), findsOneWidget);
    expect(find.textContaining('首版传输不加密'), findsOneWidget);
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);

    await tester.tap(find.byKey(const Key('lan-sync-back')));
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
  });

  testWidgets('about page uses the measured 390 by 900 geometry', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_aboutHost());
    await tester.pumpAndSettle();
    final Rect topBar = tester.getRect(find.byKey(const Key('profile-detail-top-bar')));
    final Rect icon = tester.getRect(find.byKey(const Key('about-app-icon')));
    final Rect card = tester.getRect(find.byKey(const Key('about-settings-card')));

    expect(topBar.top, closeTo(24, 0.1));
    expect(topBar.height, AppSpacing.minimumTouchTarget);
    expect(icon.top, closeTo(101, 0.1));
    expect(icon.size, const Size(106, 106));
    expect(card.left, closeTo(20, 0.1));
    expect(card.width, closeTo(350, 0.1));
    expect(card.height, AppDetailMetrics.aboutCardHeight);
    expect(card.top, closeTo(348, 0.1));
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);
  });

  testWidgets('feedback page preserves measured banner and form proportions', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();

    final Rect banner = tester.getRect(find.byKey(const Key('feedback-thanks-banner')));
    final Rect form = tester.getRect(find.byKey(const Key('feedback-form-card')));

    expect(banner, const Rect.fromLTWH(20, 72, 350, 108));
    expect(form, const Rect.fromLTWH(20, 195, 350, 602));
    expect(tester.takeException(), isNull);
  });

  testWidgets('about and feedback keep their title bars fixed while content scrolls', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 600));
    await tester.pumpWidget(_aboutHost());
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('about-page-content')), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('profile-detail-top-bar'))).top, 24);

    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('feedback-page-content')), const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('profile-detail-top-bar'))).top, 24);
  });

  testWidgets('feedback types switch and content is limited to 500 characters', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();

    final Finder suggestion = find.byKey(const Key('feedback-type-suggestion'));
    final Finder problem = find.byKey(const Key('feedback-type-problem'));
    expect(tester.getSemantics(suggestion).flagsCollection.isSelected, Tristate.isTrue);

    await tester.tap(problem);
    await tester.pump();
    expect(tester.getSemantics(problem).flagsCollection.isSelected, Tristate.isTrue);
    expect(tester.getSemantics(suggestion).flagsCollection.isSelected, Tristate.isFalse);

    await tester.enterText(find.byKey(const Key('feedback-content-field')), List<String>.filled(510, '阅').join());
    await tester.pump();
    final EditableText editor = tester.widget<EditableText>(find.byType(EditableText).first);
    expect(editor.controller.text.characters.length, 500);
    expect(find.text('500/500'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('feedback actions remain local and never pretend to submit', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-add-image')));
    await tester.pump();
    expect(find.text('截图选择尚未接入，当前不会访问本地文件。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feedback-submit')));
    await tester.pump();
    expect(find.text('请先填写反馈内容。'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('feedback-content-field')), '希望增加更清晰的目录筛选。');
    await tester.tap(find.byKey(const Key('feedback-submit')));
    await tester.pump();
    expect(find.text('反馈已保留在当前页面，提交服务尚未接入。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile detail pages omit the primary navigation bar', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_aboutHost());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);
    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-bottom-navigation')), findsNothing);
  });

  testWidgets('profile details stay light-only without header theme actions', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    final settings = await createTestAppSettings(themeMode: 'light');
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);

    final Finder profileScroll = find.byKey(const Key('profile-page-content'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-setting-about')),
      220,
      scrollable: find.descendant(of: profileScroll, matching: find.byType(Scrollable)),
    );
    await tester.drag(find.descendant(of: profileScroll, matching: find.byType(Scrollable)), const Offset(0, -24));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-setting-about')));
    await tester.pumpAndSettle();

    final Finder aboutPage = find.byType(AboutPage);
    expect(aboutPage, findsOneWidget);
    expect(Theme.of(tester.element(aboutPage)).brightness, Brightness.light);
    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);
  });
}

Widget _aboutHost() {
  return _host(
    child: AboutPage(appVersion: '1.2.0', onBackRequested: () {}, onDestinationRequested: (_) {}),
  );
}

Widget _feedbackHost() {
  return _host(
    child: FeedbackPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
  );
}

Widget _host({required Widget child}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    builder: (BuildContext context, Widget? routedChild) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(padding: const EdgeInsets.only(top: 24), viewPadding: const EdgeInsets.only(top: 24)),
        child: routedChild ?? const SizedBox.shrink(),
      );
    },
    home: child,
  );
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
