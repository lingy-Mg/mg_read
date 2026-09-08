import 'dart:async';

import '../api/models.dart';
import 'reader_platform.dart';

/// Coordinates temporary system UI requests from readers and host operations.
///
/// A holder may request either screen-awake, immersive mode, or both. A dimming
/// request keeps the display powered without overriding a concurrent holder
/// that requires full brightness. The platform receives only aggregate
/// transitions. A release is issued without waiting for a slow acquire; if an
/// older call completes late, the newest aggregate intent is applied again.
/// Host operations use a unique holder and release it when their work ends;
/// requests do not persist preferences or override other holders.
class ScreenAwakeCoordinator {
  ScreenAwakeCoordinator._();

  static final ScreenAwakeCoordinator instance = ScreenAwakeCoordinator._();

  final Map<Object, _SystemUiRequest> _holders = <Object, _SystemUiRequest>{};
  Future<void> _operation = Future<void>.value();
  _SystemUiRequest? _scheduled = const _SystemUiRequest();
  int _transitionGeneration = 0;

  int get holderCount => _holders.length;

  Future<void> acquire(
    Object holder, {
    bool keepScreenOn = true,
    bool allowScreenDimming = false,
    bool immersiveMode = false,
  }) {
    _holders[holder] = _SystemUiRequest(
      keepScreenOn: keepScreenOn,
      allowScreenDimming: allowScreenDimming,
      immersiveMode: immersiveMode,
    );
    return _applyIfChanged();
  }

  Future<void> release(Object holder) {
    if (_holders.remove(holder) == null) return _operation;
    return _applyIfChanged();
  }

  Future<void> _applyIfChanged() {
    final _SystemUiRequest target = _aggregate();
    if (target == _scheduled) return _operation;
    _scheduled = target;
    final int generation = ++_transitionGeneration;
    final Future<void> transition = () async {
      try {
        await ReaderPlatform.instance.setReaderSystemUi(
          keepScreenOn: target.keepScreenOn,
          allowScreenDimming: target.allowScreenDimming,
          immersiveMode: target.immersiveMode,
        );
      } catch (error) {
        // A failed transition must not suppress an identical retry.
        if (generation == _transitionGeneration && _scheduled == target) {
          _scheduled = null;
        }
        throw ReaderFailure(
          ReaderFailureKind.platform,
          target.keepScreenOn
              ? '无法保持屏幕常亮'
              : target.immersiveMode
              ? '无法启用沉浸阅读'
              : '无法恢复系统显示状态',
          cause: error,
        );
      }
      if (generation != _transitionGeneration && _aggregate() != target) {
        // The stale call may have overwritten a newer platform state. Reapply
        // the aggregate intent without waiting for unrelated slow callbacks.
        _scheduled = null;
        _applyIfChanged().ignore();
      }
    }();
    _operation = transition.then<void>((_) {}, onError: (_) {});
    return transition;
  }

  _SystemUiRequest _aggregate() {
    final bool keepScreenOn = _holders.values.any((v) => v.keepScreenOn);
    final bool requiresBrightness = _holders.values.any(
      (v) => v.keepScreenOn && !v.allowScreenDimming,
    );
    return _SystemUiRequest(
      keepScreenOn: keepScreenOn,
      allowScreenDimming: keepScreenOn && !requiresBrightness,
      immersiveMode: _holders.values.any((v) => v.immersiveMode),
    );
  }
}

class _SystemUiRequest {
  const _SystemUiRequest({
    this.keepScreenOn = false,
    this.allowScreenDimming = false,
    this.immersiveMode = false,
  });
  final bool keepScreenOn;
  final bool allowScreenDimming;
  final bool immersiveMode;

  @override
  bool operator ==(Object other) =>
      other is _SystemUiRequest &&
      keepScreenOn == other.keepScreenOn &&
      allowScreenDimming == other.allowScreenDimming &&
      immersiveMode == other.immersiveMode;

  @override
  int get hashCode =>
      Object.hash(keepScreenOn, allowScreenDimming, immersiveMode);
}
