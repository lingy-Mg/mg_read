/// Exercises persisted choices, paired-mode correction and native renderer
/// save/restart feedback. No real application restart or decoder runs here.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_restart.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/profile_video_settings.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  const channel = MethodChannel('mgread/rendering_settings');
  late AppSettingsManager settings;
  late String nativeMode;
  late bool failSave;
  late int restartCount;
  setUp(() async {
    nativeMode = 'auto';
    failSave = false;
    restartCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'select') {
        if (failSave) throw PlatformException(code: 'save_failed');
        nativeMode = (call.arguments as Map)['mode'] as String;
      }
      return {'selected': nativeMode, 'activeRenderer': 'opengl', 'restartRequired': nativeMode == 'vulkan'};
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await settings.close();
  });

  Future<Widget> host({double textScale = 1}) async {
    settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    return ProviderScope(
      overrides: [appSettingsProvider.overrideWithValue(settings), appRestartProvider.overrideWithValue(() async => restartCount++)],
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const Scaffold(body: SingleChildScrollView(child: ProfileVideoSettings())),
      ),
    );
  }

  Future<void> choose(WidgetTester tester, String key) async {
    final target = find.byKey(Key(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
    for (var tick = 0; tick < 20; tick++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (tester.widget<ChoiceChip>(find.byKey(const Key('video-decoder-auto'))).onSelected != null) break;
    }
  }

  testWidgets('global ad filtering defaults on and can be disabled without reopening a decoder', (tester) async {
    await tester.pumpWidget(await host());
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('video-ad-filter-on'))).selected, isTrue);
    await choose(tester, 'video-ad-filter-off');
    expect(settings.get(AppSettingKeys.videoAdFilterEnabled), isFalse);
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('video-ad-filter-off'))).selected, isTrue);
    expect(find.text('已保存，重新打开视频后生效。'), findsOneWidget);
    expect(restartCount, 0);
    await choose(tester, 'video-ad-filter-on');
    expect(settings.get(AppSettingKeys.videoAdFilterEnabled), isTrue);
  });

  testWidgets('video choices remain valid and show paired corrections', (tester) async {
    await tester.pumpWidget(await host());
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('video-decoder-auto'))).selected, isTrue);
    await choose(tester, 'video-output-surface');
    expect(settings.get(AppSettingKeys.videoAndroidOutputMode), 'surface');
    await choose(tester, 'video-decoder-software');
    expect(settings.get(AppSettingKeys.videoDecoderMode), 'software');
    expect(settings.get(AppSettingKeys.videoAndroidOutputMode), 'gpu');
    expect(find.textContaining('软件解码已同时切换为 GPU 输出'), findsOneWidget);
    await choose(tester, 'video-output-surface');
    expect(settings.get(AppSettingKeys.videoDecoderMode), 'hardware');
    expect(find.textContaining('已同时切换为硬件优先'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('renderer save distinguishes active mode and offers explicit restart', (tester) async {
    await tester.pumpWidget(await host());
    await tester.pumpAndSettle();
    await choose(tester, 'android-renderer-vulkan');
    expect(nativeMode, 'vulkan');
    expect(find.textContaining('当前：OpenGL'), findsOneWidget);
    expect(find.byKey(const Key('android-renderer-restart')), findsOneWidget);
    await choose(tester, 'android-renderer-restart');
    expect(restartCount, 1);
    await choose(tester, 'android-renderer-auto');
    expect(find.byKey(const Key('android-renderer-restart')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('native save failure keeps the last selected mode and shows retry feedback', (tester) async {
    await tester.pumpWidget(await host());
    await tester.pumpAndSettle();
    failSave = true;
    await choose(tester, 'android-renderer-vulkan');
    expect(nativeMode, 'auto');
    expect(tester.widget<ChoiceChip>(find.byKey(const Key('android-renderer-auto'))).selected, isTrue);
    expect(find.byKey(const Key('android-renderer-restart')), findsNothing);
    expect(find.byKey(const Key('video-settings-error')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('choices fit a narrow screen with enlarged text', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(await host(textScale: 1.6));
    await tester.pumpAndSettle();
    await choose(tester, 'android-renderer-opengl');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
