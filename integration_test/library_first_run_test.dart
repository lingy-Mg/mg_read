import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/app/app.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first-run home matches the light empty bookshelf design', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle();

    expect(find.text('首页'), findsAtLeastNWidgets(1));
    expect(find.text('开始你的阅读旅程'), findsOneWidget);
    expect(find.text('当前还没有阅读记录'), findsOneWidget);
    expect(find.text('暂无更新内容'), findsOneWidget);
    expect(find.text('去发现好书'), findsOneWidget);
    expect(find.byType(Image), findsAtLeastNWidgets(2));

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('library_first_run_light');
  });
}
