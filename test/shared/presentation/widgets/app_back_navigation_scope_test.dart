import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/shared/presentation/widgets/app_back_navigation_scope.dart';

void main() {
  testWidgets('TV coalesces repeated platform-only callbacks but accepts a subsequent gesture', (tester) async {
    final dispatcher = RootBackButtonDispatcher();
    Future<bool> fallback() async => false;
    dispatcher.addCallback(fallback);
    addTearDown(() => dispatcher.removeCallback(fallback));
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppBackNavigationScope(
          backButtonDispatcher: dispatcher,
          captureBackKeys: true,
          onBackRequested: () async {
            calls++;
            return true;
          },
          child: const Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await dispatcher.invokeCallback(Future.value(false));
    await dispatcher.invokeCallback(Future.value(false));
    await tester.pump(const Duration(milliseconds: 40));
    await dispatcher.invokeCallback(Future.value(false));
    expect(calls, 1);
    await tester.pump(const Duration(milliseconds: 250));
    await dispatcher.invokeCallback(Future.value(false));
    expect(calls, 2);
  });

  testWidgets('captured back keys dispatch once before child shortcuts and release on mode change', (tester) async {
    var rootCalls = 0;
    var childCalls = 0;
    Widget host(bool capture) => MaterialApp(
      home: AppBackNavigationScope(
        captureBackKeys: capture,
        onBackRequested: () async {
          rootCalls++;
          return true;
        },
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => childCalls++},
          child: const Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpWidget(host(true));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(rootCalls, 1);
    expect(childCalls, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(rootCalls, 2);
    await tester.pumpWidget(host(false));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(childCalls, 1);
    expect(rootCalls, 2);
  });

  testWidgets('mouse side-back button requests the shared back action', (WidgetTester tester) async {
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
    tester.binding.handlePointerEvent(pointer.down(const Offset(10, 10), buttons: kBackMouseButton));
    await tester.pump();

    expect(requestCount, 1);
  });
}
