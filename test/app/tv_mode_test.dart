import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/features/profile/presentation/profile_general_setting_page.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/presentation/tv_profile_page.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import '../core/settings/settings_testkit.dart';
import 'mg_read_app_test_support.dart';

void main() {
  testWidgets('TV destinations open on focus and Search at the right requires OK', (tester) async {
    const renderingChannel = MethodChannel('mgread/rendering_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      renderingChannel,
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(renderingChannel, null));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await settings.set(AppSettingKeys.tvMode, true);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final router = ProviderScope.containerOf(tester.element(find.byType(TvLibraryShell))).read(appRouterProvider);
    final home = find.byKey(const Key('app-nav-home'));
    tester.widget<Focus>(find.descendant(of: home, matching: find.byType(Focus)).first).focusNode!.requestFocus();
    await tester.pumpAndSettle();
    for (final entry in {'discover': '/discover', 'profile': '/profile', 'search': '/profile'}.entries) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, entry.value);
      final action = find.byKey(Key('app-nav-${entry.key}'));
      final focus = tester.widget<Focus>(find.descendant(of: action, matching: find.byType(Focus)).first).focusNode;
      expect(FocusManager.instance.primaryFocus, focus);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/search');
    expect(find.byKey(const Key('source-search-query')), findsOneWidget);
    for (final entry in {'profile': '/profile', 'discover': '/discover', 'home': '/'}.entries) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, entry.value);
    }
    expect(
      FocusManager.instance.primaryFocus,
      tester.widget<Focus>(find.descendant(of: find.byKey(const Key('app-nav-home')), matching: find.byType(Focus)).first).focusNode,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV activation repeats never retrigger standard controls', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TvRemoteShortcuts(
          child: Scaffold(
            body: FilledButton(autofocus: true, onPressed: () => calls++, child: const Text('确认')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final key in [LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.space, LogicalKeyboardKey.gameButtonA]) {
      final before = calls;
      await tester.sendKeyDownEvent(key);
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(key);
        await tester.pump();
      }
      await tester.sendKeyUpEvent(key);
      await tester.pumpAndSettle();
      expect(calls - before, 1, reason: key.debugName);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('profile switches TV directly and exits without opening appearance', (tester) async {
    const renderingChannel = MethodChannel('mgread/rendering_settings');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      renderingChannel,
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(renderingChannel, null));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(LibraryHomeShell)));
    final router = container.read(appRouterProvider);
    router.go('/profile');
    await tester.pumpAndSettle();
    expect(find.byType(ProfilePage), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-tv-mode')));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.tvMode), isTrue);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    expect(find.byType(TvProfilePage), findsOneWidget);
    expect(find.byType(ProfileGeneralSettingPage), findsNothing);
    await tester.tap(find.byKey(const Key('tv-settings-exit-mode')));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.tvMode), isFalse);
    expect(router.routeInformationProvider.value.uri.path, '/profile');
    expect(find.byKey(const Key('profile-tv-mode')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('profile-tv-mode'))).value, isFalse);
    router.go('/profile/settings/theme-appearance');
    await tester.pumpAndSettle();
    expect(find.byType(ProfileGeneralSettingPage), findsOneWidget);
    expect(find.byKey(const Key('appearance-tv-mode')), findsNothing);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('TV preference survives store reload without replacing ordinary preferences', () async {
    final store = FakeSettingsStore();
    final first = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await first.initialize();
    expect(first.get(AppSettingKeys.tvMode), isFalse);
    await first.set(AppSettingKeys.themeMode, 'light');
    await first.set(AppSettingKeys.tvMode, true);
    await first.flush();
    final saved = Map<String, SettingsDocument>.of(store.documents);
    await first.close();
    final secondStore = FakeSettingsStore()..documents.addAll(saved);
    final second = AppSettingsManager(store: secondStore, registry: AppSettingKeys.registry);
    await second.initialize();
    expect(second.get(AppSettingKeys.tvMode), isTrue);
    expect(second.get(AppSettingKeys.themeMode), 'light');
    await second.close();
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('root switches in place and restores ordinary light theme', (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final settings = await createTestAppSettings(themeMode: 'light');
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryHomeShell), findsOneWidget);
    await settings.set(AppSettingKeys.tvMode, true);
    await tester.pumpAndSettle();
    expect(find.byType(TvLibraryShell), findsOneWidget);
    expect(Theme.of(tester.element(find.byType(TvLibraryShell))).brightness, Brightness.dark);
    await settings.set(AppSettingKeys.tvMode, false);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.tvMode), isFalse);
    expect(find.byType(LibraryHomeShell), findsOneWidget);
    expect(Theme.of(tester.element(find.byType(LibraryHomeShell))).brightness, Brightness.light);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
