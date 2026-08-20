import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/about_page.dart';
import 'package:mg_read/features/profile/presentation/feedback_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';

import '../../../app/mg_read_app_test_support.dart';

void main() {
  testWidgets(
    'profile opens typed about and feedback routes and back returns',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(390, 900));
      final settings = await createTestAppSettings();
      addTearDown(settings.close);
      await tester.pumpWidget(testMgReadApp(settings));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('app-nav-profile')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);

      final Finder profileScroll = find.byKey(
        const Key('profile-page-content'),
      );
      final Finder profileScrollable = find.descendant(
        of: profileScroll,
        matching: find.byType(Scrollable),
      );
      final Finder aboutAction = find.byKey(const Key('profile-setting-about'));
      await tester.scrollUntilVisible(
        aboutAction,
        220,
        scrollable: profileScrollable,
      );
      await tester.tap(aboutAction);
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
      expect(find.text('统一阅读'), findsOneWidget);

      await tester.tap(find.byKey(const Key('profile-detail-back')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);

      final Finder feedbackAction = find.byKey(
        const Key('profile-setting-feedback'),
      );
      await tester.scrollUntilVisible(
        feedbackAction,
        180,
        scrollable: profileScrollable,
      );
      await tester.tap(feedbackAction);
      await tester.pumpAndSettle();
      expect(find.byType(FeedbackPage), findsOneWidget);
      expect(find.text('感谢您的反馈！'), findsOneWidget);

      await tester.tap(find.byKey(const Key('profile-detail-back')));
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);
    },
  );

  testWidgets('about page uses the measured 390 by 900 geometry', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_aboutHost());
    await tester.pumpAndSettle();
    final Rect topBar = tester.getRect(
      find.byKey(const Key('profile-detail-top-bar')),
    );
    final Rect icon = tester.getRect(find.byKey(const Key('about-app-icon')));
    final Rect card = tester.getRect(
      find.byKey(const Key('about-settings-card')),
    );
    final Rect navigation = tester.getRect(
      find.byKey(const Key('app-bottom-navigation')),
    );

    expect(topBar.top, closeTo(24, 0.1));
    expect(topBar.height, AppDetailMetrics.topBarHeight);
    expect(icon.top, closeTo(117, 0.1));
    expect(icon.size, const Size(106, 106));
    expect(card.left, closeTo(20, 0.1));
    expect(card.width, closeTo(350, 0.1));
    expect(card.height, AppDetailMetrics.aboutCardHeight);
    expect(card.top, closeTo(364, 0.1));
    expect(navigation.top, closeTo(824, 0.1));
  });

  testWidgets('feedback page preserves measured banner and form proportions', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();

    final Rect banner = tester.getRect(
      find.byKey(const Key('feedback-thanks-banner')),
    );
    final Rect form = tester.getRect(
      find.byKey(const Key('feedback-form-card')),
    );

    expect(banner, const Rect.fromLTWH(20, 88, 350, 108));
    expect(form, const Rect.fromLTWH(20, 211, 350, 602));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'feedback types switch and content is limited to 500 characters',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await _setViewport(tester, const Size(390, 900));
      await tester.pumpWidget(_feedbackHost());
      await tester.pumpAndSettle();

      final Finder suggestion = find.byKey(
        const Key('feedback-type-suggestion'),
      );
      final Finder problem = find.byKey(const Key('feedback-type-problem'));
      expect(
        tester.getSemantics(suggestion).flagsCollection.isSelected,
        Tristate.isTrue,
      );

      await tester.tap(problem);
      await tester.pump();
      expect(
        tester.getSemantics(problem).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      expect(
        tester.getSemantics(suggestion).flagsCollection.isSelected,
        Tristate.isFalse,
      );

      await tester.enterText(
        find.byKey(const Key('feedback-content-field')),
        List<String>.filled(510, '阅').join(),
      );
      await tester.pump();
      final EditableText editor = tester.widget<EditableText>(
        find.byType(EditableText).first,
      );
      expect(editor.controller.text.characters.length, 500);
      expect(find.text('500/500'), findsOneWidget);
      semantics.dispose();
    },
  );

  testWidgets('feedback actions remain local and never pretend to submit', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_feedbackHost());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-add-image')));
    await tester.pump();
    expect(find.text('截图选择尚未接入，当前不会访问本地文件。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('feedback-submit')));
    await tester.pump();
    expect(find.text('请先填写反馈内容。'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('feedback-content-field')),
      '希望增加更清晰的目录筛选。',
    );
    await tester.tap(find.byKey(const Key('feedback-submit')));
    await tester.pump();
    expect(find.text('反馈已保留在当前页面，提交服务尚未接入。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile stays selected in detail navigation semantics', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_aboutHost());
    await tester.pumpAndSettle();

    final SemanticsNode profile = tester.getSemantics(
      find.byKey(const Key('app-nav-profile')),
    );
    expect(profile.flagsCollection.isSelected, Tristate.isTrue);
    semantics.dispose();
  });

  testWidgets('profile details stay light-only without header theme actions', (
    WidgetTester tester,
  ) async {
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
      scrollable: find.descendant(
        of: profileScroll,
        matching: find.byType(Scrollable),
      ),
    );
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
    child: AboutPage(onBackRequested: () {}, onDestinationRequested: (_) {}),
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
        data: mediaQuery.copyWith(
          padding: const EdgeInsets.only(top: 24),
          viewPadding: const EdgeInsets.only(top: 24),
        ),
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
