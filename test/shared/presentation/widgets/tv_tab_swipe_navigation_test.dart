/// Touch gesture arbitration and route isolation for TV tab navigation.
/// Host gestures cover intent handling; tablet hardware needs device acceptance.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_tab_swipe_navigation.dart';

void main() {
  testWidgets('slow swipes and quick flicks select one adjacent tab', (tester) async {
    final selections = <AppNavigationDestination>[];
    await _mount(tester, onSelected: selections.add);
    await tester.timedDrag(find.byKey(_content), const Offset(-160, 0), const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(selections, [AppNavigationDestination.profile]);
    selections.clear();
    await tester.fling(find.byKey(_content), const Offset(60, 0), 1000);
    await tester.pumpAndSettle();
    expect(selections, [AppNavigationDestination.home]);
  });

  testWidgets('small movements, vertical drags and cancelled drags do not switch', (tester) async {
    final selections = <AppNavigationDestination>[];
    await _mount(tester, onSelected: selections.add);
    await tester.timedDrag(find.byKey(_content), const Offset(-45, 0), const Duration(seconds: 1));
    expect(selections, isEmpty);
    await tester.drag(find.byKey(_content), const Offset(0, -180));
    expect(selections, isEmpty);
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(_content)));
    await gesture.moveBy(const Offset(-160, 0));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('first and last tabs do not wrap', (tester) async {
    final selections = <AppNavigationDestination>[];
    await _mount(tester, selected: AppNavigationDestination.home, onSelected: selections.add);
    await tester.drag(find.byKey(_content), const Offset(180, 0));
    await _mount(tester, selected: AppNavigationDestination.search, onSelected: selections.add);
    await tester.drag(find.byKey(_content), const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  testWidgets('ordinary mode and mouse drags retain their existing behavior', (tester) async {
    final selections = <AppNavigationDestination>[];
    await _mount(tester, enabled: false, onSelected: selections.add);
    await tester.drag(find.byKey(_content), const Offset(-180, 0));
    await _mount(tester, onSelected: selections.add);
    await tester.drag(find.byKey(_content), const Offset(-180, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });

  for (final axis in Axis.values) {
    testWidgets('$axis scrollables keep their touch drags', (tester) async {
      final selections = <AppNavigationDestination>[];
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await _mount(
        tester,
        onSelected: selections.add,
        child: ListView.builder(
          key: _content,
          controller: scroll,
          scrollDirection: axis,
          itemExtent: 100,
          itemCount: 30,
          itemBuilder: (_, index) => Text('item $index'),
        ),
      );
      await tester.drag(find.byKey(_content), axis == Axis.horizontal ? const Offset(-180, 0) : const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      expect(selections, isEmpty);
    });
  }

  testWidgets('dialogs and pushed detail routes keep touch input inside their route', (tester) async {
    final selections = <AppNavigationDestination>[];
    await _mount(tester, onSelected: selections.add);
    final context = tester.element(find.byKey(_content));
    final navigator = Navigator.of(context);
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          width: 320,
          height: 200,
          child: ColoredBox(key: Key('dialog'), color: Colors.transparent),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('dialog')), const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    navigator.pop();
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          body: ColoredBox(key: Key('detail'), color: Colors.transparent, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const Key('detail')), const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
  });
}

const _content = Key('content');

Future<void> _mount(
  WidgetTester tester, {
  required ValueChanged<AppNavigationDestination> onSelected,
  AppNavigationDestination selected = AppNavigationDestination.discover,
  bool enabled = true,
  Widget child = const ColoredBox(key: _content, color: Colors.transparent, child: SizedBox.expand()),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: TvModeScope(
        enabled: enabled,
        onChanged: (_) {},
        child: TvTabSwipeNavigation(
          selected: selected,
          onSelected: onSelected,
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
