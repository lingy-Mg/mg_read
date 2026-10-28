/// Lifecycle-owned refresh queue. User requests precede queued automatic work;
/// four books total and two books per source may perform network work at once.
/// No transport or persistence is owned here; running work is never interrupted.
library;

import 'dart:async';

final class LibraryRefreshSkipped implements Exception {
  const LibraryRefreshSkipped();
}

final class LibraryRefreshQueue {
  final List<_RefreshJob> _pending = [];
  final Map<String, int> _sources = {};
  int _running = 0;

  Future<bool> run(String source, Future<bool> Function() work, {required bool automatic, bool Function()? mayStart}) {
    final job = _RefreshJob(source, work, automatic, mayStart);
    _pending.add(job);
    _drain();
    return job.completer.future;
  }

  void _drain() {
    _pending.sort((a, b) => (a.automatic ? 1 : 0).compareTo(b.automatic ? 1 : 0));
    while (_running < 4) {
      final index = _pending.indexWhere((job) => (_sources[job.source] ?? 0) < 2);
      if (index < 0) return;
      final job = _pending.removeAt(index);
      if (job.automatic && job.mayStart?.call() == false) {
        job.completer.completeError(const LibraryRefreshSkipped());
        continue;
      }
      _running++;
      _sources[job.source] = (_sources[job.source] ?? 0) + 1;
      unawaited(_execute(job));
    }
  }

  Future<void> _execute(_RefreshJob job) async {
    try {
      job.completer.complete(await job.work());
    } catch (error, stack) {
      job.completer.completeError(error, stack);
    } finally {
      _running--;
      final remaining = _sources[job.source]! - 1;
      if (remaining == 0) {
        _sources.remove(job.source);
      } else {
        _sources[job.source] = remaining;
      }
      _drain();
    }
  }
}

final class _RefreshJob {
  _RefreshJob(this.source, this.work, this.automatic, this.mayStart);
  final String source;
  final Future<bool> Function() work;
  final bool automatic;
  final bool Function()? mayStart;
  final Completer<bool> completer = Completer<bool>();
}
