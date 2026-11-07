/// TV pagination follows remote scrolling in the home and nested category view.
/// Controlled page completion verifies serialization, retry, exhaustion and focus
/// without a real Runtime, source network or platform player.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_tv_pagination.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

import '../../../support/tv_discovery_pagination_fixture.dart';

void main() {
  testWidgets('TV starts the next page with two screens still ahead and keeps focus', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 112);
    await _mount(tester, page);
    await _settle(tester);
    expect(page.requests, isEmpty);
    final focused = _cardFocus(tester, 'videos-0')..requestFocus();
    await _settle(tester);
    final scrollable = find.byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down).first;
    final scroll = tester.state<ScrollableState>(scrollable).position;
    final viewport = tester.getRect(scrollable);
    final footer = find.byType(DiscoveryTvPaginationFooter);
    final footerTop = tester.getTopLeft(footer).dy - viewport.top;
    scroll.jumpTo(footerTop - viewport.height * 2.75);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(footer).dy - viewport.top, greaterThan(viewport.height * 2));
    expect(page.requests, [('videos', '2')], reason: 'loading starts well before the last half-screen');
    expect(FocusManager.instance.primaryFocus, same(focused));
    page.complete(add: 28);
    await _settle(tester);
    expect(page.requests, hasLength(1));
    expect(FocusManager.instance.primaryFocus, same(focused));
    expect(tester.takeException(), isNull);
  });

  for (final depth in [0, 1]) {
    testWidgets('TV depth $depth loads near the end without OK and retains content focus', (tester) async {
      final page = TvDiscoveryPaginationFixture(depth: depth, count: 84);
      await _mount(tester, page);
      await _settle(tester);
      expect(page.requests, isEmpty);
      expect(find.byKey(const ValueKey('runtime-discovery-load-more-videos')), findsNothing);
      _cardFocus(tester, 'videos-0').requestFocus();
      await _settle(tester);
      for (var step = 0; step < 20 && page.requests.isEmpty; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(page.requests, [('videos', '2')]);
      for (var step = 0; step < 4; step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(page.requests, hasLength(1));
      final focused = FocusManager.instance.primaryFocus;
      page.complete(add: 14);
      await _settle(tester);
      expect(FocusManager.instance.primaryFocus, same(focused));
      expect(find.byKey(const ValueKey('runtime-discovery-cover-videos-97')), findsOneWidget);
      expect(page.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short TV pages continue filling the viewport until the cursor ends', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1);
    await _mount(tester, page);
    expect(page.requests, [('videos', '2')]);
    page.complete(add: 1, next: '3');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.requests, [('videos', '2'), ('videos', '3')]);
    page.complete(add: 1);
    await _settle(tester);
    expect(page.requests, hasLength(2));
    expect(find.text('正在加载下一页…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed page stops automatic retries and OK returns focus to content', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1);
    await _mount(tester, page);
    final content = _cardFocus(tester, 'videos-0')..requestFocus();
    await tester.pump();
    page.complete(add: 0, next: '2');
    await _settle(tester);
    expect(page.requests, hasLength(1));
    expect(find.byKey(const ValueKey('runtime-discovery-retry-videos')), findsOneWidget);
    page.rebuild();
    await _settle(tester);
    expect(page.requests, hasLength(1));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 250));
    expect(FocusManager.instance.primaryFocus, isNot(content));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.requests, [('videos', '2'), ('videos', '2')]);
    page.complete(add: 2);
    await _settle(tester);
    expect(FocusManager.instance.primaryFocus, same(content));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty page with an advancing cursor still loads the next page', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1);
    await _mount(tester, page);
    page.complete(add: 0, next: '3');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.requests, [('videos', '2'), ('videos', '3')]);
    page.complete();
    await _settle(tester);
    expect(find.byKey(const ValueKey('runtime-discovery-retry-videos')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing category resets an attempted cursor shared by both categories', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1);
    await _mount(tester, page);
    page.complete(add: 0, next: '2');
    await _settle(tester);
    page.target = 'other';
    page.rebuild();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.requests, [('videos', '2'), ('videos', '2')]);
    page.complete();
    await _settle(tester);
  });

  testWidgets('automatic pagination waits for category replacement to finish', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1)..replacing = true;
    await _mount(tester, page);
    expect(page.requests, isEmpty);
    page.replacing = false;
    page.rebuild();
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.requests, hasLength(1));
    page.complete();
    await _settle(tester);
  });

  testWidgets('multiple visible collections request pages serially', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1)
      ..counts['other'] = 1
      ..cursors['other'] = '2';
    await _mount(tester, page);
    expect(page.requests, [('videos', '2')]);
    page.complete(add: 1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(page.requests, [('videos', '2'), ('other', '2')]);
    page.complete(add: 1);
    await _settle(tester);
    expect(page.requests, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary discovery retains explicit pagination', (tester) async {
    final page = TvDiscoveryPaginationFixture(count: 1, tv: false);
    await _mount(tester, page);
    await _settle(tester);
    expect(page.requests, isEmpty);
    await tester.tap(find.byKey(const ValueKey('runtime-discovery-load-more-videos')));
    await tester.pump();
    expect(page.requests, [('videos', '2')]);
    page.complete();
    await _settle(tester);
  });
}

Future<void> _mount(WidgetTester tester, TvDiscoveryPaginationFixture page) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(page.widget);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));

FocusNode _cardFocus(WidgetTester tester, String id) {
  final card = find.ancestor(of: find.byKey(ValueKey('runtime-discovery-cover-$id')), matching: find.byType(TvFocusable)).first;
  return tester.widget<Focus>(find.descendant(of: card, matching: find.byType(Focus)).first).focusNode!;
}
