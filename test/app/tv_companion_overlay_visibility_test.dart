/// The TV entry leaves dialogs and pushed routes unobstructed; the phone entry
/// remains available for handing off the current video from its playback route.
/// Exercises the production root navigator with isolated settings/runtime ports.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_entry.dart';

import 'mg_read_app_test_support.dart';

void main() {
  for (final tvMode in [false, true]) {
    testWidgets('companion entry respects TV overlays and phone handoff with TV=$tvMode', (tester) async {
      final settings = await createTestAppSettings();
      addTearDown(settings.close);
      await settings.set(AppSettingKeys.tvMode, tvMode);
      await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
      await tester.pumpWidget(testMgReadApp(settings));
      await tester.pumpAndSettle();
      expect(find.byType(CompanionEntry), findsOneWidget);

      final navigator = appRootNavigatorKey.currentState!;
      final dialog = showDialog<void>(
        context: navigator.context,
        builder: (_) => const AlertDialog(
          title: Text('筛选'),
          actions: [TextButton(onPressed: null, child: Text('完成'))],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(CompanionEntry), tvMode ? findsNothing : findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      await dialog;
      expect(find.byType(CompanionEntry), findsOneWidget);

      final child = navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('设置子页面'))));
      await tester.pumpAndSettle();
      expect(find.text('设置子页面'), findsOneWidget);
      expect(find.byType(CompanionEntry), tvMode ? findsNothing : findsOneWidget);
      navigator.pop();
      await tester.pumpAndSettle();
      await child;
      expect(find.byType(CompanionEntry), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
