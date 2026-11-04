/// Regression for content aligned under an inactive source tab and root reset.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/tv_source_navigation_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_region.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/widgets/tv_top_navigation.dart';

void main() {
  testWidgets('Up from the right side returns only to Home and back resets the full scroll', (tester) async {
    final scroll = ScrollController();
    final home = FocusNode();
    final content = FocusNode();
    addTearDown(scroll.dispose);
    addTearDown(home.dispose);
    addTearDown(content.dispose);
    var sourceSelections = 0;
    var refreshes = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TvModeScope(
          onChanged: (_) async {},
          enabled: true,
          child: TvSourceNavigationScope(
            sourceId: 'sakura',
            target: null,
            showContent: false,
            entries: const [TvSourceNavigationEntry(label: '樱花动漫', target: null)],
            onSelected: (_) => sourceSelections++,
            child: TvFocusRegion(
              child: Scaffold(
                body: Column(
                  children: [
                    TvTopNavigation(
                      selected: AppNavigationDestination.home,
                      homeFocusNode: home,
                      onHomeReselected: () => refreshes++,
                      onSelected: (_) {},
                    ),
                    Expanded(
                      child: ListView(
                        controller: scroll,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: TvFocusable(focusNode: content, onPressed: () {}, child: const Text('内容')),
                          ),
                          for (var i = 0; i < 25; i++)
                            SizedBox(
                              height: 100,
                              child: TvFocusable(onPressed: () {}, child: Text('内容 $i')),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    content.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(home.hasFocus, isTrue);
    expect(sourceSelections, 0);
    expect(refreshes, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    content.requestFocus();
    await tester.pumpAndSettle();
    scroll.jumpTo(900);
    await tester.pumpAndSettle();
    expect(TvFocusRegion.returnToNavigation(), isTrue);
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    expect(home.hasFocus, isTrue);
    expect(TvFocusRegion.returnToNavigation(), isFalse);
    expect(sourceSelections, 0);
    expect(refreshes, 1);
  });
}
