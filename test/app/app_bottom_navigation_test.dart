/// 底部导航共享动效范围测试。
///
/// 职责：
/// - 验证胶囊可重定向、减少动态效果立即收束且 controller 可释放。
///
/// 注意：
/// - 这是共享组件测试，不替代 Android 页面或路由验收。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('shrinks, slides and expands the selected icon capsule', (
    WidgetTester tester,
  ) async {
    AppNavigationDestination selected = AppNavigationDestination.home;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppBottomNavigationMotionScope(
          animateTexture: false,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return Scaffold(
                bottomNavigationBar: AppBottomNavigation(
                  selected: selected,
                  onSelected: (AppNavigationDestination destination) {
                    setState(() {
                      selected = destination;
                    });
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder homeItem = find.byKey(const Key('app-nav-home'));
    final Finder backdrop = find.byKey(
      const Key('app-bottom-navigation-backdrop'),
    );
    final Finder texture = find.byKey(
      const Key('app-bottom-navigation-texture'),
    );
    final Finder indicator = find.byKey(
      const Key('app-bottom-navigation-moving-indicator'),
    );
    final BoxDecoration backdropDecoration =
        tester.widget<DecoratedBox>(backdrop).decoration as BoxDecoration;
    final BoxDecoration indicatorDecoration =
        tester.widget<DecoratedBox>(indicator).decoration as BoxDecoration;
    final Rect initialIndicator = tester.getRect(indicator);

    expect(initialIndicator.width, lessThan(tester.getSize(homeItem).width));
    expect(backdropDecoration.gradient, isA<LinearGradient>());
    expect(tester.widget<IgnorePointer>(texture).ignoring, isTrue);
    expect(initialIndicator.height, AppSpacing.bottomNavigationIndicatorHeight);
    expect(indicatorDecoration.gradient, isA<LinearGradient>());
    expect(
      initialIndicator.center.dx,
      closeTo(tester.getCenter(homeItem).dx, 0.1),
    );
    expect(
      initialIndicator.center.dy,
      closeTo(
        tester
            .getRect(find.byKey(const Key('app-bottom-navigation')))
            .center
            .dy,
        0.1,
      ),
    );
    expect(_labelOpacity(tester, AppNavigationDestination.home), 0);
    expect(_labelOpacity(tester, AppNavigationDestination.search), 1);
    expect(tester.widget<InkResponse>(homeItem).hoverColor, Colors.transparent);

    final Finder searchItem = find.byKey(const Key('app-nav-search'));
    await tester.tap(searchItem);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    final Rect movingIndicator = tester.getRect(indicator);
    expect(selected, AppNavigationDestination.search);
    expect(movingIndicator.left, greaterThan(initialIndicator.left));
    expect(movingIndicator.width, lessThan(initialIndicator.width));
    expect(movingIndicator.height, lessThan(initialIndicator.height));

    await tester.pump(const Duration(milliseconds: 30));
    expect(
      tester.getSize(indicator).width,
      greaterThan(initialIndicator.width),
    );

    await tester.pump(const Duration(milliseconds: 150));
    expect(_labelOpacity(tester, AppNavigationDestination.home), 1);
    expect(_labelOpacity(tester, AppNavigationDestination.search), 0);
    expect(
      _iconScale(tester, AppNavigationDestination.search),
      AppMotion.bottomNavigationSelectedIconScale,
    );

    await tester.pumpAndSettle();
    final Rect settledIndicator = tester.getRect(indicator);
    expect(
      settledIndicator.center.dx,
      closeTo(tester.getCenter(searchItem).dx, 0.1),
    );
    expect(
      settledIndicator.width,
      closeTo(AppSpacing.bottomNavigationIndicatorWidth, 0.1),
    );
    expect(
      settledIndicator.height,
      closeTo(AppSpacing.bottomNavigationIndicatorHeight, 0.1),
    );

    final Finder profileItem = find.byKey(const Key('app-nav-profile'));
    await tester.tap(profileItem);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(indicator).center.dx,
      closeTo(tester.getCenter(profileItem).dx, 0.1),
    );
    expect(_labelOpacity(tester, AppNavigationDestination.profile), 0);
  });

  testWidgets('gently drifts the decorative texture when motion is enabled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppBottomNavigationMotionScope(
          child: Scaffold(
            bottomNavigationBar: AppBottomNavigation(
              selected: AppNavigationDestination.home,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    final Finder texturePaint = find.byKey(
      const Key('app-bottom-navigation-texture-paint'),
    );
    final CustomPaint initialTexture = tester.widget<CustomPaint>(texturePaint);
    await tester.pump(const Duration(seconds: 4));

    expect(
      tester.widget<CustomPaint>(texturePaint).painter,
      isNot(same(initialTexture.painter)),
    );
  });

  testWidgets('keeps the decorative texture still when motion is disabled', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AppBottomNavigationMotionScope(
            child: Scaffold(
              bottomNavigationBar: AppBottomNavigation(
                selected: AppNavigationDestination.home,
                onSelected: (_) {},
              ),
            ),
          ),
        ),
      ),
    );

    final Finder texturePaint = find.byKey(
      const Key('app-bottom-navigation-texture-paint'),
    );
    final CustomPainter? initialPainter = tester
        .widget<CustomPaint>(texturePaint)
        .painter;
    await tester.pump(const Duration(seconds: 4));

    expect(
      tester.widget<CustomPaint>(texturePaint).painter,
      same(initialPainter),
    );
  });

  testWidgets('retargets rapid taps from the current capsule position', (
    WidgetTester tester,
  ) async {
    AppNavigationDestination selected = AppNavigationDestination.home;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppBottomNavigationMotionScope(
          initialDestination: selected,
          animateTexture: false,
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return Scaffold(
                bottomNavigationBar: AppBottomNavigation(
                  selected: selected,
                  onSelected: (AppNavigationDestination destination) {
                    setState(() => selected = destination);
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder indicator = find.byKey(
      const Key('app-bottom-navigation-moving-indicator'),
    );
    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    final Rect beforeRetarget = tester.getRect(indicator);

    await tester.tap(find.byKey(const Key('app-nav-search')));
    await tester.pump();
    final Rect atRetarget = tester.getRect(indicator);
    expect(atRetarget.center.dx, closeTo(beforeRetarget.center.dx, 0.1));

    await tester.pump(const Duration(milliseconds: 90));
    expect(tester.getRect(indicator).center.dx, lessThan(atRetarget.center.dx));
    await tester.pumpAndSettle();

    expect(selected, AppNavigationDestination.search);
    expect(
      tester.getRect(indicator).center.dx,
      closeTo(
        tester.getCenter(find.byKey(const Key('app-nav-search'))).dx,
        0.1,
      ),
    );
  });

  testWidgets(
    'settles the capsule and implicit feedback immediately when reduced',
    (WidgetTester tester) async {
      AppNavigationDestination selected = AppNavigationDestination.home;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: AppBottomNavigationMotionScope(
              animateTexture: false,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  return Scaffold(
                    bottomNavigationBar: AppBottomNavigation(
                      selected: selected,
                      onSelected: (AppNavigationDestination destination) {
                        setState(() => selected = destination);
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );

      final Finder indicator = find.byKey(
        const Key('app-bottom-navigation-moving-indicator'),
      );
      await tester.tap(find.byKey(const Key('app-nav-discover')));
      await tester.pump();

      expect(selected, AppNavigationDestination.discover);
      expect(
        tester.getCenter(indicator).dx,
        closeTo(
          tester.getCenter(find.byKey(const Key('app-nav-discover'))).dx,
          0.1,
        ),
      );
      expect(
        tester
            .widget<AnimatedAlign>(
              find.byKey(const Key('app-nav-icon-motion-discover')),
            )
            .duration,
        Duration.zero,
      );
    },
  );

  testWidgets('releases active navigation tickers when its scope is removed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppBottomNavigationMotionScope(
          animateTexture: false,
          child: Scaffold(
            bottomNavigationBar: AppBottomNavigation(
              selected: AppNavigationDestination.home,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pump(const Duration(milliseconds: 40));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}

double _labelOpacity(
  WidgetTester tester,
  AppNavigationDestination destination,
) {
  return tester
      .widget<AnimatedOpacity>(
        find.descendant(
          of: find.byKey(Key('app-nav-label-motion-${destination.name}')),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;
}

double _iconScale(WidgetTester tester, AppNavigationDestination destination) {
  return tester
      .widget<AnimatedScale>(
        find.descendant(
          of: find.byKey(Key('app-nav-icon-motion-${destination.name}')),
          matching: find.byType(AnimatedScale),
        ),
      )
      .scale;
}
