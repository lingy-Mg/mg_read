/// Android TV pagination acceptance in the device's actual landscape window.
/// Controlled source pages exercise the production discovery renderer with
/// directional keys, cursor completion and stable focus; no Runtime is started.
/// Install only a verified tvpaginationqa profile APK and drive it using
/// --use-application-binary --keep-app-running to protect formal application data.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

import '../test/support/tv_discovery_pagination_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final depth in [0, 1]) {
    testWidgets('Android TV discovery depth $depth appends by Down without OK', (tester) async {
      expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'tvpaginationqa');
      final page = TvDiscoveryPaginationFixture(count: 56, depth: depth);
      await tester.pumpWidget(page.widget);
      await _settle(tester);
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(size.width, greaterThan(size.height));
      expect(page.requests, isEmpty);
      expect(find.byKey(const Key('runtime-discovery-load-more-videos')), findsNothing);
      final first = find.ancestor(of: find.byKey(const Key('runtime-discovery-cover-videos-0')), matching: find.byType(TvFocusable));
      tester.widget<Focus>(find.descendant(of: first, matching: find.byType(Focus)).first).focusNode!.requestFocus();
      await _settle(tester);
      var downKeys = 0;
      for (final cursor in ['2', '3']) {
        for (var step = 0; step < 35 && page.requests.length < int.parse(cursor) - 1; step++) {
          await _down(tester);
          downKeys++;
        }
        expect(page.requests.last, ('videos', cursor));
        final count = page.requests.length;
        for (var step = 0; step < 3; step++) {
          await _down(tester);
          downKeys++;
        }
        expect(page.requests, hasLength(count), reason: 'pending pages must not be requested twice');
        final focused = FocusManager.instance.primaryFocus;
        page.complete(add: 14, next: cursor == '2' ? '3' : null);
        await _settle(tester);
        expect(FocusManager.instance.primaryFocus, same(focused));
      }
      expect(page.requests, [('videos', '2'), ('videos', '3')]);
      expect(page.counts['videos'], 84);
      expect(find.byKey(const Key('runtime-discovery-cover-videos-83')), findsOneWidget);
      await _capture(tester, binding, page.captureKey, 'tv-pagination-depth-$depth');
      binding.reportData ??= {};
      final cases = binding.reportData!.putIfAbsent('paginationCases', () => <String, Object?>{}) as Map<String, Object?>;
      cases['depth-$depth'] = {
        'logicalWidth': size.width,
        'logicalHeight': size.height,
        'downKeys': downKeys,
        'confirmKeys': 0,
        'cursors': page.requests.map((request) => request.$2).toList(),
        'items': page.counts['videos'],
        'focusRetained': true,
      };
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}

Future<void> _down(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown, physicalKey: PhysicalKeyboardKey.arrowDown);
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));

Future<void> _capture(WidgetTester tester, IntegrationTestWidgetsFlutterBinding binding, GlobalKey key, String name) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final frame = await boundary.toImage(pixelRatio: 1);
    try {
      final raw = await frame.toByteData();
      if (raw == null) continue;
      final pixels = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
      var visible = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i] > 32 || pixels[i + 1] > 32 || pixels[i + 2] > 32) visible++;
        if (visible > 1000) break;
      }
      if (visible <= 1000) continue;
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
      binding.reportData ??= {};
      final screenshots = binding.reportData!.putIfAbsent('tvScreenshots', () => <String, String>{}) as Map<String, String>;
      screenshots[name] = base64Encode(bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      return;
    } finally {
      frame.dispose();
    }
  }
  fail('Android TV pagination frame remained blank: $name');
}
