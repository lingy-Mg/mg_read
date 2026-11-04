/// Owns companion command admission, control leases, deduplication, ordering,
/// and cancellation. Platform integrations supply the actual command handler.
///
/// All time values use the injected monotonic clock; deadlineMs is interpreted
/// in that same host clock domain. A transport must translate client clocks.
library;

import 'dart:async';

import '../domain/companion_command.dart';

typedef CompanionCommandHandler =
    Future<CompanionReceipt> Function(String peerId, CompanionCommand command, CompanionExecutionContext context);

/// Passed to integrations so long operations can fence their final side effect.
final class CompanionExecutionContext {
  CompanionExecutionContext._(this._isCurrent, this._report, this._commitPlaybackChange, this.peerId);
  final String peerId;

  final bool Function() _isCurrent;
  final void Function(CompanionCommandPhase phase, Map<String, Object?> details) _report;
  final void Function() _commitPlaybackChange;

  bool get isCurrent => _isCurrent();

  void ensureCurrent() {
    if (!isCurrent) throw const CompanionCommandCancelledException();
  }

  /// Commits this command's media-session replacement while preserving its
  /// own execution fence and invalidating commands queued for the old session.
  void commitPlaybackChange() {
    ensureCurrent();
    _commitPlaybackChange();
  }

  void report(CompanionCommandPhase phase, {Map<String, Object?> details = const {}}) {
    if (!phase.isProgress) throw ArgumentError.value(phase, 'phase', 'must be a progress phase');
    if (isCurrent) _report(phase, details);
  }
}

final class CompanionCommandCancelledException implements Exception {
  const CompanionCommandCancelledException();
}

final class CompanionCommandEngine {
  CompanionCommandEngine({
    required this.hostEpoch,
    required this._handler,
    int Function()? nowMs,
    this.leaseDuration = const Duration(seconds: 15),
    this.cacheTtl = const Duration(minutes: 10),
    this.maxCacheEntries = 2048,
    this.maxPendingCommands = 64,
    this.localPriorityDuration = const Duration(seconds: 3),
    Duration Function(CompanionCommandType)? executionBudget,
  }) : _nowMs = nowMs ?? _defaultMonotonicMs,
       _executionBudget = executionBudget ?? _defaultExecutionBudget {
    if (hostEpoch.isEmpty || hostEpoch.length > CompanionCommand.maxHostEpochLength) {
      throw ArgumentError.value(hostEpoch, 'hostEpoch');
    }
    if (leaseDuration <= Duration.zero || cacheTtl <= Duration.zero || maxCacheEntries < 1 || maxPendingCommands < 1) {
      throw ArgumentError('leaseDuration, cacheTtl, maxCacheEntries, and maxPendingCommands must be positive');
    }
    if (CompanionCommandType.values.any((type) => _executionBudget(type) <= Duration.zero)) {
      throw ArgumentError('execution budgets must be positive');
    }
  }

  final String hostEpoch;
  final CompanionCommandHandler _handler;
  final int Function() _nowMs;
  final Duration leaseDuration;
  final Duration cacheTtl;
  final int maxCacheEntries;
  final int maxPendingCommands;
  final Duration localPriorityDuration;
  final Duration Function(CompanionCommandType) _executionBudget;

  final StreamController<CompanionReceipt> _receipts = StreamController<CompanionReceipt>.broadcast(sync: true);
  final Map<String, _CommandRecord> _records = <String, _CommandRecord>{};
  final Map<String, int> _highWater = <String, int>{};
  final Map<String, int> _peerTokens = <String, int>{};
  final List<_QueuedCommand> _queue = <_QueuedCommand>[];

  String? _controlOwnerId;
  int _controlGeneration = 0;
  int _playbackGeneration = 0;
  int _leaseExpiresAtMs = 0;
  int _globalToken = 0;
  int _localPriorityUntilMs = 0;
  bool _pumping = false;
  bool _closed = false;
  String? _activePeerId;
  Completer<void>? _activeCancellation;

  String? get controlOwnerId {
    _expireLeaseIfNeeded();
    return _controlOwnerId;
  }

  int get controlGeneration => _controlGeneration;
  int get playbackGeneration => _playbackGeneration;
  int get serverNowMs => _nowMs();
  int getPeerSequenceHighWater(String peerId) => _highWater[peerId] ?? -1;
  CompanionReceipt? receiptFor(String peerId, String commandId) {
    final record = _records[_recordKey(peerId, commandId)];
    if (record == null || record.createdAtMs < _nowMs() - cacheTtl.inMilliseconds) return null;
    return record.latestReceipt;
  }

