/// Isolated Android TV acceptance for update focus and layered back handling.
/// Uses production dialog/navigation widgets with fixture metadata and injected
/// platform-back callbacks. No APK is downloaded or installed by these widgets.
/// Build with MGREAD_APPLICATION_ID_SUFFIX=tvqa and verify the APK before launch.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/app_tv_back_navigation.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/app_update/application/github_apk_update.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_prompt.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_tv_prompt.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import '../test/support/github_apk_release_fixture.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('TV update dialog is remotely reachable and back consumes only the visible overlay', (tester) async {
    expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'tvqa');
    final capture = GlobalKey();
    final router = GoRouter(
      navigatorKey: appRootNavigatorKey,
      initialLocation: '/profile',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Center(child: Text('影视首页'))),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, _) => const Scaffold(body: Center(child: Text('电视设置'))),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        theme: appTvTheme(AppTheme.dark()),
        builder: (_, child) => RepaintBoundary(
          key: capture,
          child: AppTvBackNavigation(
            router: router,
            enabled: true,
            child: TvModeScope(
              enabled: true,
              onChanged: (_) {},
              child: TvRemoteShortcuts(child: child!),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final size = MediaQuery.sizeOf(tester.element(find.text('电视设置')));
    binding.reportData = {
      'screen': {'width': size.width, 'height': size.height},
    };

    final first = showGitHubApkUpdatePrompt(appRootNavigatorKey.currentContext!, githubApkReleaseFixture);
    await tester.pumpAndSettle();
    expect(_focusedKey(), const Key('github-apk-update-later'));
    await _capture(binding, capture, 'tv-update-dialog');
    await _press(tester, LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
    expect(_focusedKey(), const Key('github-apk-update-install'));
    await _press(tester, LogicalKeyboardKey.select, PhysicalKeyboardKey.enter);
    expect(await first, isTrue);
    expect(router.routeInformationProvider.value.uri.path, '/profile');

    final notesDialog = showDialog<bool>(
      context: appRootNavigatorKey.currentContext!,
      builder: (context) => GitHubApkUpdateTvPrompt(
        notes: List.generate(80, (i) => '第 $i 项：优化电视操作与显示。').join('\n'),
        onOpenRelease: () {},
        onLater: () => Navigator.of(context).pop(false),
        onInstall: () => Navigator.of(context).pop(true),
      ),
    );
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowUp, PhysicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.arrowDown, PhysicalKeyboardKey.arrowDown);
    final notesScroll = find
        .descendant(of: find.byKey(const Key('github-apk-update-notes-scroll')), matching: find.byType(Scrollable))
        .first;
    expect(tester.state<ScrollableState>(notesScroll).position.pixels, greaterThan(0));
    await _press(tester, LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
    expect(_focusedKey(), const Key('github-apk-update-later'));
    await _capture(binding, capture, 'tv-update-long-notes');
    await _press(tester, LogicalKeyboardKey.select, PhysicalKeyboardKey.enter);
    expect(await notesDialog, isFalse);

    final second = showGitHubApkUpdatePrompt(appRootNavigatorKey.currentContext!, githubApkReleaseFixture);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await second, isNull);
    expect(router.routeInformationProvider.value.uri.path, '/profile');

    final third = showGitHubApkUpdatePrompt(appRootNavigatorKey.currentContext!, githubApkReleaseFixture);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await third, isNull);
    expect(router.routeInformationProvider.value.uri.path, '/profile');

    final finish = Completer<void>();
    final progress = showGitHubApkUpdateInstallProgress(appRootNavigatorKey.currentContext!, (onProgress) async {
      onProgress(const GitHubApkDownloadProgress(receivedBytes: 50, totalBytes: 100));
      await finish.future;
    });
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('正在下载更新'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    await _capture(binding, capture, 'tv-update-download-back-blocked');
    finish.complete();
    await tester.pumpAndSettle();
    await progress;
    expect(find.text('正在下载更新'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    binding.reportData!['passed'] = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }, timeout: const Timeout(Duration(minutes: 2)));
}

Key? _focusedKey() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey logical, PhysicalKeyboardKey physical) async {
  await tester.sendKeyEvent(logical, physicalKey: physical);
  await tester.pumpAndSettle();
}

Future<void> _capture(IntegrationTestWidgetsFlutterBinding binding, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final frame = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
    final screenshots = binding.reportData!.putIfAbsent('tvScreenshots', () => <String, String>{}) as Map<String, String>;
    screenshots[name] = base64Encode(bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  } finally {
    frame.dispose();
  }
}
