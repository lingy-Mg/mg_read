/// 全局无动画策略的行为验证：设置重载、真实组合根、路由和局部内容中断。
/// 使用测试 Runtime；不代表真实设备帧率或平台播放验收。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/library/presentation/library_page.dart';
import 'package:mg_read/shared/presentation/motion/app_content_transition.dart';
import 'package:mg_read/shared/presentation/motion/app_motion_scope.dart';

import '../core/settings/settings_testkit.dart';
import 'mg_read_app_test_support.dart';

void main() {
  testWidgets('changing motion policy retains the current content state', (tester) async {
    Widget host(bool disabled) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disabled),
        child: const Scaffold(
          body: AppContentTransition(child: TextField(key: Key('retained-input'))),
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    await tester.enterText(find.byKey(const Key('retained-input')), '保留输入');
    await tester.pumpWidget(host(true));
    expect(find.text('保留输入'), findsOneWidget);
    await tester.pumpWidget(host(false));
    expect(find.text('保留输入'), findsOneWidget);
  });
  test('no-animation preference defaults off and survives settings reload', () async {
    final store = FakeSettingsStore();
    final first = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    await first.initialize();
    expect(first.get(AppSettingKeys.noAnimations), isFalse);
    await first.set(AppSettingKeys.noAnimations, true);
    expect((await first.flush()).persisted, isTrue);
    await first.close();
    final reopened = AppSettingsManager(store: store, registry: AppSettingKeys.registry);
    addTearDown(reopened.close);
    await reopened.initialize();
    expect(reopened.get(AppSettingKeys.noAnimations), isTrue);
  });

  testWidgets('combines system and application policy without overriding system preference', (tester) async {
    for (final system in [false, true]) {
      for (final application in [false, true]) {
        late BuildContext content;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(disableAnimations: system),
            child: AppMotionScope(
              disabled: application,
              child: Builder(
                builder: (context) {
                  content = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        expect(AppMotion.disablesAnimations(content), system || application);
        expect(AppMotion.overlayStyle(content).duration, system || application ? Duration.zero : AppMotion.pageTransition);
      }
    }
  });

  testWidgets('real application applies policy live to theme, routes and overlays', (tester) async {
    final settings = await createTestAppSettings();
    addTearDown(settings.close);
    await tester.pumpWidget(testMgReadApp(settings));
    await tester.pumpAndSettle();
    final page = tester.element(find.byType(LibraryPage));
    final normalTheme = Theme.of(page);
    final builder = normalTheme.pageTransitionsTheme.builders[TargetPlatform.windows]!;
    expect(builder.transitionDuration, AppMotion.pageTransition);
    await settings.set(AppSettingKeys.noAnimations, true);
    await tester.pump();
    expect(MediaQuery.disableAnimationsOf(page), isTrue);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeAnimationDuration, Duration.zero);
    expect(Theme.of(page).pageTransitionsTheme.builders[TargetPlatform.windows]!.transitionDuration, Duration.zero);
    expect(Theme.of(page).expansionTileTheme.expansionAnimationStyle!.duration, Duration.zero);

    showDialog<void>(
      context: page,
      animationStyle: AppMotion.overlayStyle(page),
      builder: (_) => const AlertDialog(title: Text('策略弹窗')),
    );
    await tester.pump();
    final dialogContext = tester.element(find.text('策略弹窗'));
    expect(MediaQuery.disableAnimationsOf(dialogContext), isTrue);
    expect(ModalRoute.of(dialogContext)!.animation!.value, 1);
    Navigator.of(dialogContext).pop();
    await tester.pumpAndSettle();
    await settings.set(AppSettingKeys.noAnimations, false);
    await tester.pumpAndSettle();
    expect(MediaQuery.disableAnimationsOf(page), isFalse);
    expect(Theme.of(page).pageTransitionsTheme.builders[TargetPlatform.windows]!.transitionDuration, AppMotion.pageTransition);
  });

  testWidgets('content changes animate, isolate outgoing semantics and finish immediately when disabled', (tester) async {
    final semantics = tester.ensureSemantics();
    Widget host(String value, {bool disabled = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disabled),
        child: Scaffold(
          body: AppContentTransition(
            child: SizedBox(
              key: ValueKey(value),
              height: 100,
              width: 200,
              child: TextButton(onPressed: () {}, child: Text(value)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(host('旧内容'));
    await tester.pumpWidget(host('新内容'));
    await tester.pump(const Duration(milliseconds: 50));
    final fade = tester.widget<FadeTransition>(find.ancestor(of: find.text('新内容'), matching: find.byType(FadeTransition)).first);
    expect(fade.opacity.value, inExclusiveRange(0, 1));
    expect(find.bySemanticsLabel('旧内容'), findsNothing);
    expect(find.bySemanticsLabel('新内容'), findsOneWidget);
    await tester.pumpWidget(host('新内容', disabled: true));
    expect(find.text('旧内容'), findsNothing);
    expect(find.text('新内容'), findsOneWidget);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
