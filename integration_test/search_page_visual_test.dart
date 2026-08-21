import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/app/app.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search reference preview renders in light mode', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle(const Duration(seconds: 45));

    await tester.tap(find.byKey(const Key('app-nav-search')));
    await tester.pumpAndSettle(const Duration(seconds: 45));

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.text('诡秘之主'), findsWidgets);
    expect(find.byKey(const Key('search-page-scroll')), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('search_page_reference_light');
  });
}
