/// Host-owned fullscreen lifetime for transient source-video routes.
///
/// Mobile playback uses route-scoped orientation and system bars. Windows
/// playback instead makes the current native window fullscreen on its current
/// display, without imposing a mobile orientation.
/// TV routes enter landscape immediately and never fall back to portrait.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'package:mg_read/features/media/application/source_media_system_ui_controller.dart';

/// Platform operations used by [SourceVideoFullscreenController].
///
/// This seam is public only so the host behavior can be tested without sending
/// real platform-channel messages.
@visibleForTesting
abstract interface class SourceVideoFullscreenPlatform implements SourceMediaSystemUiPlatform {
  /// Whether fullscreen is owned by the desktop window rather than system UI.
  bool get usesDesktopWindowFullscreen;

  /// Enters or leaves fullscreen on the current native desktop window.
  Future<void> setDesktopWindowFullscreen(bool fullscreen);
}

/// Applies fullscreen through Flutter's system UI and orientation APIs.
final class SystemSourceVideoFullscreenPlatform implements SourceVideoFullscreenPlatform {
  const SystemSourceVideoFullscreenPlatform();

  static const SourceMediaSystemUiPlatform _delegate = SystemSourceMediaSystemUiPlatform();

  @override
  bool get usesDesktopWindowFullscreen => Platform.isWindows;

  @override
  Future<void> enterPortrait() => _delegate.enterPortrait();

  @override
  Future<void> enterLandscape() => _delegate.enterLandscape();

  @override
  Future<void> restore() => _delegate.restore();

  @override
  Future<void> setDesktopWindowFullscreen(bool fullscreen) => windowManager.setFullScreen(fullscreen);
}

/// Owns one video route's serialized fullscreen platform state.
final class SourceVideoFullscreenController {
  SourceVideoFullscreenController({this.tvMode = false})
    : _platform = const SystemSourceVideoFullscreenPlatform(),
      _lease = SourceMediaSystemUiLease();

  @visibleForTesting
  SourceVideoFullscreenController.withPlatform(SourceVideoFullscreenPlatform platform, {this.tvMode = false})
    : _platform = platform,
      _lease = SourceMediaSystemUiLease.withCoordinator(SourceMediaSystemUiCoordinator.withPlatform(platform));

  final SourceVideoFullscreenPlatform _platform;
  final bool tvMode;
  final SourceMediaSystemUiLease _lease;
  Future<void> _desktopTail = Future<void>.value();
  bool _desktopRestoreNeeded = false;
  bool _closed = false;

  /// Enters the route-scoped immersive mode, landscape for TV.
  Future<void> activate() {
    if (_closed) return Future<void>.value();
    if (_platform.usesDesktopWindowFullscreen) return tvMode ? setFullscreen(true) : Future<void>.value();
    return _lease.setMode(tvMode ? SourceMediaSystemUiMode.landscapeImmersive : SourceMediaSystemUiMode.portraitImmersive);
  }

  /// Applies the latest player fullscreen intent in request order.
  Future<void> setFullscreen(bool fullscreen) {
    if (_closed) return Future<void>.value();
    if (_platform.usesDesktopWindowFullscreen) {
      _desktopRestoreNeeded = true;
      return _appendDesktop(() async {
        await _platform.setDesktopWindowFullscreen(fullscreen);
        _desktopRestoreNeeded = fullscreen;
      });
    }
    return _lease.setMode((fullscreen || tvMode) ? SourceMediaSystemUiMode.landscapeImmersive : SourceMediaSystemUiMode.portraitImmersive);
  }

  /// Rejects later intents and restores normal app chrome after pending work.
  Future<void> restoreAndClose() {
    _closed = true;
    if (_platform.usesDesktopWindowFullscreen) {
      return _appendDesktop(() async {
        if (!_desktopRestoreNeeded) return;
        try {
          await _platform.setDesktopWindowFullscreen(false);
        } finally {
          _desktopRestoreNeeded = false;
        }
      });
    }
    return _lease.releaseAndClose();
  }

  Future<void> _appendDesktop(Future<void> Function() operation) {
    final next = _desktopTail.then<void>((_) => operation(), onError: (_, _) => operation());
    _desktopTail = next;
    return next;
  }
}
