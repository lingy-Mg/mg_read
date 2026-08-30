import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_overview_card.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_settings_list.dart';
import 'package:mg_read/features/profile/domain/profile_identity.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('places the Android profile header directly below the system inset', (WidgetTester tester) async {
    await tester.pumpWidget(_host(topInset: 24));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(ProfileTopBar)).top, 24);
  });

  testWidgets('renders the profile hierarchy with fixed mobile proportions', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('我的'), findsAtLeastNWidgets(2));
    expect(find.byType(ProfileOverviewCard), findsOneWidget);
    expect(find.text('书海行者'), findsOneWidget);
    expect(find.text('VIP'), findsOneWidget);
    expect(find.text('设置与管理'), findsOneWidget);
    expect(find.text('阅读播放设置'), findsOneWidget);
    expect(find.text('数据源管理'), findsOneWidget);
    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.text('下载与缓存'), findsNothing);
    expect(find.text('清理缓存'), findsNothing);
    expect(find.text('关于与其他'), findsOneWidget);
    expect(find.text('调试日志'), findsOneWidget);
    expect(find.byType(AppBottomNavigation), findsOneWidget);

    final Rect card = tester.getRect(find.byType(ProfileOverviewCard));
    final Rect firstSettingsRow = tester.getRect(find.byType(ProfileSettingsRow).first);
    expect(card.left, closeTo(AppSpacing.compactPagePadding, 0.1));
    expect(card.width, closeTo(350, 0.1));
    expect(card.height, AppSpacing.profileCardHeight);
    expect(firstSettingsRow.height, AppSpacing.profileSettingsRowHeight);

    final ListView profileContent = tester.widget<ListView>(find.byKey(const Key('profile-page-content')));
    expect((profileContent.padding! as EdgeInsets).bottom, AppSpacing.profileContentBottomSafeDistance);
    final Scrollbar scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isFalse);
    expect(scrollbar.thickness, AppSpacing.unit - 1);

    final Finder firstSettingsIcon = find.descendant(of: find.byType(ProfileSettingsRow).first, matching: find.byType(Icon));
    expect(tester.widget<Icon>(firstSettingsIcon.first).size, AppSpacing.profileSettingsIconSize);
    final Finder firstSettingsChevron = find.descendant(
      of: find.byType(ProfileSettingsRow).first,
      matching: find.byIcon(Icons.chevron_right_rounded),
    );
    expect(
      tester.widget<Icon>(firstSettingsChevron),
      isA<Icon>().having((Icon icon) => icon.size, 'chevron size', AppSpacing.profileChevronSize),
    );
  });

  testWidgets('uses the reference text hierarchy and selected profile nav', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Text pageTitle = tester.widget<Text>(find.descendant(of: find.byType(ProfileTopBar), matching: find.text('我的')));
    final Text settingTitle = tester.widget<Text>(find.text('阅读播放设置'));
    final Text settingDescription = tester.widget<Text>(find.text('阅读偏好、后台播放等'));
    final Finder profileNavigation = find.byKey(const Key('app-nav-profile'));
    final SemanticsNode profileSemantics = tester.getSemantics(profileNavigation);

    expect(pageTitle.style?.fontSize, AppSpacing.pageTitleSize);
    expect(pageTitle.style?.fontWeight, FontWeight.w600);
    expect(settingTitle.style?.fontSize, 16);
    expect(settingTitle.style?.fontWeight, FontWeight.w600);
    expect(settingDescription.style?.fontSize, 13);
    expect(settingDescription.style?.fontWeight, FontWeight.w400);
    expect(profileSemantics.flagsCollection.isSelected, Tristate.isTrue);
    expect(profileSemantics.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    semantics.dispose();
  });

  testWidgets('keeps light-only top actions and local action feedback', (WidgetTester tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('theme-mode-toggle')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-setting-reading-settings')));
    await tester.pumpAndSettle();
    expect(find.text('此操作尚未接入真实数据，可由后续功能替换。'), findsOneWidget);
  });

  testWidgets('delegates the notification bell to the app layer', (WidgetTester tester) async {
    var notificationsRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: ProfilePage(onNotificationsRequested: () => notificationsRequested = true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('通知'));

    expect(notificationsRequested, isTrue);
    expect(find.text('此操作尚未接入真实数据，可由后续功能替换。'), findsNothing);
  });

  testWidgets('shows LAN sync as an explicit on-demand action', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('profile-page-content')), const Offset(0, -360));
    await tester.pumpAndSettle();

    final Finder backupRow = find.byKey(const Key('profile-setting-data-backup'));
    expect(find.descendant(of: backupRow, matching: find.text('局域网同步')), findsOneWidget);
    expect(find.descendant(of: backupRow, matching: find.text('同一网络传输数据源、书架与进度')), findsOneWidget);
    expect(find.text('已开启'), findsNothing);
  });

  testWidgets('shows local identity and delegates profile editing', (WidgetTester tester) async {
    var editRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: ProfilePage(
          profileIdentity: const ProfileIdentity(displayName: '纸间旅人', motto: '在每一页里遇见新的世界。'),
          onEditRequested: () => editRequested = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('纸间旅人'), findsOneWidget);
    expect(find.text('在每一页里遇见新的世界。'), findsOneWidget);
    await tester.tap(find.text('编辑资料'));

    expect(editRequested, isTrue);
  });

  testWidgets('delegates a destination selection to the app layer', (WidgetTester tester) async {
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

  testWidgets('delegates the diagnostics entry to the app layer', (WidgetTester tester) async {
    var diagnosticsRequested = false;
    await tester.pumpWidget(_host(onDiagnosticsRequested: () => diagnosticsRequested = true));
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('profile-page-content')), const Offset(0, -600));
    await tester.pumpAndSettle();
    final diagnostics = find.byKey(const Key('profile-setting-diagnostics'));
    await tester.tap(diagnostics);

    expect(diagnosticsRequested, isTrue);
  });

  testWidgets('delegates the single cache entry to the app layer', (WidgetTester tester) async {
    var cacheRequested = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: ProfilePage(onPluginCacheRequested: () => cacheRequested = true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-setting-downloads-cache')));

    expect(cacheRequested, isTrue);
    expect(find.byKey(const Key('profile-setting-clear-cache')), findsNothing);
  });

  testWidgets('delegates the import export entry to the app layer', (WidgetTester tester) async {
    var requested = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: ProfilePage(onImportExportRequested: () => requested = true),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byKey(const Key('profile-page-content')), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-setting-import-export')));

    expect(requested, isTrue);
    expect(find.text('导入导出'), findsOneWidget);
  });

  testWidgets('keeps the phone-width profile content centered on wide windows', (WidgetTester tester) async {
    await _setViewport(tester, const Size(1280, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final Rect card = tester.getRect(find.byType(ProfileOverviewCard));
    expect(card.center.dx, closeTo(640, 0.1));
    expect(card.width, closeTo(AppSpacing.contentMaxWidth - AppSpacing.widePagePadding * 2, 0.1));
  });
}

Widget _host({
  ValueChanged<AppNavigationDestination>? onDestinationRequested,
  VoidCallback? onToggleTheme,
  VoidCallback? onDiagnosticsRequested,
  double topInset = 0,
}) {
  return MaterialApp(
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(
          padding: EdgeInsets.only(top: topInset),
          viewPadding: EdgeInsets.only(top: topInset),
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
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
