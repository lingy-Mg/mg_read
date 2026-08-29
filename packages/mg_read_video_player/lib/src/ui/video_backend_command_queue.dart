/// Serial execution lane for commands targeting one playback backend.
///
/// Responsibilities:
/// - Preserve invocation order across open, play, pause, seek, rate and volume.
/// - Keep the lane usable after an individual command fails.
///
/// Notes:
/// - Callers still own generation checks and user-visible failure reporting.
library;

/// Package-private FIFO queue for asynchronous backend commands.
final class VideoBackendCommandQueue {
  Future<void> _tail = Future<void>.value();

  /// Enqueues [command] and returns the command's unswallowed result.
  Future<void> enqueue(Future<void> Function() command) {
    final operation = _tail.then((_) => command());
    _tail = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }
}
