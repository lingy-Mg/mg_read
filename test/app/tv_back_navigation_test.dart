/// TV back regressions through the real app router and platform dispatcher.
/// SystemNavigator.pop is captured; tests never close the host application.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mg_read/features/app_update/presentation/github_apk_update_prompt.dart';
import '../support/github_apk_release_fixture.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_page_controller.dart';
import 'package:mg_read/features/discovery/application/discovery_page_state.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';

import '../support/tv_media_test_fixture.dart';
import 'mg_read_app_test_support.dart';

void main() {
  var exitCount = 0;
  final frameworkBack = <bool>[];
  setUp(() {
    exitCount = 0;
    frameworkBack.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mgread/rendering_settings'),
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exitCount++;
      if (call.method == 'SystemNavigator.setFrameworkHandlesBack') frameworkBack.add(call.arguments as bool);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('mgread/rendering_settings'),
      null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final destination in ['discover', 'search', 'settings']) {
    testWidgets('TV $destination back restores its own tab before double-back exit', (tester) async {
      final router = await _startTvApp(tester);
      await tester.tap(find.byKey(Key('app-nav-${destination == 'settings' ? 'profile' : destination}')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, destination == 'settings' ? '/profile' : '/$destination');
      expect(_navFocus(tester, destination == 'settings' ? 'profile' : destination).hasFocus, isTrue);
      expect(find.text('再按一次返回键退出应用'), findsNothing);
      expect(exitCount, 0);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('再按一次返回键退出应用'), findsOneWidget);
      expect(exitCount, 0);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(exitCount, 1);
    });
  }

  for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack]) {
    testWidgets('TV runtime discovery ${key.keyLabel} restores its own tab', (tester) async {
      final router = await _startTvApp(tester, runtimeDiscovery: true);
      await tester.tap(find.byKey(const Key('app-nav-discover')));
      await tester.pumpAndSettle();
      expect(find.text('测试发现内容'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(key, physicalKey: PhysicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/discover');
      expect(_navFocus(tester, 'discover').hasFocus, isTrue);
      expect(exitCount, 0);
    });
  }

  testWidgets('TV detail back retains discovery and exit still needs two root backs', (tester) async {
    final router = await _startTvApp(tester, runtimeDiscovery: true);
    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle();
    final context = tester.element(find.text('测试发现内容'));
    showSourceContentDetailSheet(
      context,
      gateway: ProviderScope.containerOf(context).read(sourceContentGatewayProvider),
      pluginId: tvDetailFixture.pluginId,
      id: tvDetailFixture.summary.id,
      initialDetail: tvDetailFixture,
      initialCatalog: tvCatalogFixture,
      refreshInitialContent: false,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-content-detail-sheet')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-content-detail-sheet')), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    expect(find.text('测试发现内容'), findsOneWidget);
    expect(frameworkBack.last, isTrue);
    expect(exitCount, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    expect(_navFocus(tester, 'discover').hasFocus, isTrue);
    expect(find.text('再按一次返回键退出应用'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('再按一次返回键退出应用'), findsOneWidget);
    expect(exitCount, 0);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(exitCount, 1);
  });

  for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack]) {
    for (final afterRelease in [false, true]) {
      testWidgets('TV detail consumes paired ${key.keyLabel} platform back afterRelease=$afterRelease', (tester) async {
        final router = await _startTvApp(tester, runtimeDiscovery: true);
        await _openTvDetail(tester);
        await tester.sendKeyDownEvent(key, physicalKey: PhysicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 20));
        if (!afterRelease) await tester.binding.handlePopRoute();
        await tester.sendKeyUpEvent(key, physicalKey: PhysicalKeyboardKey.escape);
        if (afterRelease) {
          // Move into content; left/right on the restored TV navigation now
          // intentionally switches the destination.
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 20));
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('source-content-detail-sheet')), findsNothing);
        expect(router.routeInformationProvider.value.uri.path, '/discover');
        expect(find.text('测试发现内容'), findsOneWidget);
        await tester.sendKeyEvent(key, physicalKey: PhysicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(router.routeInformationProvider.value.uri.path, '/discover');
        expect(_navFocus(tester, 'discover').hasFocus, isTrue);
        expect(exitCount, 0);
      });
    }
  }

  testWidgets('TV player back hides controls, exits to detail, and never also backs discovery', (tester) async {
    final router = await _startTvApp(tester, runtimeDiscovery: true);
    await _openTvDetail(tester);
    final controller = VideoPlayerController();
    final store = TvFixtureVideoStore();
    addTearDown(controller.dispose);
    appRootNavigatorKey.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => VideoPlayerView(
          tvMode: true,
          contentId: 'show',
          dataSource: TvFixtureVideoSource(),
          stateStore: store,
          controller: controller,
          backendFactory: TvFixtureVideoBackend.new,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(controller.snapshot.controlsVisible, isTrue);
    await _remoteBackWithPlatformEcho(tester);
    expect(find.byType(VideoPlayerView), findsOneWidget);
    expect(controller.snapshot.controlsVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tv-video-episodes')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('video-player-episode-sheet')), findsOneWidget);
    await _remoteBackWithPlatformEcho(tester);
    expect(find.byKey(const Key('video-player-episode-sheet')), findsNothing);
    expect(find.byType(VideoPlayerView), findsOneWidget);
    expect(controller.snapshot.controlsVisible, isTrue);
    await _remoteBackWithPlatformEcho(tester);
    expect(find.byType(VideoPlayerView), findsOneWidget);
    expect(controller.snapshot.controlsVisible, isFalse);
    await _remoteBackWithPlatformEcho(tester);
    expect(find.byType(VideoPlayerView), findsNothing);
    expect(find.byKey(const Key('source-content-detail-sheet')), findsOneWidget);
    expect(store.saved?.position, const Duration(seconds: 10));
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    await _remoteBackWithPlatformEcho(tester);
    expect(find.byKey(const Key('source-content-detail-sheet')), findsNothing);
    expect(find.text('测试发现内容'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    expect(exitCount, 0);
  });

  testWidgets('TV detail also consumes a platform signal followed by its keyboard echo', (tester) async {
    final router = await _startTvApp(tester, runtimeDiscovery: true);
    await _openTvDetail(tester);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('source-content-detail-sheet')), findsNothing);
    expect(find.text('测试发现内容'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    await tester.sendKeyEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/discover');
  });

  testWidgets('TV home exit confirmation expires after two seconds', (tester) async {
    await _startTvApp(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('再按一次返回键退出应用'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('再按一次返回键退出应用'), findsOneWidget);
    expect(exitCount, 0);
  });

  testWidgets('holding TV back does not cross multiple destinations or confirm exit', (tester) async {
    final router = await _startTvApp(tester, runtimeDiscovery: true);
    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/discover');
    expect(_navFocus(tester, 'discover').hasFocus, isTrue);
    expect(find.text('再按一次返回键退出应用'), findsNothing);
    expect(exitCount, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('再按一次返回键退出应用'), findsOneWidget);
    expect(exitCount, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(exitCount, 1);
  });

  testWidgets('leaving TV home clears the previous exit confirmation', (tester) async {
    await _startTvApp(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('再按一次返回键退出应用'), findsOneWidget);
    expect(exitCount, 0);
  });

  testWidgets('TV dialogs and home filters consume back before the exit prompt', (tester) async {
    await _startTvApp(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('tv-nav-reading')),
      220,
      scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
    );
    await tester.tap(find.byKey(const Key('tv-nav-reading')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('我的影视'), findsOneWidget);
    expect(find.text('再按一次返回键退出应用'), findsNothing);

    showDialog<void>(
      context: tester.element(find.byType(TvLibraryShell)),
      builder: (_) => const AlertDialog(title: Text('测试弹窗')),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('测试弹窗'), findsNothing);
    expect(find.text('再按一次返回键退出应用'), findsNothing);
    expect(exitCount, 0);
  });

  for (final kind in ['update', 'dialog', 'sheet']) {
    testWidgets('TV $kind consumes duplicate platform back without backing settings', (tester) async {
      final router = await _startTvApp(tester);
      router.go('/profile');
      await tester.pumpAndSettle();
      final context = appRootNavigatorKey.currentContext!;
      if (kind == 'update') {
        showGitHubApkUpdatePrompt(context, githubApkReleaseFixture);
      } else if (kind == 'dialog') {
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(key: Key('generic-tv-overlay'), title: Text('测试弹窗')),
        );
      } else {
        showModalBottomSheet<void>(
          context: context,
          builder: (_) => const SizedBox(key: Key('generic-tv-overlay'), height: 200, child: Text('测试选项')),
        );
      }
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('github-apk-update-prompt')), findsNothing);
      expect(find.byKey(const Key('generic-tv-overlay')), findsNothing);
      expect(router.routeInformationProvider.value.uri.path, '/profile');
      expect(exitCount, 0);
    });
  }

  testWidgets('TV secondary settings back returns to settings before the exit prompt', (tester) async {
    final router = await _startTvApp(tester);
    router.go('/profile/about');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    expect(exitCount, 0);
  });

  testWidgets('TV root retains Android back ownership and restores it when TV mode changes', (tester) async {
    await _startTvApp(tester);
    expect(frameworkBack.last, isTrue);
    final settings = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell))).read(appSettingsProvider);
    await settings.set(AppSettingKeys.tvMode, false);
    await tester.pumpAndSettle();
    expect(frameworkBack.last, isFalse);
    await settings.set(AppSettingKeys.tvMode, true);
    await tester.pumpAndSettle();
    expect(frameworkBack.last, isTrue);
    expect(exitCount, 0);
  });
}

