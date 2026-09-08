/// Verifies route-scoped video wakelock and brightness cleanup.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/features/media/application/source_video_playback_platform_controller.dart';

void main() {
  test('playing holds the screen awake and pause releases it', () async {
    final platform = _FakePlaybackPlatform();
    final controller = SourceVideoPlaybackPlatformController.withPlatform(platform);

    await controller.setPlaybackActive(true);
    await controller.setPlaybackActive(true);
    await controller.setPlaybackActive(false);

    expect(platform.awake, <bool>[true, false]);
  });

  test('close releases wakelock and resets brightness', () async {
    final platform = _FakePlaybackPlatform();
    final controller = SourceVideoPlaybackPlatformController.withPlatform(platform);

    await controller.setPlaybackActive(true);
    await controller.setBrightness(.35);
    await controller.restoreAndClose();

    expect(platform.awake, <bool>[true, false]);
    expect(platform.brightness, <double>[.35]);
    expect(platform.resetCount, 1);
  });

  test('close ignores later playback and brightness requests', () async {
    final platform = _FakePlaybackPlatform();
    final controller = SourceVideoPlaybackPlatformController.withPlatform(platform);

    await controller.restoreAndClose();
    await controller.setPlaybackActive(true);
    await controller.setBrightness(.2);

    expect(platform.awake, isEmpty);
    expect(platform.brightness, isEmpty);
  });

  test('pause repairs a partially failed screen-awake acquire', () async {
    final platform = _FakePlaybackPlatform(failEnable: true);
    final controller = SourceVideoPlaybackPlatformController.withPlatform(platform);

    await expectLater(controller.setPlaybackActive(true), throwsStateError);
    await controller.setPlaybackActive(false);

    expect(platform.awake, <bool>[true, false]);
  });
}

final class _FakePlaybackPlatform implements SourceVideoPlaybackPlatform {
  _FakePlaybackPlatform({this.failEnable = false});

  final bool failEnable;
  final List<bool> awake = <bool>[];
  final List<double> brightness = <double>[];
  int resetCount = 0;

  @override
  Future<double> readApplicationBrightness() async => .6;

  @override
  Future<void> resetApplicationBrightness() async => resetCount++;

  @override
  Future<void> setApplicationBrightness(double value) async => brightness.add(value);

  @override
  Future<void> setScreenAwake(bool active) async {
    awake.add(active);
    if (active && failEnable) throw StateError('enable failed');
  }
}
