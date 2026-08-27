/// Bounded startup diagnostics proxy.
///
/// This sink lets a composition root create its [DiagnosticsManager] before
/// persistent storage is ready. It only buffers metadata events, and switches
/// to the real sink once [attach] is called. All operations are best effort;
/// diagnostics must never become a startup or shutdown dependency.
library;

import 'dart:collection';
import 'dart:convert';

import 'diagnostic_event.dart';
import 'diagnostics_manager.dart';

final class DeferredDiagnosticEventSink implements DiagnosticEventSink {
  DeferredDiagnosticEventSink({
    this.minimumSeverity = DiagnosticSeverity.debug,
    this.maxEvents = 128,
    this.maxBytes = 64 * 1024,
    Set<String> traceComponents = const <String>{},
  }) : traceComponents = Set<String>.unmodifiable(traceComponents) {
    if (maxEvents <= 0 || maxBytes <= 0) {
      throw ArgumentError('Deferred diagnostics bounds must be positive.');
    }
  }

  final DiagnosticSeverity minimumSeverity;
  final int maxEvents;
  final int maxBytes;
  final Set<String> traceComponents;
  DiagnosticEventSink? _fallbackSink;
  final ListQueue<_DeferredDiagnosticEvent> _events = ListQueue<_DeferredDiagnosticEvent>();
  DiagnosticEventSink? _attachedSink;
  Future<void>? _attachFuture;
  Future<void>? _closeFuture;
  var _bufferedBytes = 0;
  var _droppedEvents = 0;
  var _enabled = true;
  var _closing = false;
  var _closed = false;
  bool _attachAttempted = false;

  /// Number of events still waiting for a real sink.
  int get bufferedEventCount => _events.length;

  /// Estimated encoded bytes still waiting for a real sink.
  int get bufferedBytes => _bufferedBytes;

  /// Number of events rejected by the bounded startup buffer.
  int get droppedEvents => _droppedEvents;

  bool get isAttached => _attachedSink != null;
  bool get isDisabled => !_enabled;
  bool get isClosed => _closed;

  @override
  bool isEnabled({required String component, required DiagnosticSeverity severity, required DiagnosticPayloadKind payloadKind}) {
    if (_closing || _closed || !_enabled) {
      final fallback = _fallbackSink;
      if (fallback == null || _closing || _closed) return false;
      try {
        return fallback.isEnabled(component: component, severity: severity, payloadKind: payloadKind);
      } catch (_) {
        return false;
      }
    }
    final sink = _attachedSink;
    if (sink != null) {
      try {
        return sink.isEnabled(component: component, severity: severity, payloadKind: payloadKind);
      } catch (_) {
        return false;
      }
    }
    if (payloadKind != DiagnosticPayloadKind.metadataOnly) return false;
    if (severity == DiagnosticSeverity.trace && !traceComponents.contains(component)) {
      return false;
    }
    return severity.index >= minimumSeverity.index;
  }

  @override
  bool add(DiagnosticEvent event) {
    if (_closing || _closed) return false;
    if (!_enabled) return _forwardToFallback(event);
    final sink = _attachedSink;
    if (sink != null) return _forward(sink, event);

    // Direct callers may bypass isEnabled; keep the startup buffer's contract
    // identical in that case as well.
    if (event.severity.index < minimumSeverity.index ||
        (event.severity == DiagnosticSeverity.trace && !traceComponents.contains(event.component))) {
      return false;
    }

    final estimatedBytes = _estimateBytes(event);
    if (_events.length >= maxEvents || estimatedBytes > maxBytes || _bufferedBytes + estimatedBytes > maxBytes) {
      _droppedEvents += 1;
      return false;
    }
    _events.addLast(_DeferredDiagnosticEvent(event, estimatedBytes));
    _bufferedBytes += estimatedBytes;
    return true;
  }

  /// Attach one real sink and drain the accepted startup events in order.
  ///
  /// A second call with the same sink is idempotent. A different sink is
  /// rejected so one event stream cannot accidentally split across runs.
  Future<void> attach(DiagnosticEventSink sink) {
    if (_attachedSink != null) {
      if (!identical(_attachedSink, sink)) {
        return Future<void>.error(StateError('Deferred diagnostics sink is already attached.'));
      }
      return _attachFuture ?? Future<void>.value();
    }
    if (_attachAttempted) {
      return Future<void>.error(StateError('Deferred diagnostics sink attachment was already attempted.'));
    }
    if (_closed || _closing || !_enabled) return Future<void>.value();
    _attachAttempted = true;
    _attachedSink = sink;
    return _attachFuture = _drainToAttachedSink(sink);
  }

  /// Stop accepting startup events and optionally route subsequent events to a
  /// best-effort fallback sink. Buffered events are drained to that fallback.
  Future<void> disable({DiagnosticEventSink? fallbackSink}) async {
    if (_closed) return;
    _enabled = false;
    if (fallbackSink != null) _fallbackSink = fallbackSink;
    final fallback = _fallbackSink;
    if (fallback != null && _attachedSink == null) {
      _drainTo(fallback);
      try {
        await fallback.flush(timeout: const Duration(milliseconds: 250));
      } catch (_) {}
    } else {
      _events.clear();
      _bufferedBytes = 0;
    }
  }

  @override
  Future<void> flush({required Duration timeout}) async {
    final attachFuture = _attachFuture;
    if (attachFuture != null) {
      try {
        await attachFuture;
      } catch (_) {}
    }
    final sink = _attachedSink ?? (!_enabled ? _fallbackSink : null);
    if (sink == null) return;
    try {
      await sink.flush(timeout: timeout);
    } catch (_) {}
  }

  @override
  Future<void> close({required Duration timeout}) => _closeFuture ??= _close(timeout);

  Future<void> _close(Duration timeout) async {
    _closing = true;
    final attachFuture = _attachFuture;
    if (attachFuture != null) {
      try {
        await attachFuture;
      } catch (_) {}
    }
    final sink = _attachedSink ?? (!_enabled ? _fallbackSink : null);
    if (sink == null) {
      _events.clear();
      _bufferedBytes = 0;
      _closed = true;
      return;
    }
    try {
      await sink.close(timeout: timeout);
    } catch (_) {}
    _events.clear();
    _bufferedBytes = 0;
    _closed = true;
  }

  Future<void> _drainToAttachedSink(DiagnosticEventSink sink) async {
    _drainTo(sink);
    try {
      await sink.flush(timeout: const Duration(seconds: 2));
    } catch (_) {}
  }

  void _drainTo(DiagnosticEventSink sink) {
    while (_events.isNotEmpty) {
      final queued = _events.removeFirst();
      _bufferedBytes -= queued.estimatedBytes;
      _forward(sink, queued.event);
    }
  }

  bool _forwardToFallback(DiagnosticEvent event) {
    final fallback = _fallbackSink;
    return fallback == null ? false : _forward(fallback, event);
  }

  bool _forward(DiagnosticEventSink sink, DiagnosticEvent event) {
    try {
      return sink.add(event);
    } catch (_) {
      return false;
    }
  }

  int _estimateBytes(DiagnosticEvent event) {
    try {
      return utf8.encode(jsonEncode(const DiagnosticEventCodec().encode(event))).length;
    } catch (_) {
      // Event envelopes have already passed manager validation. This fallback
      // keeps a malformed future extension from breaking startup admission.
      return 512 + event.summary.length * 2 + event.attributes.encodedByteLength;
    }
  }
}

final class _DeferredDiagnosticEvent {
  const _DeferredDiagnosticEvent(this.event, this.estimatedBytes);

  final DiagnosticEvent event;
  final int estimatedBytes;
}
