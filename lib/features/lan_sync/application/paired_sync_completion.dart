/// 反向连接的等待边界：连接到达后停止连接超时，传输由协议各阶段的超时约束。
/// 错误用值保存，使 UDP 发送尚未返回时到达的失败也不会成为未处理异步错误。
library;

import 'dart:async';

final class PairedSyncCompletion<T> {
  final Completer<void> _connected = Completer();
  final Completer<({T? value, Object? error, StackTrace? stack})> _result = Completer();

  bool get isCompleted => _result.isCompleted;

  void connected() {
    if (!_connected.isCompleted) _connected.complete();
  }

  void complete(T value) {
    if (!isCompleted) _result.complete((value: value, error: null, stack: null));
  }

  void completeError(Object error, StackTrace stack) {
    if (!isCompleted) _result.complete((value: null, error: error, stack: stack));
  }

  Future<T> wait(Duration connectionTimeout) async {
    await Future.any<void>([_connected.future, _result.future.then((_) {})]).timeout(connectionTimeout);
    final result = await _result.future;
    if (result.error != null) Error.throwWithStackTrace(result.error!, result.stack!);
    return result.value as T;
  }
}
