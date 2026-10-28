/// 验证真实书架阅读启动错误提示的超时、关闭、重试、替换及窄屏布局。
/// 不创建 Runtime 或真实阅读任务；计时由 widget 测试时钟驱动。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/widgets/library_reader_launch_error.dart';

import '../../../support/visual_evidence.dart';

void main() {
  testWidgets('retry error automatically disappears even with accessible navigation', (tester) async {
    final context = await _mount(tester, accessibleNavigation: true);
    var retries = 0;
    showLibraryReaderLaunchError(context, message: '阅读内容准备失败', onRetry: () => retries++);
    await tester.pumpAndSettle();
    expect(find.text('阅读内容准备失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(retries, 0);
  });

  testWidgets('close dismisses the error without retrying', (tester) async {
    final context = await _mount(tester);
    var retries = 0;
    showLibraryReaderLaunchError(context, message: '阅读内容准备失败', onRetry: () => retries++);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(retries, 0);
  });

  testWidgets('retry dismisses the error and invokes the original action once', (tester) async {
    final context = await _mount(tester);
    var retries = 0;
    showLibraryReaderLaunchError(context, message: '阅读内容准备失败', onRetry: () => retries++);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('repeated failures replace the queue and keep only the latest retry', (tester) async {
    final context = await _mount(tester);
    int? retried;
    for (var i = 0; i < 20; i++) {
      showLibraryReaderLaunchError(context, message: '加载失败 $i', onRetry: () => retried = i);
    }
    await tester.pumpAndSettle();
    expect(find.text('加载失败 19'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(retried, 19);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('long error keeps close and retry reachable on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadVisualEvidenceFonts();
    final context = await _mount(tester, textScale: 1.5);
    showLibraryReaderLaunchError(context, message: '阅读内容准备失败，请检查网络后重试。' * 50, onRetry: () {});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await captureVisualEvidence(tester, 'reader-launch-error-dismissible');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}

Future<BuildContext> _mount(WidgetTester tester, {bool accessibleNavigation = false, double textScale = 1}) async {
  late BuildContext scaffoldContext;
  await tester.pumpWidget(
    visualEvidenceHost(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(accessibleNavigation: accessibleNavigation, textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              scaffoldContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    ),
  );
  return scaffoldContext;
}
