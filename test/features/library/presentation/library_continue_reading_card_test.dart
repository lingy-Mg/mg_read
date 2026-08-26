import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';

void main() {
  testWidgets('centers the continue action in the card area beside the cover', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: LibraryContinueReadingCard(data: LibraryHomeFixtures.preview.continueReading!, onContinueReading: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect surface = tester.getRect(find.byKey(const Key('continue-reading-surface')));
    final Rect action = tester.getRect(find.byKey(const Key('continue-reading-cta')));
    final Rect cover = tester.getRect(find.byType(LibraryBookCover));
    final Rect title = tester.getRect(find.text('诡秘之主'));

    expect(action.center.dx, closeTo((cover.right + surface.right) / 2, 0.1));
    expect(title.center.dx, closeTo(action.center.dx, 0.1));
    expect(title.left, greaterThan(cover.right));
  });
}
