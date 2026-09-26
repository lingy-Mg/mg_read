/// 检测会话的返回确认、销毁取消、实时结果与窄屏状态回归。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/presentation/source_verification_page.dart';

void main() {
  testWidgets('back confirmation can continue or abort the running request', (tester) async {
    final gateway = _PendingGateway();
    var exits = 0;
    await _mount(tester, gateway, onBack: () => exits++);
    expect(find.text('正在检测数据源'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-verification-back')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('中断检测并退出？'), findsOneWidget);
    await tester.tap(find.text('继续检测'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(exits, 0);
    expect(gateway.cancellation!.isCancelled, isFalse);
    await tester.tap(find.byKey(const Key('source-verification-back')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('中断并退出'));
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(gateway.cancellation!.isCancelled, isTrue);
    expect(find.text('检测已中断'), findsOneWidget);
    gateway.discoveryResult.completeError(StateError('late response'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirmed system back pops the real route after cancellation', (tester) async {
    final gateway = _PendingGateway();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: AppTheme.light(),
          home: const Scaffold(body: Text('previous page')),
        ),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => SourceVerificationPage(onBackRequested: () => navigatorKey.currentState!.pop())),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await navigatorKey.currentState!.maybePop();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('中断并退出'));
    await tester.pumpAndSettle();
    expect(gateway.cancellation!.isCancelled, isTrue);
    expect(find.byType(SourceVerificationPage), findsNothing);
    expect(find.text('previous page'), findsOneWidget);
  });

  testWidgets('system back is intercepted and dispose cancels pending requests', (tester) async {
    final gateway = _PendingGateway();
    await _mount(tester, gateway);
    final context = tester.element(find.byType(SourceVerificationPage));
    await Navigator.of(context).maybePop();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('中断检测并退出？'), findsOneWidget);
    await tester.tap(find.text('继续检测'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    expect(gateway.cancellation!.isCancelled, isTrue);
    gateway.discoveryResult.completeError(StateError('late response'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stop during initialization finishes and can restart without stale results', (tester) async {
    final gateway = _PendingGateway(holdList: true);
    await _mount(tester, gateway);
    expect(find.text('正在准备检测'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-verification-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('检测已中断'), findsOneWidget);
    expect(gateway.calls, 0);
    gateway.list.complete([]);
    await tester.pump();
    expect(find.text('检测已中断'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-verification-restart')));
    await tester.pumpAndSettle();
    expect(find.text('暂无可检测的数据源'), findsOneWidget);
    expect(find.text('检测已中断'), findsNothing);
  });

  testWidgets('live completed results and filters fit a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = _PendingGateway(firstFails: true);
    await _mount(tester, gateway, largeText: true);
    expect(find.text('已完成 1 / 2 个数据源'), findsOneWidget);
    expect(find.text('失败 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-verification-result-source-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('source-verification-cancel')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, '通过'), 150, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.widgetWithText(ChoiceChip, '通过'));
    await tester.pumpAndSettle();
    expect(find.text('暂无符合条件的结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mount(WidgetTester tester, _PendingGateway gateway, {VoidCallback? onBack, bool largeText = false}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
      child: MaterialApp(
        theme: AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(largeText ? 1.5 : 1)),
          child: child!,
        ),
        home: SourceVerificationPage(onBackRequested: onBack ?? () {}),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

final class _PendingGateway implements SourceContentGateway, CancellableSourceContentGateway {
  _PendingGateway({this.holdList = false, this.firstFails = false});
  final bool holdList;
  final bool firstFails;
  final list = Completer<List<PluginSourceDescriptor>>();
  final discoveryResult = Completer<PluginDiscoverResult>();
  PluginInvocationCancellation? cancellation;
  int calls = 0;

  @override
  Future<T> runCancellable<T>(PluginInvocationCancellation cancellation, Future<T> Function() request) {
    this.cancellation = cancellation;
    return request();
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => holdList
      ? list.future
      : [
          for (var i = 0; i < (firstFails ? 2 : 1); i++)
            PluginSourceDescriptor(id: 'source-$i', displayName: '用于验证长名称换行的数据源 $i', contentKinds: const [PluginContentKind.novel]),
        ];

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) {
    calls++;
    if (firstFails && calls == 1) throw StateError('fixture failure');
    return discoveryResult.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected request: ${invocation.memberName}');
}
