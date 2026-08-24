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

    await tester.pump(const Duration(milliseconds: 180));
    expect(_labelOpacity(tester, AppNavigationDestination.home), 1);
    expect(_labelOpacity(tester, AppNavigationDestination.search), 0);
    expect(
      _iconScale(tester, AppNavigationDestination.search),
      AppMotion.bottomNavigationSelectedIconScale,
    );

    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester.getSize(indicator).width,
      greaterThan(initialIndicator.width),
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

  testWidgets('retargets rapid taps from the current capsule position', (
    WidgetTester tester,
  ) async {
    AppNavigationDestination selected = AppNavigationDestination.home;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: AppBottomNavigationMotionScope(
          initialDestination: selected,
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
