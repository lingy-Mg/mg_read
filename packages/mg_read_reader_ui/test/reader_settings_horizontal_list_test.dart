import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_reader_ui/src/ui/settings/reader_settings_controls.dart';

void main() {
  testWidgets('mouse wheel scrolls horizontal settings rails', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 220,
            height: 48,
            child: ReaderSettingsHorizontalList(
              itemCount: 6,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int index) =>
                  SizedBox(width: 76, child: ColoredBox(color: Colors.black12)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder rail = find.byType(ReaderSettingsHorizontalList);
    final Offset position = tester.getCenter(rail);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(of: rail, matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.pixels, greaterThan(0));
  });
}
