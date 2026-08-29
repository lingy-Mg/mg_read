import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/private_library_page.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

void main() {
  testWidgets('shows a dedicated empty private shelf and returns to home', (WidgetTester tester) async {
    var backCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PrivateLibraryPage(
            onBackRequested: () => backCount++,
            onDestinationRequested: (AppNavigationDestination destination) {},
            onReaderRequested: (String bookId) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('隐私书架'), findsOneWidget);
    expect(find.text('暂无隐私书籍'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('app-nav-home')), matching: find.byIcon(Icons.visibility_off_rounded)), findsOneWidget);
    await tester.tap(find.byKey(const Key('private-library-back')));
    expect(backCount, 1);
  });
}
