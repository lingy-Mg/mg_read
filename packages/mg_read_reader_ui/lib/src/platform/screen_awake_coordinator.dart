import 'dart:async';

import '../api/models.dart';
import 'reader_platform.dart';

/// Coordinates reader-owned system UI across concurrently mounted readers.
///
/// A holder may request either screen-awake, immersive mode, or both. The
/// platform receives only aggregate transitions. A release is issued without
/// waiting for a slow acquire; if an older call completes late, the newest
/// aggregate intent is applied again.
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
    bool immersiveMode = false,
  }) {
    _holders[holder] = _SystemUiRequest(
      keepScreenOn: keepScreenOn,
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

  _SystemUiRequest _aggregate() => _SystemUiRequest(
    keepScreenOn: _holders.values.any((v) => v.keepScreenOn),
    immersiveMode: _holders.values.any((v) => v.immersiveMode),
  );
}

class _SystemUiRequest {
  const _SystemUiRequest({
    this.keepScreenOn = false,
    this.immersiveMode = false,
  });
  final bool keepScreenOn;
  final bool immersiveMode;

  @override
  bool operator ==(Object other) =>
      other is _SystemUiRequest &&
      keepScreenOn == other.keepScreenOn &&
      immersiveMode == other.immersiveMode;

  @override
  int get hashCode => Object.hash(keepScreenOn, immersiveMode);
}
