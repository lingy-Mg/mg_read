/// Verifies TV navigation clears status bars without padding a safe body twice.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/tv_top_navigation.dart';

void main() {
  const systemPadding = EdgeInsets.fromLTRB(24, 32, 24, 16);

  Widget host(Widget child) => MaterialApp(
    theme: AppTheme.dark(),
    home: MediaQuery(
      data: const MediaQueryData(padding: systemPadding, viewPadding: systemPadding),
      child: TvModeScope(enabled: true, onChanged: (_) {}, child: child),
    ),
  );

  testWidgets('TV app bar clears the status bar and reserves its full content height', (tester) async {
    await tester.pumpWidget(
      host(
        Scaffold(
          appBar: AppBottomNavigation(selected: AppNavigationDestination.search, onSelected: (_) {}),
          body: const SizedBox.expand(key: Key('body')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final home = tester.getRect(find.byKey(const Key('app-nav-home')));
    final search = tester.getRect(find.byKey(const Key('app-nav-search')));
    expect(home.top, greaterThanOrEqualTo(systemPadding.top));
    expect(search.top, greaterThanOrEqualTo(systemPadding.top));
    expect(home.left, greaterThanOrEqualTo(systemPadding.left));
    expect(tester.getRect(find.byKey(const Key('body'))).top, systemPadding.top + AppSpacing.bottomNavigationHeight);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV library navigation consumes an outer safe area only once', (tester) async {
    await tester.pumpWidget(
      host(
        Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                SizedBox(
                  height: AppSpacing.bottomNavigationHeight,
                  child: TvTopNavigation(selected: AppNavigationDestination.home, onSelected: (_) {}),
                ),
                const Expanded(child: SizedBox.expand(key: Key('body'))),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(TvTopNavigation)).top, systemPadding.top);
    expect(tester.getRect(find.byKey(const Key('body'))).top, systemPadding.top + AppSpacing.bottomNavigationHeight);
    expect(tester.takeException(), isNull);
  });
}
