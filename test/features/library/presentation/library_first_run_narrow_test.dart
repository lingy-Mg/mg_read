/// Regression for the welcome hero overflow observed on the Android emulator.
/// Exercises the production empty shelf at phone widths without hiding errors.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';

void main() {
  for (final width in <double>[320, 360, 390]) {
    testWidgets('first-run welcome fits a $width pixel phone', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: LibraryHomeShell(data: LibraryHomeViewData.empty(), isRefreshing: false, onRefresh: () async {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('欢迎来到 MgRead'), findsOneWidget);
      final title = tester.getRect(find.text('从一本书开始，\n发现更大的世界'));
      final welcome = tester.getRect(find.byKey(const Key('library-first-run-welcome')));
      expect(welcome.contains(title.topLeft), isTrue);
      expect(welcome.contains(title.bottomRight), isTrue);
    });
  }
}
