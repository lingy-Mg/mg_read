/// MuMu landscape acceptance through real Android windows and Flutter keys.
/// Bootstraps the production app in the isolated tvqa package, then exercises
/// source-driven navigation with deterministic metadata (no source/network claim).
/// Captures Flutter frames through reportData; never overwrites existing apps.
/// Build arm64 profile with MGREAD_APPLICATION_ID_SUFFIX=tvqa; verify the APK
/// package before drive --use-application-binary --keep-app-running.
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/mg_read_app.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import 'package:mg_read/features/tv_companion/presentation/companion_entry.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

import '../test/app/mg_read_app_test_support.dart';
import '../test/support/tv_discovery_test_fixture.dart';
import 'tv_media_adaptation_test.dart' as media;
import 'tv_update_dialog_navigation_test.dart' as updates;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('MuMu production startup, TV destinations, settings and search', (tester) async {
    expect(const String.fromEnvironment('MGREAD_APPLICATION_ID_SUFFIX'), 'tvqa');
    addTearDown(() => _unmount(tester));
    Widget? app;
    final capture = GlobalKey();
    await bootstrapMgReadApp(televisionDetector: () async => true, appRunner: (widget) => app = widget);
    await tester.pumpWidget(RepaintBoundary(key: capture, child: app!));
    await _settle(tester);
    expect(find.byType(TvLibraryShell), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(MgReadApp)));
    final settings = container.read(appSettingsProvider);
    final router = container.read(appRouterProvider);
    final size = MediaQuery.sizeOf(tester.element(find.byType(TvLibraryShell)));
    expect(size.width, greaterThan(size.height));
    binding.reportData = {
      'window': {
        'width': size.width,
        'height': size.height,
        'devicePixelRatio': tester.view.devicePixelRatio,
        'physicalWidth': tester.view.physicalSize.width,
        'physicalHeight': tester.view.physicalSize.height,
        'disableAnimations': MediaQuery.disableAnimationsOf(tester.element(find.byType(TvLibraryShell))),
      },
    };
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    await _capture(binding, capture, 'mumu-tv-home');
    _focus(tester, find.byKey(const Key('app-nav-home'))).requestFocus();
    await _settle(tester);
    for (final entry in {'discover': '/discover', 'profile': '/profile', 'search': '/profile'}.entries) {
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(router.routeInformationProvider.value.uri.path, entry.value);
      expect(FocusManager.instance.primaryFocus, _focus(tester, find.byKey(Key('app-nav-${entry.key}'))));
      if (entry.key == 'discover') await _capture(binding, capture, 'mumu-tv-empty-sources');
      if (entry.key == 'profile') await _capture(binding, capture, 'mumu-tv-settings-playback');
    }
    await _press(tester, LogicalKeyboardKey.select);
    expect(router.routeInformationProvider.value.uri.path, '/search');
    final query = tester.widget<TextField>(find.byKey(const Key('source-search-query')));
    query.focusNode!.requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(query.focusNode!.hasFocus, isFalse, reason: 'Remote navigation must leave the search input.');
    await _capture(binding, capture, 'mumu-tv-search');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(router.routeInformationProvider.value.uri.path, '/');

    _focus(tester, find.byKey(const Key('app-nav-profile'))).requestFocus();
    await _settle(tester);
    _focus(tester, find.byKey(const Key('tv-settings-section-0'))).requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focusedKey(), const Key('tv-settings-section-1'));
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focusedKey(), const Key('tv-setting-theme-appearance'));
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('appearance-tv-mode')), findsOneWidget);
    expect(find.byType(CompanionEntry), findsNothing);
    await _capture(binding, capture, 'mumu-tv-appearance');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    expect(find.byType(CompanionEntry), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(router.routeInformationProvider.value.uri.path, '/');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('再按一次返回键退出应用'), findsOneWidget);
    await _capture(binding, capture, 'mumu-tv-exit-prompt');
    expect(tester.takeException(), isNull);
    binding.reportData!['productionNavigationPassed'] = true;
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('MuMu source categories, secondary filters and changing sources', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    addTearDown(() => _unmount(tester));
    await settings.set(AppSettingKeys.tvMode, true);
    await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
    final gateway = TvDiscoveryTestGateway()
      ..autoComplete = true
      ..includeLibrary = true;
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: testMgReadApp(settings, sourceGateway: gateway),
      ),
    );
    await _settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell)));
    final router = container.read(appRouterProvider);
    final controller = container.read(discoveryPageControllerProvider.notifier);
    _focus(tester, find.byKey(const Key('app-nav-home'))).requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(router.routeInformationProvider.value.uri.toString(), '/discover?tv=content');
    expect(find.text('首页全部推荐'), findsOneWidget);
    await _capture(binding, capture, 'mumu-tv-source-posters');
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(controller.tvPrimaryTarget, 'library');
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      _focusedKey(),
      isIn([
        for (final id in ['all', 'cn', 'jp', 'us']) ValueKey(('discovery-filter', 'type', id)),
      ]),
    );
    _focus(tester, find.byKey(const ValueKey(('discovery-filter', 'type', 'all')))).requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp');
    await _capture(binding, capture, 'mumu-tv-anime-library');
    _focus(tester, find.byKey(const Key('tv-open-filters'))).requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('tv-filter-dialog')), findsOneWidget);
    expect(find.byType(CompanionEntry), findsNothing);
    _focus(tester, find.byKey(const ValueKey(('discovery-filter', 'genre', 'all')))).requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp', reason: 'Secondary filters require OK.');
    await _press(tester, LogicalKeyboardKey.select);
    expect(container.read(discoveryPageControllerProvider).target, 'library:jp:comedy');
    await _capture(binding, capture, 'mumu-tv-filter-dialog');
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.byKey(const Key('tv-filter-dialog')), findsNothing);
    expect(find.byType(CompanionEntry), findsOneWidget);
    expect(_focusedKey(), const Key('tv-open-filters'));

    _focus(tester, find.byKey(const Key('app-nav-discover'))).requestFocus();
    await _settle(tester);
    expect(find.byKey(const Key('tv-discovery-sources')), findsOneWidget);
    _focus(tester, find.byKey(const ValueKey('tv-source-choice-other'))).requestFocus();
    await _settle(tester);
    await _press(tester, LogicalKeyboardKey.select);
    final outer = find.byKey(const Key('tv-outer-navigation'));
    expect(find.descendant(of: outer, matching: find.text('备用动漫')), findsOneWidget);
    expect(find.descendant(of: outer, matching: find.text('其他栏目')), findsOneWidget);
    expect(find.descendant(of: outer, matching: find.text('动漫库')), findsNothing);
    expect(_focusedKey(), const ValueKey('tv-source-choice-other'));
    await _capture(binding, capture, 'mumu-tv-source-picker');
    expect(tester.takeException(), isNull);
    binding.reportData!['fixtureSourceNavigationPassed'] = true;
  }, timeout: const Timeout(Duration(minutes: 2)));

  media.main();
  updates.main();
}

FocusNode _focus(WidgetTester tester, Finder target) =>
    tester.widget<Focus>(find.descendant(of: target, matching: find.byType(Focus)).first).focusNode!;

Key? _focusedKey() => FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.key;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(
    key,
    physicalKey: {
      LogicalKeyboardKey.select: PhysicalKeyboardKey.enter,
      LogicalKeyboardKey.arrowUp: PhysicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown: PhysicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft: PhysicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight: PhysicalKeyboardKey.arrowRight,
    }[key],
  );
  await _settle(tester);
}

Future<void> _capture(IntegrationTestWidgetsFlutterBinding binding, GlobalKey key, String name) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final frame = await boundary.toImage(pixelRatio: 1);
  try {
    final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
    binding.reportData ??= {};
    final screenshots = binding.reportData!.putIfAbsent('tvScreenshots', () => <String, String>{}) as Map<String, String>;
    screenshots[name] = base64Encode(bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
  } finally {
    frame.dispose();
  }
}
