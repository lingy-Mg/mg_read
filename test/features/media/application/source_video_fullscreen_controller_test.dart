/// Verifies host-owned video fullscreen transitions and cleanup ordering.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_video_fullscreen_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('system platform enables both orientations and immersive UI', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const platform = SystemSourceVideoFullscreenPlatform();

    await platform.enter();
    await platform.exit();

    expect(calls.map((call) => call.method), <String>[
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
    ]);
    expect(calls[0].arguments, <String>[
      'DeviceOrientation.portraitUp',
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.portraitDown',
      'DeviceOrientation.landscapeRight',
    ]);
    expect(calls[1].arguments, 'SystemUiMode.immersiveSticky');
    expect(calls[2].arguments, isEmpty);
    expect(calls[3].arguments, 'SystemUiMode.edgeToEdge');
  });

  test('enters and exits fullscreen in request order', () async {
    final platform = _FakeFullscreenPlatform();
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await controller.setFullscreen(true);
    await controller.setFullscreen(false);

    expect(platform.calls, <String>['enter', 'exit']);
  });

  test('restore closes fullscreen and ignores later requests', () async {
    final platform = _FakeFullscreenPlatform();
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await controller.setFullscreen(true);
    await controller.restoreAndClose();
    await controller.setFullscreen(true);

    expect(platform.calls, <String>['enter', 'exit']);
  });

  test('restore waits for an active enter before exiting', () async {
    final enterGate = Completer<void>();
    final platform = _FakeFullscreenPlatform(enterGate: enterGate);
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    final entering = controller.setFullscreen(true);
    await Future<void>.delayed(Duration.zero);
    final restoring = controller.restoreAndClose();
    expect(platform.calls, <String>['enter']);

    enterGate.complete();
    await Future.wait(<Future<void>>[entering, restoring]);

    expect(platform.calls, <String>['enter', 'exit']);
  });

  test('restore repairs a partially failed enter', () async {
    final platform = _FakeFullscreenPlatform(failEnter: true);
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await expectLater(controller.setFullscreen(true), throwsStateError);
    await controller.restoreAndClose();

    expect(platform.calls, <String>['enter', 'exit']);
  });
}

final class _FakeFullscreenPlatform implements SourceVideoFullscreenPlatform {
  _FakeFullscreenPlatform({this.enterGate, this.failEnter = false});

  final Completer<void>? enterGate;
  final bool failEnter;
  final List<String> calls = <String>[];

  @override
  Future<void> enter() async {
    calls.add('enter');
    await enterGate?.future;
    if (failEnter) throw StateError('enter failed');
  }

  @override
  Future<void> exit() async {
    calls.add('exit');
  }
}
