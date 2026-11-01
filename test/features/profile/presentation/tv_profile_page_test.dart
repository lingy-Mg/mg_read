/// TV settings remote flows, durable video choices and large-text dashboard.
/// Native renderer preferences are stubbed; no restart or network is invoked.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_page.dart';
import 'package:mg_read/features/profile/presentation/tv_profile_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import '../../../core/settings/settings_testkit.dart';

void main() {
  late AppSettingsManager settings;
  const channel = MethodChannel('mgread/rendering_settings');

  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() async {
    settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => {'selected': 'auto', 'activeRenderer': 'opengl', 'restartRequired': false},
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await settings.close();
  });

  Widget host({ValueChanged<String>? onSetting, double scale = 1}) => ProviderScope(
    overrides: [appSettingsProvider.overrideWithValue(settings)],
    child: MaterialApp(
      theme: appTvTheme(AppTheme.dark()),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: TvModeScope(
          enabled: true,
          onChanged: (_) {},
          child: TvRemoteShortcuts(child: child!),
        ),
      ),
      home: ProfilePage(appVersion: 'test', onPendingSettingRequested: onSetting),
    ),
  );

  testWidgets('TV video choices save by remote and keep focus through the save', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byType(TvProfilePage), findsOneWidget);
    _focus(tester, 'video-decoder-hardware').requestFocus();
    await tester.pumpAndSettle();
    final before = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(settings.get(AppSettingKeys.videoDecoderMode), 'hardware');
    expect(FocusManager.instance.primaryFocus, before);
    expect(tester.widget<TvFocusable>(find.byKey(const Key('video-decoder-hardware'))).selected, isTrue);
    await expectLater(find.byType(TvProfilePage), matchesGoldenFile('goldens/tv_settings_dashboard.png'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('category rail keeps focus and outgoing panels cannot capture right', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? opened;
    await tester.pumpWidget(host(onSetting: (id) => opened = id));
    await tester.pumpAndSettle();
    _focus(tester, 'tv-settings-section-0').requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 30));
    expect(FocusManager.instance.primaryFocus, _focus(tester, 'tv-settings-section-1'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 30));
    expect(FocusManager.instance.primaryFocus, _focus(tester, 'tv-settings-section-2'));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, _focus(tester, 'tv-setting-source-management'));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened, 'source-management');
    expect(tester.takeException(), isNull);
  });

  testWidgets('every TV settings category fits a short display with large text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(640, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(scale: 1.6));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      _focus(tester, 'tv-settings-section-$i').requestFocus();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });
}

FocusNode _focus(WidgetTester tester, String key) =>
    tester.widget<Focus>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Focus)).first).focusNode!;
