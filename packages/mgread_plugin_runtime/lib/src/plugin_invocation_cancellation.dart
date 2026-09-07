part of mgread_plugin_runtime;

/// Caller-owned cancellation for one or more related Runtime invocations.
///
/// Cancellation is idempotent. Desktop forwards it through the negotiated wire
/// cancel frame; Android aborts the matching embedded invocation. Callers may
/// share one instance across parallel detail and catalog requests.
final class PluginInvocationCancellation {
  bool _isCancelled = false;
  int _nextListenerId = 0;
  final Map<int, VoidCallback> _listeners = <int, VoidCallback>{};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    final listeners = List<VoidCallback>.of(_listeners.values);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  VoidCallback _listen(VoidCallback listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    final id = ++_nextListenerId;
    _listeners[id] = listener;
    return () => _listeners.remove(id);
  }

  void _throwIfCancelled() {
    if (_isCancelled) throw _pluginInvocationCancelled;
  }
}

const PluginRuntimeException _pluginInvocationCancelled =
    PluginRuntimeException(
      'cancelled',
      'The Runtime capability call was cancelled.',
    );

Future<T> _awaitPluginInvocation<T>(
  Future<T> operation,
  PluginInvocationCancellation? cancellation, {
  VoidCallback? onCancel,
}) async {
  if (cancellation == null) return operation;
  cancellation._throwIfCancelled();
  final cancelled = Completer<T>();
  final raced = Future.any<T>(<Future<T>>[operation, cancelled.future]);
  final stopListening = cancellation._listen(() {
    onCancel?.call();
    if (!cancelled.isCompleted)
      cancelled.completeError(_pluginInvocationCancelled);
  });
  try {
    return await raced;
  } finally {
    stopListening();
  }
}
