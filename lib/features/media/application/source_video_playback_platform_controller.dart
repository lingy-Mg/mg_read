/// Route-scoped screen-awake and application-brightness ownership for video.
///
/// Playing video holds the screen awake; pause, failure, backgrounding and
/// route disposal release it. Gesture brightness is application-local and is
/// always reset when the video route closes.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@visibleForTesting
abstract interface class SourceVideoPlaybackPlatform {
  Future<void> setScreenAwake(bool active);

  Future<double> readApplicationBrightness();

  Future<void> setApplicationBrightness(double brightness);

  Future<void> resetApplicationBrightness();
}

final class SystemSourceVideoPlaybackPlatform implements SourceVideoPlaybackPlatform {
  const SystemSourceVideoPlaybackPlatform();

  @override
  Future<void> setScreenAwake(bool active) => WakelockPlus.toggle(enable: active);

  @override
  Future<double> readApplicationBrightness() => ScreenBrightness.instance.application;

  @override
  Future<void> setApplicationBrightness(double brightness) =>
      ScreenBrightness.instance.setApplicationScreenBrightness(brightness.clamp(0.05, 1).toDouble());

  @override
  Future<void> resetApplicationBrightness() => ScreenBrightness.instance.resetApplicationScreenBrightness();
}

final class SourceVideoPlaybackPlatformController {
  SourceVideoPlaybackPlatformController() : _platform = const SystemSourceVideoPlaybackPlatform();

  @visibleForTesting
  SourceVideoPlaybackPlatformController.withPlatform(this._platform);

  final SourceVideoPlaybackPlatform _platform;

  Future<void> _tail = Future<void>.value();
  bool _desiredAwake = false;
  bool _screenAwake = false;
  bool _wakeReleaseNeeded = false;
  double? _desiredBrightness;
  double? _appliedBrightness;
  bool _brightnessResetNeeded = false;
  bool _closed = false;

  Future<void> setPlaybackActive(bool active) {
    if (_closed) return Future<void>.value();
    _desiredAwake = active;
    return _append(() async {
      if (_closed) return;
      final target = _desiredAwake;
      if (target && _screenAwake) return;
      if (!target && !_screenAwake && !_wakeReleaseNeeded) return;
      if (target) _wakeReleaseNeeded = true;
      await _platform.setScreenAwake(target);
      _screenAwake = target;
      if (!target) _wakeReleaseNeeded = false;
    });
  }

  Future<double?> readBrightness() async {
    if (_closed) return null;
    try {
      return (await _platform.readApplicationBrightness())
          .clamp(0.05, 1)
          .toDouble();
    } on Object {
      return _appliedBrightness;
    }
  }

  Future<void> setBrightness(double brightness) {
    if (_closed) return Future<void>.value();
    _desiredBrightness = brightness.clamp(0.05, 1).toDouble();
    return _append(() async {
      if (_closed) return;
      final target = _desiredBrightness;
      if (target == null || target == _appliedBrightness) return;
      _brightnessResetNeeded = true;
      await _platform.setApplicationBrightness(target);
      _appliedBrightness = target;
    });
  }

  Future<void> restoreAndClose() {
    if (_closed) return _tail;
    _closed = true;
    _desiredAwake = false;
    return _append(() async {
      final operations = <Future<void>>[];
      if (_wakeReleaseNeeded || _screenAwake) {
        operations.add(_platform.setScreenAwake(false));
      }
      if (_brightnessResetNeeded) {
        operations.add(_platform.resetApplicationBrightness());
      }
      try {
        await Future.wait<void>(operations, eagerError: false);
      } finally {
        _screenAwake = false;
        _wakeReleaseNeeded = false;
        _appliedBrightness = null;
        _desiredBrightness = null;
        _brightnessResetNeeded = false;
      }
    });
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = _tail.then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next;
  }
}