  Stream<CompanionReceipt> get receipts => _receipts.stream;

  /// Admit a command. Same-id retries share the exact in-flight future/result.
  Future<CompanionReceipt> execute(String peerId, CompanionCommand command) {
    if (_closed) return Future.value(_receipt(peerId, command, CompanionCommandPhase.failed, code: 'engine_closed'));
    _pruneRecords();
    final key = _recordKey(peerId, command.id);
    final fingerprint = command.fingerprint();
    final existing = _records[key];
    if (existing != null) {
      if (existing.fingerprint != fingerprint) {
        final conflict = _receipt(peerId, command, CompanionCommandPhase.failed, code: 'command_id_conflict');
        _emit(conflict, record: false);
        return Future.value(conflict);
      }
      return existing.completer.future;
    }

    final rejection = _validateAdmission(peerId, command);
    if (rejection != null) {
      _emit(_receipt(peerId, command, rejection.$1, code: rejection.$2), record: false);
      final future = Future<CompanionReceipt>.value(_receipt(peerId, command, rejection.$1, code: rejection.$2));
      _remember(key, fingerprint, future);
      return future;
    }

    final pendingSeek = command.type == CompanionCommandType.seek
        ? _queue.lastWhereOrNull((item) => item.command.type == CompanionCommandType.seek)
        : null;
    if (_queue.length >= maxPendingCommands && pendingSeek == null) {
      final busy = _receipt(peerId, command, CompanionCommandPhase.failed, code: 'receiver_busy');
      _emit(busy, record: false);
      return Future.value(busy);
    }

    _highWater[peerId] = command.clientSeq;
    final completer = Completer<CompanionReceipt>();
    _records[key] = _CommandRecord(fingerprint, _nowMs(), completer);
    _emit(_receipt(peerId, command, CompanionCommandPhase.received));
    _emit(_receipt(peerId, command, CompanionCommandPhase.accepted));
    final queued = _QueuedCommand(peerId, command, completer);
    if (pendingSeek != null) {
      _queue.remove(pendingSeek);
      pendingSeek.completer.complete(
        _receipt(pendingSeek.peerId, pendingSeek.command, CompanionCommandPhase.superseded, code: 'seek_superseded'),
      );
    }
    _queue.add(queued);
    _pump();
    return completer.future;
  }

  /// Explicitly grant a takeover after the TV UI has approved it.
  void grantControl(String peerId) {
    _ensureOpen();
    if (peerId.isEmpty) throw ArgumentError.value(peerId, 'peerId');
    _invalidateAll();
    _controlOwnerId = peerId;
    _localPriorityUntilMs = 0;
    _controlGeneration++;
    _renewLease();
  }

  /// Renew an active controller's lease. Unknown peers cannot extend a lease.
  bool renewControl(String peerId) {
    _expireLeaseIfNeeded();
    if (_closed || _controlOwnerId != peerId) return false;
    _renewLease();
    return true;
  }

  /// Cancel that peer's queued/in-flight work and release its lease.
  void disconnect(String peerId) {
    _peerTokens[peerId] = (_peerTokens[peerId] ?? 0) + 1;
    if (_activePeerId == peerId) _cancelActive();
    _cancelQueued((item) => item.peerId == peerId, 'peer_disconnected');
    if (_controlOwnerId == peerId) {
      _controlOwnerId = null;
      _controlGeneration++;
      _leaseExpiresAtMs = 0;
    }
  }

  /// A local remote/key interaction takes control away from companions.
  void localInteraction() {
    _localPriorityUntilMs = _nowMs() + localPriorityDuration.inMilliseconds;
    _invalidateAll();
    if (_controlOwnerId != null) _controlGeneration++;
    _controlOwnerId = null;
    _leaseExpiresAtMs = 0;
  }

  /// Fence commands tied to the previous playback session.
  void playbackChanged() {
    _playbackGeneration++;
    _globalToken++;
    _cancelQueued((_) => true, 'playback_changed');
  }

