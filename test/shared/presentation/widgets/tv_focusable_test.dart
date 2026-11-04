/// Remote hold regressions: release, repeats, cancellation and menu handoff.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

void main() {
  testWidgets('ActivateIntent Actions invokes the focused control callback', (tester) async {
    var activated = 0;
    await _mount(tester, onPressed: () => activated++, onMore: null);

    Actions.invoke(tester.element(find.text('影片')), const ActivateIntent());

    expect(activated, 1);
  });

  for (final key in [
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  ]) {
    testWidgets('${key.debugName} short press opens content once on release', (tester) async {
      var opened = 0;
      var menus = 0;
      await _mount(tester, onPressed: () => opened++, onMore: () => menus++);
      await tester.sendKeyDownEvent(key);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.sendKeyRepeatEvent(key);
      expect(opened, 0);
      await tester.sendKeyUpEvent(key);
      await tester.pump(const Duration(seconds: 1));
      expect(opened, 1);
      expect(menus, 0);
    });

    testWidgets('${key.debugName} hold opens only the menu despite repeats', (tester) async {
      var opened = 0;
      var menus = 0;
      await _mount(tester, onPressed: () => opened++, onMore: () => menus++);
      await tester.sendKeyDownEvent(key);
      await tester.pump(const Duration(milliseconds: 650));
      expect(menus, 1);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(key);
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.sendKeyUpEvent(key);
      await tester.pumpAndSettle();
      expect(opened, 0);
      expect(menus, 1);
      await tester.sendKeyEvent(key);
      expect(opened, 1);
    });
  }

  testWidgets('moving focus cancels a pending menu and release does not activate the next control', (tester) async {
    var actions = 0;
    await _mount(tester, onPressed: () => actions++, onMore: () => actions++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(actions, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(actions, 1);
  });

  for (final change in ['disable', 'remove menu', 'dispose']) {
    testWidgets('$change cancels an outstanding hold', (tester) async {
      var actions = 0;
      await _mount(tester, onPressed: () => actions++, onMore: () => actions++);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 200));
      if (change == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      } else {
        await _mount(
          tester,
          onPressed: change == 'disable' ? null : () => actions++,
          onMore: change == 'remove menu' ? null : () => actions++,
        );
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      expect(actions, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('menu key cancels the hold and opens the menu immediately', (tester) async {
    var opened = 0;
    var menus = 0;
    await _mount(tester, onPressed: () => opened++, onMore: () => menus++);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(menus, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(menus, 1);
    expect(opened, 0);
  });
}

Future<void> _mount(WidgetTester tester, {required VoidCallback? onPressed, required VoidCallback? onMore}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: TvRemoteShortcuts(
        child: Scaffold(
          body: Column(
            children: [
              TvFocusable(autofocus: true, onPressed: onPressed, onMore: onMore, child: const Text('影片')),
              TvFocusable(onPressed: onPressed, child: const Text('下一项')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
