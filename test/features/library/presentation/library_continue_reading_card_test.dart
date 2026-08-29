import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';

void main() {
  testWidgets('renders an immersive surface with a flat cover on the right', (WidgetTester tester) async {
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
    final Finder flatCover = find.byKey(const Key('continue-reading-flat-cover'));
    final Rect cover = tester.getRect(flatCover);
    final Rect title = tester.getRect(find.text('诡秘之主'));
    final Element surfaceElement = tester.element(find.byKey(const Key('continue-reading-surface')));
    final List<Widget> localCoverAncestors = <Widget>[];
    tester.element(flatCover).visitAncestorElements((Element element) {
      if (identical(element, surfaceElement)) return false;
      localCoverAncestors.add(element.widget);
      return true;
    });

    expect(find.byType(LibraryBookCover), findsNWidgets(2));
    expect(localCoverAncestors.whereType<Transform>(), isEmpty);
    expect(localCoverAncestors.whereType<RotatedBox>(), isEmpty);
    expect(surface.contains(cover.topLeft), isTrue);
    expect(surface.contains(cover.bottomRight), isTrue);
    expect(title.right, lessThan(cover.left));
    expect(action.right, lessThan(cover.left));
  });
}
