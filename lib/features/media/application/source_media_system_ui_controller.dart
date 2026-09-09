/// Shared host ownership for transient media system UI.
///
/// Responsibilities:
/// - Merge overlapping audio and video immersive requests without allowing one
///   retiring host to restore system bars underneath another active host.
/// - Serialize portrait, landscape and normal app-chrome platform changes.
///
/// Notes:
/// - Player packages remain independent; only the app host shares this
///   platform boundary.
/// - Every lease must be released when its owning host is minimized or closed.
library;

import 'package:flutter/services.dart';

enum SourceMediaSystemUiMode { portraitImmersive, landscapeImmersive }

/// Platform operations used by [SourceMediaSystemUiCoordinator].
abstract interface class SourceMediaSystemUiPlatform {
  Future<void> enterPortrait();

  Future<void> enterLandscape();

  Future<void> restore();
}

/// Applies media presentation through Flutter's system UI APIs.
final class SystemSourceMediaSystemUiPlatform implements SourceMediaSystemUiPlatform {
  const SystemSourceMediaSystemUiPlatform();

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

/// Serializes the effective system UI requested by all active media hosts.
final class SourceMediaSystemUiCoordinator {
  SourceMediaSystemUiCoordinator._(this._platform);

  SourceMediaSystemUiCoordinator.withPlatform(this._platform);

  static final SourceMediaSystemUiCoordinator instance = SourceMediaSystemUiCoordinator._(const SystemSourceMediaSystemUiPlatform());

  final SourceMediaSystemUiPlatform _platform;
  final Map<Object, SourceMediaSystemUiMode> _requests = <Object, SourceMediaSystemUiMode>{};

  Future<void> _tail = Future<void>.value();
  SourceMediaSystemUiMode? _appliedMode;
  bool _restoreNeeded = false;

  Future<void> setMode(Object owner, SourceMediaSystemUiMode mode) {
    return _append(() async {
      _requests[owner] = mode;
      await _synchronize();
    });
  }

  Future<void> release(Object owner) {
    return _append(() async {
      _requests.remove(owner);
      await _synchronize();
    });
  }

  SourceMediaSystemUiMode? get _targetMode {
    if (_requests.values.contains(SourceMediaSystemUiMode.landscapeImmersive)) {
      return SourceMediaSystemUiMode.landscapeImmersive;
    }
    if (_requests.isNotEmpty) {
      return SourceMediaSystemUiMode.portraitImmersive;
    }
    return null;
  }

  Future<void> _synchronize() async {
    final target = _targetMode;
    if (target == null) {
      if (!_restoreNeeded && _appliedMode == null) return;
      await _platform.restore();
      _appliedMode = null;
      _restoreNeeded = false;
      return;
    }
    if (_appliedMode == target) return;
    _restoreNeeded = true;
    switch (target) {
      case SourceMediaSystemUiMode.portraitImmersive:
        await _platform.enterPortrait();
      case SourceMediaSystemUiMode.landscapeImmersive:
        await _platform.enterLandscape();
    }
    _appliedMode = target;
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = _tail.then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next;
  }
}

/// One media host's idempotent request handle.
final class SourceMediaSystemUiLease {
  SourceMediaSystemUiLease() : _coordinator = SourceMediaSystemUiCoordinator.instance;

  SourceMediaSystemUiLease.withCoordinator(this._coordinator);

  final SourceMediaSystemUiCoordinator _coordinator;
  final Object _owner = Object();
  bool _closed = false;

  Future<void> setMode(SourceMediaSystemUiMode mode) {
    if (_closed) return Future<void>.value();
    return _coordinator.setMode(_owner, mode);
  }

  Future<void> release() {
    if (_closed) return Future<void>.value();
    return _coordinator.release(_owner);
  }

  Future<void> releaseAndClose() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return _coordinator.release(_owner);
  }
}
