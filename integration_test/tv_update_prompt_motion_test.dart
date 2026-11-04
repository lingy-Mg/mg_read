/// Isolated Android acceptance for the TV release-notes scrolling regression.
/// Uses the production prompt with both motion preferences in the real window,
/// without starting application services. Captures Flutter frames via reportData.
/// Build arm64 profile with MGREAD_APPLICATION_ID_SUFFIX=tvpromptqa, verify the
/// APK package, and drive with --use-application-binary --keep-app-running.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_tv_prompt.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final disabled in [false, true]) {
    testWidgets('Android TV notes scroll and return with disableAnimations=$disabled', (tester) async {
      expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'tvpromptqa');
      final capture = GlobalKey();
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTvTheme(AppTheme.dark()),
          builder: (context, child) => RepaintBoundary(
            key: capture,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: disabled),
              child: TvModeScope(
                enabled: true,
                onChanged: (_) {},
                child: TvRemoteShortcuts(child: child!),
              ),
            ),
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  autofocus: true,
                  onPressed: () async {
                    result = await showDialog<bool>(
                      context: context,
                      builder: (context) => GitHubApkUpdateTvPrompt(
                        notes: List.generate(80, (i) => '第 $i 项：优化电视操作与显示。').join('\n'),
                        onOpenRelease: () {},
                        onLater: () => Navigator.of(context).pop(false),
                        onInstall: () => Navigator.of(context).pop(true),
                      ),
                    );
                  },
                  child: const Text('检查更新'),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      await _press(tester, LogicalKeyboardKey.select);
      expect(find.byKey(const Key('github-apk-update-prompt')), findsOneWidget);
      expect(_focusedKey(), const Key('github-apk-update-later'));
      await _press(tester, LogicalKeyboardKey.arrowUp);
      await _press(tester, LogicalKeyboardKey.arrowDown);
      final notes = find.descendant(of: find.byKey(const Key('github-apk-update-notes-scroll')), matching: find.byType(Scrollable)).first;
      final position = tester.state<ScrollableState>(notes).position;
      expect(position.pixels, greaterThan(0));
      expect(find.byKey(const Key('github-apk-update-install')).hitTestable(), findsOneWidget);
      await _capture(tester, binding, capture, 'tv-notes-motion-disabled-$disabled');
      binding.reportData ??= {};
      final cases = binding.reportData!.putIfAbsent('motionCases', () => <String, Object?>{}) as Map<String, Object?>;
      cases['$disabled'] = {'offset': position.pixels, 'scrollExtent': position.maxScrollExtent};
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusedKey(), const Key('github-apk-update-later'));
      await _press(tester, LogicalKeyboardKey.select);
      expect(result, isFalse);
      expect(find.byKey(const Key('github-apk-update-prompt')), findsNothing);
      expect(find.text('检查更新'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    }, timeout: const Timeout(Duration(minutes: 1)));
  }
}

Key? _focusedKey() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key;

Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 15));

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(
    key,
    physicalKey: {
      LogicalKeyboardKey.select: PhysicalKeyboardKey.enter,
      LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    }[key],
  );
  await _settle(tester);
}

Future<void> _capture(WidgetTester tester, IntegrationTestWidgetsFlutterBinding binding, GlobalKey key, String name) async {
  // Native profile readbacks can be empty after the animation scheduler settles.
  // Retry a bounded number of frames and reject blank visual evidence.
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
      final attempts = binding.reportData!.putIfAbsent('captureAttempts', () => <String, int>{}) as Map<String, int>;
      attempts[name] = attempt + 1;
      return;
    } finally {
      frame.dispose();
    }
  }
  fail('The native prompt frame stayed blank: $name');
}
