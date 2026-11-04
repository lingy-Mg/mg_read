/// Reader navigation never adds a floating TV connection entry.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';

import 'mg_read_app_test_support.dart';

void main() {
  testWidgets('keeps the phone companion entry absent on reader routes and return', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, false);
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);

    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '连接 TV'), findsNothing);

    final context = tester.element(find.byType(LibraryPage));
    const ReaderRoute(bookId: 'overlay-reader-test').go(context);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '连接 TV'), findsNothing);

    GoRouter.of(appRootNavigatorKey.currentContext!).go('/');
    await tester.pumpAndSettle();
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '连接 TV'), findsNothing);

    final libraryContext = tester.element(find.byType(LibraryPage));
    final pushedReader = const ReaderRoute(bookId: 'overlay-reader-pushed').push<void>(libraryContext);
    await tester.pumpAndSettle();
    expect(GoRouter.of(appRootNavigatorKey.currentContext!).state.uri.path, '/reader/overlay-reader-pushed');
    expect(find.widgetWithText(FilledButton, '连接 TV'), findsNothing);

    appRootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await pushedReader;
    expect(find.byType(LibraryPage), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '连接 TV'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
