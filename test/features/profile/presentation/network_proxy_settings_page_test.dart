import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/profile/presentation/network_proxy_settings_page.dart';

import '../../../core/settings/settings_testkit.dart';

void main() {
  testWidgets('enables forced Runtime routing after a Windows media route is selected', (tester) async {
    if (!Platform.isWindows) return;
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    await settings.initialize();
    addTearDown(settings.close);
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsProvider.overrideWithValue(settings)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NetworkProxySettingsPage(onBackRequested: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = find.descendant(of: find.byKey(const Key('network-proxy-content')), matching: find.byType(Scrollable)).first;
    final videoRow = find.byKey(const Key('network-proxy-video'));
    await tester.scrollUntilVisible(videoRow, 220, scrollable: scrollable);
    final videoSwitch = find.descendant(of: videoRow, matching: find.byType(Switch));
    await Scrollable.ensureVisible(tester.element(videoSwitch), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(videoSwitch);
    await tester.pump();

    final forceSwitch = find.byKey(const Key('network-proxy-force-player-local'));
    await tester.scrollUntilVisible(forceSwitch, 220, scrollable: scrollable);
    await Scrollable.ensureVisible(tester.element(forceSwitch), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(forceSwitch).onChanged, isNotNull);
    await tester.tap(forceSwitch);
    await tester.pump();
    expect(tester.widget<Switch>(forceSwitch).value, isTrue);
  });
}
