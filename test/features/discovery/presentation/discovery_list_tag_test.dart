/// 发现列表标签的浅色布局测试。
///
/// 职责：
/// - 验证标签保持紧凑尺寸。
/// - 验证标签文字字号和水平、垂直居中布局。
///
/// 注意：
/// - 只覆盖隔离展示组件，不替代页面或 Android Integration Test。
/// - 测试固定使用浅色主题。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_list_tag.dart';

void main() {
  testWidgets('keeps discovery list tags compact and centered', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Center(
            child: Wrap(
              children: <Widget>[DiscoveryListTag(label: '东方玄幻')],
            ),
          ),
        ),
      ),
    );

    final Finder tagFinder = find.byType(DiscoveryListTag);
    final Finder textFinder = find.text('东方玄幻');
    final Rect tagRect = tester.getRect(tagFinder);
    final Rect textRect = tester.getRect(textFinder);
    final Text text = tester.widget<Text>(textFinder);

    expect(tagRect.height, 18);
    expect(tagRect.width, lessThan(80));
    expect(text.style?.fontSize, AppTypography.discoveryListTag);
    expect(textRect.center.dx, closeTo(tagRect.center.dx, 0.01));
    expect(textRect.center.dy, closeTo(tagRect.center.dy, 0.01));
  });
}
