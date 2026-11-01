/// Verifies route-scoped video wakelock and brightness cleanup.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/features/media/application/source_video_playback_platform_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('native video output compatibility', () {
    const channel = MethodChannel('mgread/device_profile');
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('uses the native hardware decision for Android video output', () async {
      for (final preferred in [true, false]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'prefersDirectVideoSurface');
          return preferred;
        });
        expect(await readSourceVideoDirectSurfacePreference(), preferred);
      }
    });

    test('unavailable native capability retains default output', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        throw MissingPluginException();
      });
      expect(await readSourceVideoDirectSurfacePreference(), isFalse);
    });

    test('other platforms never query Android hardware policy', () async {
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return true;
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(await readSourceVideoDirectSurfacePreference(), isFalse);
      expect(calls, 0);
    });
  });

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

  test('routes video gesture volume through the system-volume platform', () async {
    final platform = _FakePlaybackPlatform();
    final controller = SourceVideoPlaybackPlatformController.withPlatform(platform);

    expect(await controller.readSystemVolume(), 50);
    await controller.setSystemVolume(72);

    expect(platform.systemVolumes, <double>[72]);
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
  Future<double> readSystemVolume() async => 50;

  @override
  Future<void> setSystemVolume(double value) async => systemVolumes.add(value);

  @override
  Future<void> setScreenAwake(bool active) async {
    awake.add(active);
    if (active && failEnable) throw StateError('enable failed');
  }

  final List<double> systemVolumes = <double>[];
}
