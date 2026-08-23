import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/shared/presentation/widgets/app_back_navigation_scope.dart';

void main() {
  testWidgets('mouse side-back button requests the shared back action', (
    WidgetTester tester,
  ) async {
    var requestCount = 0;
    await tester.pumpWidget(
      AppBackNavigationScope(
        onBackRequested: () async {
          requestCount++;
          return true;
        },
        child: const SizedBox.expand(),
      ),
    );

    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    tester.binding.handlePointerEvent(
      pointer.down(const Offset(10, 10), buttons: kBackMouseButton),
    );
    await tester.pump();

    expect(requestCount, 1);
  });
}
