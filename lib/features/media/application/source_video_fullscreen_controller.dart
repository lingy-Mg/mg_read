/// Host-owned fullscreen lifetime for transient source-video routes.
///
/// The controller serializes platform changes, keeps the normal player in
/// portrait immersive mode, forces landscape while fullscreen, and restores
/// the app's default orientation and edge-to-edge UI before the route is left.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform operations used by [SourceVideoFullscreenController].
///
/// This seam is public only so the host behavior can be tested without sending
/// real platform-channel messages.
@visibleForTesting
abstract interface class SourceVideoFullscreenPlatform {
  Future<void> enterPortrait();

  Future<void> enterLandscape();

  Future<void> restore();
}

/// Applies fullscreen through Flutter's system UI and orientation APIs.
final class SystemSourceVideoFullscreenPlatform implements SourceVideoFullscreenPlatform {
  const SystemSourceVideoFullscreenPlatform();

  @override
  Future<void> enterPortrait() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  Future<void> enterLandscape() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  Future<void> restore() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}

/// Owns one video route's serialized fullscreen platform state.
final class SourceVideoFullscreenController {
  SourceVideoFullscreenController() : _platform = const SystemSourceVideoFullscreenPlatform();

  @visibleForTesting
  SourceVideoFullscreenController.withPlatform(this._platform);

  final SourceVideoFullscreenPlatform _platform;

  Future<void> _tail = Future<void>.value();
  bool _fullscreen = false;
  bool _active = false;
  bool _restoreNeeded = false;
  bool _closed = false;

  /// Enters the route-scoped portrait immersive player mode.
  Future<void> activate() {
    if (_closed) return Future<void>.value();
    return _append(() async {
      if (_closed || _active) return;
      _restoreNeeded = true;
      await _platform.enterPortrait();
      _active = true;
    });
  }

  /// Applies the latest player fullscreen intent in request order.
  Future<void> setFullscreen(bool fullscreen) {
    if (_closed) return Future<void>.value();
    return _append(() async {
      if (_closed || _fullscreen == fullscreen) return;
      if (fullscreen) {
        _restoreNeeded = true;
        await _platform.enterLandscape();
        _active = true;
        _fullscreen = true;
        return;
      }
      _restoreNeeded = true;
      await _platform.enterPortrait();
      _active = true;
      _fullscreen = false;
    });
  }

  /// Rejects later intents and restores normal app chrome after pending work.
  Future<void> restoreAndClose() {
    _closed = true;
    return _append(_restore);
  }

  Future<void> _restore() async {
    if (!_restoreNeeded && !_active && !_fullscreen) return;
    await _platform.restore();
    _fullscreen = false;
    _active = false;
    _restoreNeeded = false;
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = _tail.then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next;
  }
}
