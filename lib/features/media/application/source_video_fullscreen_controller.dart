/// Host-owned fullscreen lifetime for transient source-video routes.
///
/// The controller keeps the normal player in portrait immersive mode, forces
/// landscape while fullscreen, and releases its shared media-system-UI lease
/// before the route is left.
library;

import 'package:flutter/foundation.dart';

import 'package:mg_read/features/media/application/source_media_system_ui_controller.dart';

/// Platform operations used by [SourceVideoFullscreenController].
///
/// This seam is public only so the host behavior can be tested without sending
/// real platform-channel messages.
@visibleForTesting
abstract interface class SourceVideoFullscreenPlatform implements SourceMediaSystemUiPlatform {}

/// Applies fullscreen through Flutter's system UI and orientation APIs.
final class SystemSourceVideoFullscreenPlatform implements SourceVideoFullscreenPlatform {
  const SystemSourceVideoFullscreenPlatform();

  static const SourceMediaSystemUiPlatform _delegate = SystemSourceMediaSystemUiPlatform();

  @override
  Future<void> enterPortrait() => _delegate.enterPortrait();

  @override
  Future<void> enterLandscape() => _delegate.enterLandscape();

  @override
  Future<void> restore() => _delegate.restore();
}

/// Owns one video route's serialized fullscreen platform state.
final class SourceVideoFullscreenController {
  SourceVideoFullscreenController() : _lease = SourceMediaSystemUiLease();

  @visibleForTesting
  SourceVideoFullscreenController.withPlatform(SourceVideoFullscreenPlatform platform)
    : _lease = SourceMediaSystemUiLease.withCoordinator(SourceMediaSystemUiCoordinator.withPlatform(platform));

  final SourceMediaSystemUiLease _lease;
  bool _closed = false;

  /// Enters the route-scoped portrait immersive player mode.
  Future<void> activate() {
    if (_closed) return Future<void>.value();
    return _lease.setMode(SourceMediaSystemUiMode.portraitImmersive);
  }

  /// Applies the latest player fullscreen intent in request order.
  Future<void> setFullscreen(bool fullscreen) {
    if (_closed) return Future<void>.value();
    return _lease.setMode(fullscreen ? SourceMediaSystemUiMode.landscapeImmersive : SourceMediaSystemUiMode.portraitImmersive);
  }

  /// Rejects later intents and restores normal app chrome after pending work.
  Future<void> restoreAndClose() {
    _closed = true;
    return _lease.releaseAndClose();
  }
}
