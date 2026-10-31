/// Checks TV field traversal without changing ordinary editing or caret keys.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_text_input_navigation.dart';

void main() {
  for (final enabled in [false, true]) {
    testWidgets('field navigation preserves caret editing with TV=$enabled', (tester) async {
      final first = FocusNode();
      final second = FocusNode();
      final text = TextEditingController(text: '电影查询');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: TvModeScope(
            enabled: enabled,
            onChanged: (_) {},
            child: Scaffold(
              body: Column(
                children: [
                  TvTextInputNavigation(
                    child: TextField(focusNode: first, controller: text),
                  ),
                  TvTextInputNavigation(child: TextField(focusNode: second)),
                ],
              ),
            ),
          ),
        ),
      );
      first.requestFocus();
      text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(text.selection.baseOffset, 2);
      expect(first.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(second.hasFocus, enabled);
      if (enabled) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(first.hasFocus, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
