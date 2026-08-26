import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/reading_history_page.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

void main() {
  testWidgets('uses the settings secondary-page chrome without bottom navigation', (WidgetTester tester) async {
    var backCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ReadingHistoryPage(onBackRequested: () => backCount += 1, onReaderRequested: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('阅读记录'), findsOneWidget);
    expect(find.text('暂无阅读记录'), findsOneWidget);
    expect(find.byType(AppBottomNavigation), findsNothing);

    await tester.tap(find.byKey(const Key('reading-history-back')));
    expect(backCount, 1);
  });
}
