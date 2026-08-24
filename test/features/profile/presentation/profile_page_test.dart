import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_overview_card.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_settings_list.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('renders the profile hierarchy with fixed mobile proportions', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('我的'), findsAtLeastNWidgets(2));
    expect(find.byType(ProfileOverviewCard), findsOneWidget);
    expect(find.text('书海行者'), findsOneWidget);
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('设置与管理'), findsOneWidget);
    expect(find.text('阅读设置'), findsOneWidget);
    expect(find.text('数据源管理'), findsOneWidget);
    expect(find.text('关于与其他'), findsOneWidget);
    expect(find.text('调试日志'), findsOneWidget);
    expect(find.byType(AppBottomNavigation), findsOneWidget);

    final Rect card = tester.getRect(find.byType(ProfileOverviewCard));
    final Rect firstSettingsRow = tester.getRect(
      find.byType(ProfileSettingsRow).first,
    );
    expect(card.left, closeTo(AppSpacing.compactPagePadding, 0.1));
    expect(card.width, closeTo(350, 0.1));
    expect(card.height, AppSpacing.profileCardHeight);
    expect(firstSettingsRow.height, AppSpacing.profileSettingsRowHeight);
  });

  testWidgets('uses the reference text hierarchy and selected profile nav', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Text pageTitle = tester.widget<Text>(
      find.descendant(
        of: find.byType(ProfileTopBar),
        matching: find.text('我的'),
      ),
    );
    final Text settingTitle = tester.widget<Text>(find.text('阅读设置'));
    final Text settingDescription = tester.widget<Text>(find.text('字体、排版、翻页等'));
    final Finder profileNavigation = find.byKey(const Key('app-nav-profile'));
    final SemanticsNode profileSemantics = tester.getSemantics(
      profileNavigation,
    );

    expect(pageTitle.style?.fontSize, AppSpacing.pageTitleSize);
    expect(pageTitle.style?.fontWeight, FontWeight.w600);
    expect(settingTitle.style?.fontSize, 16);
    expect(settingTitle.style?.fontWeight, FontWeight.w500);
    expect(settingDescription.style?.fontSize, 13);
    expect(settingDescription.style?.fontWeight, FontWeight.w400);
    expect(profileSemantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(
      profileSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    semantics.dispose();
  });

  testWidgets('keeps light-only top actions and local action feedback', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-setting-reading-settings')));
    await tester.pumpAndSettle();
    expect(find.text('此操作尚未接入真实数据，可由后续功能替换。'), findsOneWidget);
  });

  testWidgets('delegates a destination selection to the app layer', (
    WidgetTester tester,
  ) async {
    AppNavigationDestination? requestedDestination;
    await tester.pumpWidget(
      _host(
        onDestinationRequested: (AppNavigationDestination destination) {
          requestedDestination = destination;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-home')));
    expect(requestedDestination, AppNavigationDestination.home);
  });

  testWidgets('delegates the diagnostics entry to the app layer', (
    WidgetTester tester,
  ) async {
    var diagnosticsRequested = false;
    await tester.pumpWidget(
      _host(onDiagnosticsRequested: () => diagnosticsRequested = true),
    );
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('profile-page-content')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    final diagnostics = find.byKey(const Key('profile-setting-diagnostics'));
    await tester.tap(diagnostics);

    expect(diagnosticsRequested, isTrue);
  });

  testWidgets(
    'keeps the phone-width profile content centered on wide windows',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(1280, 900));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final Rect card = tester.getRect(find.byType(ProfileOverviewCard));
      expect(card.center.dx, closeTo(640, 0.1));
      expect(
        card.width,
        closeTo(
          AppSpacing.contentMaxWidth - AppSpacing.widePagePadding * 2,
          0.1,
        ),
      );
    },
  );
}

Widget _host({
  ValueChanged<AppNavigationDestination>? onDestinationRequested,
  VoidCallback? onToggleTheme,
  VoidCallback? onDiagnosticsRequested,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: ProfilePage(
      onDestinationRequested: onDestinationRequested,
      onToggleTheme: onToggleTheme,
      onDiagnosticsRequested: onDiagnosticsRequested,
    ),
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
