/// 全局动效 token 与减少动态效果策略测试。
///
/// 职责：
/// - 验证 token 层级、反向时长和中心化的立即完成语义。
///
/// 注意：
/// - 不把 token 测试当作页面视觉或平台性能验收。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';

void main() {
  test(
    'uses a shorter reverse navigation token and bounded retarget duration',
    () {
      expect(
        AppMotion.destinationReverseTransition,
        lessThan(AppMotion.destinationTransition),
      );
      expect(
        AppMotion.interruptedDuration(
          fullDuration: AppMotion.bottomNavigationPillTravel,
          minimumDuration: AppMotion.bottomNavigationPillMinimumTravel,
          from: 0,
          to: 1 / 3,
          disableAnimations: false,
        ),
        AppMotion.bottomNavigationPillMinimumTravel,
      );
      expect(
        AppMotion.interruptedDuration(
          fullDuration: AppMotion.short,
          from: 0,
          to: 0.5,
          disableAnimations: true,
        ),
        Duration.zero,
      );
    },
  );

  testWidgets('resolves every shared duration to zero for reduced motion', (
    WidgetTester tester,
  ) async {
    Duration? resolved;
    bool? disabled;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (BuildContext context) {
            disabled = AppMotion.disablesAnimations(context);
            resolved = AppMotion.effectiveDuration(context, AppMotion.short);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(disabled, isTrue);
    expect(resolved, Duration.zero);
  });
}
