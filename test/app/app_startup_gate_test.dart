/// 启动遮罩回归：遮罩内真实内容必须绘制，撤下时保留状态，等待期间屏蔽交互。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_startup.dart';
import 'package:mg_read/app/app_startup_gate.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

void main() {
  testWidgets('paints under the mask and reveals the same mounted route', (tester) async {
    final semantics = tester.ensureSemantics();
    final resources = Completer<AppStartupResources>();
    final startup = AppStartupController(
      openResources: () => resources.future,
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
    );
    addTearDown(() async {
      if (!resources.isCompleted) resources.complete(const AppStartupResources());
      await startup.close();
    });
    final boot = startup.start();
    var taps = 0;
    var paints = 0;
    final routeKey = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStartupControllerProvider.overrideWithValue(startup)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: AppStartupGate(
            child: Scaffold(
              key: routeKey,
              body: CustomPaint(
                painter: _PaintProbe(() => paints++),
                child: Center(
                  child: TextButton(onPressed: () => taps++, child: const Text('打开书籍')),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final routeElement = routeKey.currentContext;
    expect(TickerMode.valuesOf(routeElement!).enabled, isTrue);
    expect(paints, greaterThan(0));
    expect(find.byKey(const Key('app-startup-mask')), findsOneWidget);
    expect(find.bySemanticsLabel('打开书籍'), findsNothing);
    await tester.tap(find.text('打开书籍'), warnIfMissed: false);
    expect(taps, 0);

    resources.complete(const AppStartupResources());
    await boot;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-startup-mask')), findsNothing);
    expect(identical(routeElement, routeKey.currentContext), isTrue);
    expect(TickerMode.valuesOf(routeKey.currentContext!).enabled, isTrue);
    await tester.tap(find.text('打开书籍'));
    expect(taps, 1);
    semantics.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('masked routes keep ticking but cannot receive remote activation', (tester) async {
    final resources = Completer<AppStartupResources>();
    final startup = AppStartupController(
      openResources: () => resources.future,
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
    );
    addTearDown(() async {
      if (!resources.isCompleted) resources.complete(const AppStartupResources());
      await startup.close();
    });
    final boot = startup.start();
    var completed = false;
    var activated = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStartupControllerProvider.overrideWithValue(startup)],
        child: MaterialApp(
          home: AppStartupGate(
            child: _StartupAnimationProbe(onComplete: () => completed = true, onPressed: () => activated++),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(completed, isTrue);
    expect(find.byKey(const Key('app-startup-mask')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 0);
    resources.complete(const AppStartupResources());
    await boot;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-startup-mask')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 1);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('slow startup exposes its stage without opening a duplicate attempt', (tester) async {
    final resources = Completer<AppStartupResources>();
    var attempts = 0;
    final startup = AppStartupController(
      openResources: () {
        attempts++;
        return resources.future;
      },
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
    );
    addTearDown(() async {
      if (!resources.isCompleted) resources.complete(const AppStartupResources());
      await startup.close();
    });
    final boot = startup.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStartupControllerProvider.overrideWithValue(startup)],
        child: const MaterialApp(
          home: AppStartupGate(
            waitWarningDelay: Duration(seconds: 1),
            child: Scaffold(body: Text('书架')),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('启动耗时较长'), findsOneWidget);
    expect(find.text('正在打开本地书架…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('startup-continue-waiting')));
    await tester.pump();
    expect(attempts, 1);
    resources.complete(const AppStartupResources());
    await boot;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-startup-mask')), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('failed startup can retry behind the same mask', (tester) async {
    final retryResources = Completer<AppStartupResources>();
    var attempts = 0;
    final startup = AppStartupController(
      openResources: () async {
        if (++attempts == 1) throw StateError('startup fixture failure');
        return retryResources.future;
      },
      diagnostics: DiagnosticsManager(
        sink: const NoopDiagnosticEventSink(),
        registry: AppDiagnosticEvents.registry,
        source: DiagnosticSource.app,
      ),
    );
    addTearDown(startup.close);
    await startup.start();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appStartupControllerProvider.overrideWithValue(startup)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const AppStartupGate(child: Scaffold(body: Text('真实页面'))),
        ),
      ),
    );
    expect(find.text('启动失败'), findsOneWidget);
    await tester.tap(find.byKey(const Key('startup-retry')));
    await tester.pump();
    await tester.pump();
    expect(attempts, 2);
    expect(find.byKey(const Key('app-startup-mask')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    retryResources.complete(const AppStartupResources());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-startup-mask')), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 1)));
}

class _PaintProbe extends CustomPainter {
  _PaintProbe(this.onPaint);
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_PaintProbe oldDelegate) => false;
}

class _StartupAnimationProbe extends StatefulWidget {
  const _StartupAnimationProbe({required this.onComplete, required this.onPressed});
  final VoidCallback onComplete;
  final VoidCallback onPressed;
  @override
  State<_StartupAnimationProbe> createState() => _StartupAnimationProbeState();
}

class _StartupAnimationProbeState extends State<_StartupAnimationProbe> with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  @override
  void initState() {
    super.initState();
    controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 100));
    controller.forward().whenComplete(widget.onComplete);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(autofocus: true, onPressed: widget.onPressed, child: const Text('隐藏的遥控操作')),
    ),
  );
}
