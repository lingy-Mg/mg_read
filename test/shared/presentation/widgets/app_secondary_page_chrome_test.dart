import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

void main() {
  testWidgets('uses compact and wide secondary-page content widths', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_host());
    expect(
      tester.getRect(find.byKey(_contentKey)),
      const Rect.fromLTWH(0, 0, 390, 900),
    );

    await _setViewport(tester, const Size(1280, 900));
    await tester.pump();
    expect(
      tester.getRect(find.byKey(_contentKey)),
      Rect.fromLTWH(
        (1280 - AppSpacing.contentMaxWidth) / 2,
        0,
        AppSpacing.contentMaxWidth,
        900,
      ),
    );
  });
}

const Key _contentKey = Key('secondary-page-content-test');

Widget _host() => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(
    body: AppSecondaryPageContent(
      child: const SizedBox.expand(key: _contentKey),
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
