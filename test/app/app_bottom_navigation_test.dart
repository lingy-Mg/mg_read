import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('uses a compact animated indicator instead of a full item fill', (
    WidgetTester tester,
  ) async {
    AppNavigationDestination selected = AppNavigationDestination.home;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
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
    );
    await tester.pumpAndSettle();

    final Finder homeItem = find.byKey(const Key('app-nav-home'));
    final Finder homeIndicator = find.byKey(
      const Key('app-nav-indicator-home'),
    );
    final AnimatedContainer indicator = tester.widget<AnimatedContainer>(
      homeIndicator,
    );
    final BoxDecoration decoration = indicator.decoration! as BoxDecoration;

    expect(
      tester.getSize(homeIndicator).width,
      lessThan(tester.getSize(homeItem).width),
    );
    expect(
      tester.getSize(homeIndicator).height,
      AppSpacing.bottomNavigationIndicatorHeight,
    );
    expect(
      decoration.color,
      AppThemeTokens.of(tester.element(homeIndicator)).accentSoft,
    );
    expect(tester.widget<InkResponse>(homeItem).hoverColor, Colors.transparent);

    await tester.tap(find.byKey(const Key('app-nav-search')));
    await tester.pump();
    await tester.pump(AppMotion.navigationSelection);

    final AnimatedContainer searchIndicator = tester.widget<AnimatedContainer>(
      find.byKey(const Key('app-nav-indicator-search')),
    );
    final BoxDecoration searchDecoration =
        searchIndicator.decoration! as BoxDecoration;
    expect(selected, AppNavigationDestination.search);
    expect(
      searchDecoration.color,
      AppThemeTokens.of(tester.element(homeItem)).accentSoft,
    );
  });
}
