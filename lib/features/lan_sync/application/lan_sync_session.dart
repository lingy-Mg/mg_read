/// 扫码和已配对同步共用的网关会话所有权。
/// 网关保存预览和导入批次；从预览到清理完成只能由一个会话使用。
/// 取消先等待已发出的网关调用退出，再清理批次，防止旧清理影响新会话。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/features/lan_sync/application/lan_sync_gateway.dart';

final lanSyncSessionCoordinatorProvider = Provider((ref) => LanSyncSessionCoordinator());

final class LanSyncSessionCoordinator {
  LanSyncSession? _active;

  LanSyncSession? tryAcquire(LanSyncGateway gateway) {
    if (_active != null) return null;
    return _active = LanSyncSession._(gateway, () => _active = null);
  }
}

final class LanSyncSession {
  LanSyncSession._(this.gateway, this._release);

  final LanSyncGateway gateway;
  final void Function() _release;
  final Set<Future<void>> _pending = {};
  Future<void>? _closing;

  Future<T> run<T>(Future<T> Function(LanSyncGateway) action) {
    if (_closing != null) return Future.error(StateError('lan_sync_session_closed'));
    final result = Future<T>.sync(() => action(gateway));
    final observed = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _pending.add(observed);
    unawaited(observed.then((_) => _pending.remove(observed)));
    return result;
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await Future.wait(_pending.toList());
      await gateway.cancelPluginImports();
    } on Object {
      // 清理失败不能替换原始业务错误。
    } finally {
      _release();
    }
  }
}
