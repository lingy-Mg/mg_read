/// 继续阅读按钮在低进度和无确定进度时的文字对比与命中区回归。
/// 只渲染本地组件，不读取书架、封面网络或播放器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_continue_reading_card.dart';

void main() {
  for (final color in AppThemeColor.values) {
    testWidgets('low progress remains legible in day palette ${color.id}', (tester) async {
      await _verify(tester, AppTheme.light(color: color));
    });
  }
  for (final color in AppDarkThemeColor.values) {
    testWidgets('low progress remains legible in night palette ${color.id}', (tester) async {
      await _verify(tester, AppTheme.dark(color: color));
    });
  }
  testWidgets('an action without determinate progress retains its contrast', (tester) async {
    await _verify(tester, AppTheme.light(), determinate: false);
    expect(find.byKey(const Key('continue-reading-cta-progress-fill')), findsNothing);
  });
}

Future<void> _verify(WidgetTester tester, ThemeData theme, {bool determinate = true}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 320,
            child: LibraryContinueReadingCard(
              data: LibraryContinueReadingViewData(
                bookId: 'contrast-book',
                title: '对比度测试',
                chapter: '第一章',
                progress: 0.05,
                hasDeterminateProgress: determinate,
                lastReadLabel: '刚刚',
                coverVariant: LibraryCoverVariant.dusk,
              ),
              onContinueReading: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final action = find.byKey(const Key('continue-reading-cta'));
  final label = tester.widget<Text>(find.descendant(of: action, matching: find.byType(Text)));
  final background = tester.widget<ColoredBox>(find.byKey(const Key('continue-reading-cta-track'))).color;
  expect(_contrast(label.style!.color!, background), greaterThanOrEqualTo(4.5));
  if (determinate) {
    final overlay = tester.widget<ColoredBox>(find.byKey(const Key('continue-reading-cta-progress-fill'))).color;
    expect(_contrast(label.style!.color!, Color.alphaBlend(overlay, background)), greaterThanOrEqualTo(4.5));
  }
  expect(tester.getSize(action).height, greaterThanOrEqualTo(AppSpacing.minimumTouchTarget));
  expect(tester.takeException(), isNull);
}

double _contrast(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
}
