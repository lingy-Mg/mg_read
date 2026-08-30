/// 二级页面共享内容壳测试。
///
/// 职责：
/// - 验证统一顶部节奏与窄宽/宽屏内容边界。
///
/// 注意：
/// - 仅验证确定性的组件几何，不替代页面或设备验收。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

void main() {
  testWidgets('uses compact and wide secondary-page content widths', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    expect(tester.getRect(find.byKey(_contentKey)), const Rect.fromLTRB(0, 0, 390, 900));

    await _setViewport(tester, const Size(1280, 900));
    await tester.pump();
    expect(
      tester.getRect(find.byKey(_contentKey)),
      Rect.fromLTRB((1280 - AppSpacing.contentMaxWidth) / 2, 0, (1280 + AppSpacing.contentMaxWidth) / 2, 900),
    );
  });

  testWidgets('uses only the system inset on Android', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(topInset: 24));

    expect(tester.getRect(find.byKey(_contentKey)).top, 24);
  });

  testWidgets('retains the eight-dp rhythm outside Android', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host(platform: TargetPlatform.windows, topInset: 24));

    expect(tester.getRect(find.byKey(_contentKey)).top, 24 + AppSpacing.pageHeaderTopPadding);
  });
}

const Key _contentKey = Key('secondary-page-content-test');

Widget _host({TargetPlatform platform = TargetPlatform.android, double topInset = 0}) => MaterialApp(
  theme: AppTheme.light().copyWith(platform: platform),
  builder: (BuildContext context, Widget? child) {
    final MediaQueryData mediaQuery = MediaQuery.of(context);
    return MediaQuery(
      data: mediaQuery.copyWith(
        padding: EdgeInsets.only(top: topInset),
        viewPadding: EdgeInsets.only(top: topInset),
      ),
      child: child ?? const SizedBox.shrink(),
    );
  },
  home: Scaffold(
    body: SafeArea(
      bottom: false,
      child: AppSecondaryPageContent(child: const SizedBox.expand(key: _contentKey)),
    ),
  ),
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
