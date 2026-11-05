/// Shared host ownership for TV orientation and transient media system UI.
///
/// Responsibilities:
/// - Merge overlapping audio and video immersive requests without allowing one
///   retiring host to restore system bars underneath another active host.
/// - Serialize portrait, landscape and normal app-chrome platform changes.
/// - Keep the app-root TV landscape lease above media portrait requests;
///   preserve normal system bars when no immersive media host is active.
///
/// Notes:
/// - Player packages remain independent; only the app host shares this
///   platform boundary.
/// - Every lease must be released when its owning host is minimized or closed;
///   the app-root TV lease lasts until TV mode is disabled or the root closes.
library;

import 'package:flutter/services.dart';

enum SourceMediaSystemUiMode { portraitImmersive, landscapeImmersive, landscapeEdgeToEdge }

/// Platform operations used by [SourceMediaSystemUiCoordinator].
abstract interface class SourceMediaSystemUiPlatform {
  Future<void> enterPortrait();

  Future<void> enterLandscape({bool immersive = true});

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
  Future<void> enterLandscape({bool immersive = true}) async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  @override
  Future<void> restore() async {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
}

/// Serializes system UI requested by active media hosts and the app TV baseline.
final class SourceMediaSystemUiCoordinator {
  SourceMediaSystemUiCoordinator._(this._platform);

  SourceMediaSystemUiCoordinator.withPlatform(this._platform);

  static final SourceMediaSystemUiCoordinator instance = SourceMediaSystemUiCoordinator._(const SystemSourceMediaSystemUiPlatform());

  final SourceMediaSystemUiPlatform _platform;
  final Map<Object, SourceMediaSystemUiMode> _requests = <Object, SourceMediaSystemUiMode>{};

  Future<void>? _tail;
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
    if (_requests.values.contains(SourceMediaSystemUiMode.landscapeEdgeToEdge)) {
      return _requests.values.contains(SourceMediaSystemUiMode.portraitImmersive)
          ? SourceMediaSystemUiMode.landscapeImmersive
          : SourceMediaSystemUiMode.landscapeEdgeToEdge;
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
      case SourceMediaSystemUiMode.landscapeEdgeToEdge:
        await _platform.enterLandscape(immersive: false);
    }
    _appliedMode = target;
  }

  Future<void> _append(Future<void> Function() operation) {
    final next = (_tail ?? Future<void>.value()).then<void>((_) => operation(), onError: (_, _) => operation());
    _tail = next;
    return next.whenComplete(() {
      if (identical(_tail, next)) _tail = null;
    });
  }
}

/// One media host or app root's idempotent request handle.
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
