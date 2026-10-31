import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/features/profile/presentation/profile_general_setting_page.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/widgets/library_home_shell.dart';
import 'package:mg_read/features/library/presentation/widgets/tv_library_shell.dart';
import '../core/settings/settings_testkit.dart';
import 'mg_read_app_test_support.dart';

void main() {
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
  });

  testWidgets('switching TV from appearance retains the current settings route', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(LibraryHomeShell)));
    final router = container.read(appRouterProvider);
    router.go('/profile/settings/theme-appearance');
    await tester.pumpAndSettle();
    expect(find.byType(ProfileGeneralSettingPage), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(find.byKey(const Key('appearance-tv-mode')));
    toggle.onChanged!(true);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.tvMode), isTrue);
    expect(router.routeInformationProvider.value.uri.path, '/profile/settings/theme-appearance');
    expect(find.byType(ProfileGeneralSettingPage), findsOneWidget);
    tester.widget<SwitchListTile>(find.byKey(const Key('appearance-tv-mode'))).onChanged!(false);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.tvMode), isFalse);
    expect(find.byType(ProfileGeneralSettingPage), findsOneWidget);
  });

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
  });

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
    await tester.tap(find.byKey(const Key('tv-nav-mode')));
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.tvMode), isFalse);
    expect(find.byType(LibraryHomeShell), findsOneWidget);
    expect(Theme.of(tester.element(find.byType(LibraryHomeShell))).brightness, Brightness.light);
  });
}