  int _commitPlaybackChange() {
    _playbackGeneration++;
    _globalToken++;
    _cancelQueued(
      (item) =>
          item.command.type != CompanionCommandType.acquireControl &&
          item.command.type != CompanionCommandType.releaseControl &&
          item.command.playbackGeneration != _playbackGeneration,
      'playback_changed',
    );
    return _playbackGeneration;
  }

  static Duration _defaultExecutionBudget(CompanionCommandType type) => switch (type) {
    CompanionCommandType.handoff ||
    CompanionCommandType.selectEpisode ||
    CompanionCommandType.nextEpisode ||
    CompanionCommandType.previousEpisode => const Duration(seconds: 30),
    _ => const Duration(seconds: 5),
  };

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _invalidateAll();
    _cancelQueued((_) => true, 'engine_closed');
    await _receipts.close();
  }

  (CompanionCommandPhase, String)? _validateAdmission(String peerId, CompanionCommand command) {
    if (peerId.isEmpty || peerId.length > 128) return (CompanionCommandPhase.failed, 'invalid_peer');
    if (command.hostEpoch != hostEpoch) return (CompanionCommandPhase.failed, 'stale_host_epoch');
    final now = _nowMs();
    if (command.deadlineMs < now) return (CompanionCommandPhase.expired, 'deadline_expired');
    if (command.deadlineMs - now > 5000) return (CompanionCommandPhase.failed, 'deadline_too_far');
    final high = _highWater[peerId];
    if (high != null && command.clientSeq <= high) return (CompanionCommandPhase.failed, 'stale_sequence');
    if (command.type == CompanionCommandType.acquireControl) {
      if (now < _localPriorityUntilMs) return (CompanionCommandPhase.failed, 'local_control_active');
      _expireLeaseIfNeeded();
      if (_controlOwnerId != null && _controlOwnerId != peerId) {
        return (CompanionCommandPhase.failed, 'control_owned');
      }
      if (command.controlGeneration != _controlGeneration) {
        return (CompanionCommandPhase.failed, 'stale_control_generation');
      }
      return null;
    }
    if (command.type == CompanionCommandType.releaseControl) {
      if (_controlOwnerId != peerId) return (CompanionCommandPhase.failed, 'not_control_owner');
      if (command.controlGeneration != _controlGeneration) {
        return (CompanionCommandPhase.failed, 'stale_control_generation');
      }
      return null;
    }
    _expireLeaseIfNeeded();
    if (_controlOwnerId != peerId) return (CompanionCommandPhase.failed, 'control_required');
    if (command.controlGeneration != _controlGeneration) {
      return (CompanionCommandPhase.failed, 'stale_control_generation');
    }
    if (command.playbackGeneration != _playbackGeneration) {
      return (CompanionCommandPhase.failed, 'stale_playback_generation');
    }
    return null;
  }

  void _pump() {
    if (_pumping || _closed) return;
    _pumping = true;
    scheduleMicrotask(() async {
      try {
        while (_queue.isNotEmpty && !_closed) {
          final item = _queue.removeAt(0);
          if (item.completer.isCompleted) continue;
          final result = await _run(item);
          _emit(result);
          if (!item.completer.isCompleted) item.completer.complete(result);
        }
      } finally {
        _pumping = false;
        if (_queue.isNotEmpty && !_closed) _pump();
      }
    });
  }

  Future<CompanionReceipt> _run(_QueuedCommand item) async {
    final peerId = item.peerId;
    final command = item.command;
    final now = _nowMs();
    if (_closed) return _receipt(peerId, command, CompanionCommandPhase.cancelled, code: 'engine_closed');
    if (command.deadlineMs < now) return _receipt(peerId, command, CompanionCommandPhase.expired, code: 'deadline_expired');
    if (command.hostEpoch != hostEpoch) return _receipt(peerId, command, CompanionCommandPhase.failed, code: 'stale_host_epoch');

    if (command.type == CompanionCommandType.acquireControl) {
      _expireLeaseIfNeeded();
      if (_controlOwnerId != null && _controlOwnerId != peerId) {
        return _receipt(peerId, command, CompanionCommandPhase.failed, code: 'control_owned');
      }
      if (command.controlGeneration != _controlGeneration) {
        return _receipt(peerId, command, CompanionCommandPhase.failed, code: 'stale_control_generation');
      }
      if (_controlOwnerId == null) _controlGeneration++;
      _controlOwnerId = peerId;
      _renewLease();
      return _receipt(peerId, command, CompanionCommandPhase.applied, details: {'controlGeneration': _controlGeneration});
    }
    if (command.type == CompanionCommandType.releaseControl) {
      if (_controlOwnerId != peerId || command.controlGeneration != _controlGeneration) {
        return _receipt(peerId, command, CompanionCommandPhase.failed, code: 'control_lease_changed');
      }
      _controlOwnerId = null;
      _controlGeneration++;
      _leaseExpiresAtMs = 0;
      _peerTokens[peerId] = (_peerTokens[peerId] ?? 0) + 1;
      _cancelQueued((queued) => queued.peerId == peerId, 'control_released');
      return _receipt(peerId, command, CompanionCommandPhase.applied, details: {'controlGeneration': _controlGeneration});
    }

    final rejection = _validateExecution(peerId, command);
    if (rejection != null) return _receipt(peerId, command, rejection.$1, code: rejection.$2);
    _renewLease();
    final peerToken = _peerTokens[peerId] ?? 0;
    final globalToken = _globalToken;
    final controlGeneration = _controlGeneration;
    var playbackGeneration = _playbackGeneration;
    final cancellation = Completer<void>();
    _activePeerId = peerId;
    _activeCancellation = cancellation;
    final executionBudget = _executionBudget(command.type);
    final executionDeadlineMs = _nowMs() + executionBudget.inMilliseconds;
    var executionTimedOut = false;
    final executionTimer = Timer(executionBudget, () {
      executionTimedOut = true;
      if (!cancellation.isCompleted) cancellation.complete();
    });
    var currentGlobalToken = globalToken;
    bool isCurrent() =>
        !_closed &&
        _controlOwnerId == peerId &&
        _controlGeneration == controlGeneration &&
        _playbackGeneration == playbackGeneration &&
        !executionTimedOut &&
        _nowMs() <= executionDeadlineMs &&
        _nowMs() < _leaseExpiresAtMs &&
        (_peerTokens[peerId] ?? 0) == peerToken &&
        _globalToken == currentGlobalToken;
    final context = CompanionExecutionContext._(
      isCurrent,
      (phase, details) => _emit(_receipt(peerId, command, phase, details: details)),
      () {
        playbackGeneration = _commitPlaybackChange();
        currentGlobalToken = _globalToken;
      },
      peerId,
    );
    try {
      _emit(_receipt(peerId, command, CompanionCommandPhase.preparing));
      context.ensureCurrent();
      final result = await Future.any<CompanionReceipt>(<Future<CompanionReceipt>>[
        _handler(peerId, command, context),
        cancellation.future.then(
          (_) => executionTimedOut
              ? _receipt(peerId, command, CompanionCommandPhase.expired, code: 'execution_timeout')
              : _receipt(peerId, command, CompanionCommandPhase.cancelled, code: 'execution_invalidated'),
        ),
      ]);
      if (result.phase == CompanionCommandPhase.expired && result.code == 'execution_timeout') return result;
      if (result.phase == CompanionCommandPhase.cancelled && result.code == 'execution_invalidated') {
        return result;
      }
      if (_nowMs() > executionDeadlineMs) {
        return _receipt(peerId, command, CompanionCommandPhase.expired, code: 'execution_timeout');
      }
      if (!isCurrent()) return _receipt(peerId, command, CompanionCommandPhase.cancelled, code: 'execution_invalidated');
      _renewLease();
      if (result.commandId != command.id || result.peerId != peerId || !result.isTerminal) {
        return _receipt(peerId, command, CompanionCommandPhase.failed, code: 'invalid_handler_receipt');
      }
      return result;
    } on CompanionCommandCancelledException {
      if (_nowMs() > executionDeadlineMs) {
        return _receipt(peerId, command, CompanionCommandPhase.expired, code: 'execution_timeout');
      }
      return _receipt(peerId, command, CompanionCommandPhase.cancelled, code: 'execution_invalidated');
    } catch (_) {
      return _receipt(peerId, command, CompanionCommandPhase.failed, code: 'handler_failed');
    } finally {
      executionTimer.cancel();
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
        _activePeerId = null;
      }
    }
  }

  (CompanionCommandPhase, String)? _validateExecution(String peerId, CompanionCommand command) {
    _expireLeaseIfNeeded();
    if (command.deadlineMs < _nowMs()) return (CompanionCommandPhase.expired, 'deadline_expired');
    if (_controlOwnerId != peerId) return (CompanionCommandPhase.failed, 'control_required');
    if (command.controlGeneration != _controlGeneration) {
      return (CompanionCommandPhase.failed, 'stale_control_generation');
    }
    if (command.playbackGeneration != _playbackGeneration) {
      return (CompanionCommandPhase.failed, 'stale_playback_generation');
    }
    return null;
  }

  void _expireLeaseIfNeeded() {
    if (_controlOwnerId != null && _nowMs() >= _leaseExpiresAtMs) {
      _controlOwnerId = null;
      _controlGeneration++;
      _leaseExpiresAtMs = 0;
      _invalidateAll();
    }
  }

  void _renewLease() => _leaseExpiresAtMs = _nowMs() + leaseDuration.inMilliseconds;

  void _invalidateAll() {
    _globalToken++;
    _cancelActive();
    for (final peer in _peerTokens.keys.toList()) {
      _peerTokens[peer] = (_peerTokens[peer] ?? 0) + 1;
    }
    _cancelQueued((_) => true, 'execution_invalidated');
  }

  void _cancelActive() {
    final cancellation = _activeCancellation;
    if (cancellation != null && !cancellation.isCompleted) cancellation.complete();
  }

  void _cancelQueued(bool Function(_QueuedCommand) predicate, String code) {
    final cancelled = _queue.where(predicate).toList();
    _queue.removeWhere(predicate);
    for (final item in cancelled) {
      if (!item.completer.isCompleted) {
        final receipt = _receipt(item.peerId, item.command, CompanionCommandPhase.cancelled, code: code);
        _emit(receipt);
        item.completer.complete(receipt);
      }
    }
  }

  void _remember(String key, String fingerprint, Future<CompanionReceipt> future) {
    final completer = Completer<CompanionReceipt>();
    final record = _CommandRecord(fingerprint, _nowMs(), completer);
    _records[key] = record;
    future.then((receipt) {
      record.latestReceipt = receipt;
      if (!completer.isCompleted) completer.complete(receipt);
    });
  }

  void _pruneRecords() {
    final threshold = _nowMs() - cacheTtl.inMilliseconds;
    _records.removeWhere((_, record) => record.createdAtMs < threshold && record.completer.isCompleted);
    if (_records.length > maxCacheEntries) {
      final completed = _records.entries.where((entry) => entry.value.completer.isCompleted).toList()
        ..sort((a, b) => a.value.createdAtMs.compareTo(b.value.createdAtMs));
      for (final entry in completed.take(_records.length - maxCacheEntries)) {
        _records.remove(entry.key);
      }
    }
  }

  CompanionReceipt _receipt(
    String peerId,
    CompanionCommand command,
    CompanionCommandPhase phase, {
    String? code,
    Map<String, Object?> details = const {},
  }) => CompanionReceipt(peerId: peerId, commandId: command.id, phase: phase, code: code, details: details);

  void _emit(CompanionReceipt receipt, {bool record = true}) {
    if (!_closed && !_receipts.isClosed) {
      if (record) {
        _records[_recordKey(receipt.peerId, receipt.commandId)]?.latestReceipt = receipt;
      }
      _receipts.add(receipt);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Companion command engine is closed');
  }

  static final Stopwatch _monotonicClock = Stopwatch()..start();
  static int _defaultMonotonicMs() => _monotonicClock.elapsedMilliseconds;

  static String _recordKey(String peerId, String id) => '$peerId\u0000$id';
}

extension on CompanionCommandPhase {
  bool get isProgress => switch (this) {
    CompanionCommandPhase.preparing || CompanionCommandPhase.resolving || CompanionCommandPhase.buffering => true,
    _ => false,
  };
}

extension<T> on Iterable<T> {
  T? lastWhereOrNull(bool Function(T) predicate) {
    for (final value in toList().reversed) {
      if (predicate(value)) return value;
    }
    return null;
  }
}

final class _CommandRecord {
  _CommandRecord(this.fingerprint, this.createdAtMs, this.completer);

  final String fingerprint;
  final int createdAtMs;
  final Completer<CompanionReceipt> completer;
  CompanionReceipt? latestReceipt;
}

final class _QueuedCommand {
  _QueuedCommand(this.peerId, this.command, this.completer);

  final String peerId;
  final CompanionCommand command;
  final Completer<CompanionReceipt> completer;
}
