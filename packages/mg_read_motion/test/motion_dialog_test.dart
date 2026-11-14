/// 对话框静态表面、键盘避让和运行中策略变化回归；不访问网络或平台窗口。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_motion/mg_read_motion.dart';

void main() {
  testWidgets(
    'dialog insets and theme apply instantly while editor state is retained',
    (tester) async {
      final controller = TextEditingController(text: '保留输入');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      Widget host({
        required bool disabled,
        bool dark = false,
        double inset = 0,
      }) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: disabled,
            viewInsets: EdgeInsets.only(bottom: inset),
          ),
          child: MotionTheme(
            data: dark ? ThemeData.dark() : ThemeData.light(),
            child: MotionAlertDialog(
              title: const Text('提示'),
              content: MotionTextField(
                controller: controller,
                focusNode: focus,
              ),
              actions: [TextButton(onPressed: () {}, child: const Text('确定'))],
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(disabled: false));
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      final editor = tester.state<EditableTextState>(find.byType(EditableText));
      await tester.pumpWidget(host(disabled: true));
      await tester.pump();
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editor),
      );
      expect(focus.hasPrimaryFocus, isTrue);
      expect(controller.text, '保留输入');
      final beforeInset = tester.getRect(find.text('提示'));
      await tester.pumpWidget(host(disabled: true, dark: true, inset: 160));
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      final position = tester.getRect(find.text('提示'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(find.text('提示')), position);
      expect(position.top, lessThan(beforeInset.top));
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
