/// Route-scoped screen-awake and application-brightness ownership for video.
///
/// Playing video holds the screen awake; pause, failure, backgrounding and
/// route disposal release it. Gesture brightness is application-local and is
/// always reset when the video route closes.
/// Samples the native device's direct-video-surface preference independently of
/// TV presentation mode; unsupported hosts keep the default backend output.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Reads a narrowly selected Android hardware compatibility policy.
Future<bool> readSourceVideoDirectSurfacePreference() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await const MethodChannel(
          'mgread/device_profile',
        ).invokeMethod<bool>('prefersDirectVideoSurface').timeout(const Duration(seconds: 2)) ??
        false;
  } on Object {
    return false;
  }
}

@visibleForTesting
abstract interface class SourceVideoPlaybackPlatform {
  Future<void> setScreenAwake(bool active);

  Future<double> readApplicationBrightness();

  Future<void> setApplicationBrightness(double brightness);

  Future<void> resetApplicationBrightness();

  Future<double> readSystemVolume();

  Future<void> setSystemVolume(double volume);
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

  @override
  Future<double> readSystemVolume() async {
    final value = await _systemVolumeChannel.invokeMethod<num>('getSystemVolume');
    return (value ?? 0).toDouble().clamp(0, 100);
  }

  @override
  Future<void> setSystemVolume(double volume) =>
      _systemVolumeChannel.invokeMethod<void>('setSystemVolume', <String, Object>{'volume': volume.clamp(0, 100).toDouble()});

  static const MethodChannel _systemVolumeChannel = MethodChannel('mgread/media_system_volume');
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
  double? _desiredSystemVolume;
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
      return (await _platform.readApplicationBrightness()).clamp(0.05, 1).toDouble();
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

  Future<double?> readSystemVolume() async {
    if (_closed) return null;
    try {
      return (await _platform.readSystemVolume()).clamp(0, 100).toDouble();
    } on Object {
      return null;
    }
  }

  Future<void> setSystemVolume(double volume) {
    if (_closed) return Future<void>.value();
    _desiredSystemVolume = volume.clamp(0, 100).toDouble();
    return _append(() async {
      if (_closed) return;
      final target = _desiredSystemVolume;
      if (target == null) return;
      await _platform.setSystemVolume(target);
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
        _desiredSystemVolume = null;
      }
    });
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = _tail.then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next;
  }
}