Future<GoRouter> _startTvApp(WidgetTester tester, {bool runtimeDiscovery = false}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final settings = await createTestAppSettings();
  addTearDown(settings.close);
  await settings.set(AppSettingKeys.tvMode, true);
  await settings.set(AppSettingKeys.sourceAutoUpdateCheckEnabled, false);
  final scope = testMgReadApp(settings) as ProviderScope;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...scope.overrides, if (runtimeDiscovery) discoveryPageControllerProvider.overrideWith(_LoadedDiscoveryController.new)],
      child: scope.child,
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell))).read(appRouterProvider);
}

Future<void> _openTvDetail(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('app-nav-discover')));
  await tester.pumpAndSettle();
  final context = tester.element(find.text('测试发现内容'));
  showSourceContentDetailSheet(
    context,
    gateway: ProviderScope.containerOf(context).read(sourceContentGatewayProvider),
    pluginId: tvDetailFixture.pluginId,
    id: tvDetailFixture.summary.id,
    initialDetail: tvDetailFixture,
    initialCatalog: tvCatalogFixture,
    refreshInitialContent: false,
  );
  await tester.pumpAndSettle();
}

Future<void> _remoteBackWithPlatformEcho(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 20));
  await tester.binding.handlePopRoute();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.goBack, physicalKey: PhysicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

class _LoadedDiscoveryController extends DiscoveryPageController {
  @override
  DiscoveryPageState build() => DiscoveryPageState.resolved(
    sources: [
      PluginSourceDescriptor(id: 'tv-test', displayName: '测试源', contentKinds: const [PluginContentKind.video]),
    ],
    selectedSourceId: 'tv-test',
    result: PluginDiscoveryDocumentResult(
      pluginId: 'tv-test',
      sourceName: '测试源',
      document: PluginDiscoveryDocument(
        components: const [PluginDiscoveryTextComponent(id: 'text', text: '测试发现内容')],
      ),
    ),
    isEmpty: false,
    canNavigateBack: false,
    navigationDepth: 0,
    target: null,
  );
}

FocusNode _navFocus(WidgetTester tester, String id) =>
    tester.widget<Focus>(find.descendant(of: find.byKey(Key('app-nav-$id')), matching: find.byType(Focus)).first).focusNode!;
