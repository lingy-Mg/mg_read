/// Verifies host-owned video fullscreen transitions and cleanup ordering.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_video_fullscreen_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('system platform uses portrait, landscape, then restores app UI', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const platform = SystemSourceVideoFullscreenPlatform();

    await platform.enterPortrait();
    await platform.enterLandscape();
    await platform.restore();

    expect(calls.map((call) => call.method), <String>[
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
      'SystemChrome.setPreferredOrientations',
      'SystemChrome.setEnabledSystemUIMode',
    ]);
    expect(calls[0].arguments, <String>['DeviceOrientation.portraitUp']);
    expect(calls[1].arguments, 'SystemUiMode.immersiveSticky');
    expect(calls[2].arguments, <String>['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);
    expect(calls[3].arguments, 'SystemUiMode.immersiveSticky');
    expect(calls[4].arguments, isEmpty);
    expect(calls[5].arguments, 'SystemUiMode.edgeToEdge');
  });

  test('activates portrait and enters and exits fullscreen in request order', () async {
    final platform = _FakeFullscreenPlatform();
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await controller.activate();
    await controller.setFullscreen(true);
    await controller.setFullscreen(false);
    await controller.restoreAndClose();

    expect(platform.calls, <String>['portrait', 'landscape', 'portrait', 'restore']);
  });

  test('restore closes fullscreen and ignores later requests', () async {
    final platform = _FakeFullscreenPlatform();
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await controller.activate();
    await controller.setFullscreen(true);
    await controller.restoreAndClose();
    await controller.setFullscreen(true);

    expect(platform.calls, <String>['portrait', 'landscape', 'restore']);
  });

  test('restore waits for an active enter before exiting', () async {
    final landscapeGate = Completer<void>();
    final platform = _FakeFullscreenPlatform(landscapeGate: landscapeGate);
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    final entering = controller.setFullscreen(true);
    await Future<void>.delayed(Duration.zero);
    final restoring = controller.restoreAndClose();
    expect(platform.calls, <String>['landscape']);

    landscapeGate.complete();
    await Future.wait(<Future<void>>[entering, restoring]);

    expect(platform.calls, <String>['landscape', 'restore']);
  });

  test('restore repairs a partially failed enter', () async {
    final platform = _FakeFullscreenPlatform(failLandscape: true);
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await expectLater(controller.setFullscreen(true), throwsStateError);
    await controller.restoreAndClose();

    expect(platform.calls, <String>['landscape', 'restore']);
  });

  test('desktop fullscreen changes only the current window and never requests mobile orientation', () async {
    final platform = _FakeFullscreenPlatform(usesDesktopWindowFullscreen: true);
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await controller.activate();
    await controller.setFullscreen(true);
    await controller.setFullscreen(false);
    await controller.restoreAndClose();

    expect(platform.calls, <String>['desktop:true', 'desktop:false']);
  });

  test('desktop route cleanup exits the current window fullscreen after a pending enter', () async {
    final platform = _FakeFullscreenPlatform(usesDesktopWindowFullscreen: true);
    final controller = SourceVideoFullscreenController.withPlatform(platform);

    await controller.setFullscreen(true);
    await controller.restoreAndClose();

    expect(platform.calls, <String>['desktop:true', 'desktop:false']);
  });
}

final class _FakeFullscreenPlatform implements SourceVideoFullscreenPlatform {
  _FakeFullscreenPlatform({this.landscapeGate, this.failLandscape = false, this.usesDesktopWindowFullscreen = false});

  final Completer<void>? landscapeGate;
  final bool failLandscape;
  @override
  final bool usesDesktopWindowFullscreen;
  final List<String> calls = <String>[];

  @override
  Future<void> enterLandscape() async {
    calls.add('landscape');
    await landscapeGate?.future;
    if (failLandscape) throw StateError('landscape failed');
  }

  @override
  Future<void> enterPortrait() async {
    calls.add('portrait');
  }

  @override
  Future<void> restore() async {
    calls.add('restore');
  }

  @override
  Future<void> setDesktopWindowFullscreen(bool fullscreen) async {
    calls.add('desktop:$fullscreen');
  }
}
