/// Bounded process-local diagnostics used by the in-app debug viewer.
///
/// Responsibilities:
/// - Default to recent warnings/errors (200 events / 256 KiB); detailed
///   metadata is admitted only during an explicit recording session.
/// - Notify the visible viewer without adding disk I/O to business paths.
/// - Keep both event count and encoded bytes bounded.
///
/// Notes:
/// - This store never persists events or attachment payloads.
/// - Debug-only local viewing intentionally preserves projected field values;
///   production exports and external diagnostics keep their own policies.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'diagnostic_event.dart';
import 'diagnostics_manager.dart';

final class LiveDiagnosticsBuffer implements DiagnosticEventSink {
  LiveDiagnosticsBuffer({this.minimumSeverity = DiagnosticSeverity.warn, this.maxEvents = 200, this.maxBytes = 256 * 1024, this.onEvent})
    : startedAtUtcMicros = DateTime.now().toUtc().microsecondsSinceEpoch {
    if (maxEvents <= 0 || maxBytes <= 0) {
      throw ArgumentError('Live diagnostics bounds must be positive.');
    }
  }

  DiagnosticSeverity minimumSeverity;

  /// Detailed recording is session-only. Returning to normal drops ordinary
  /// events immediately so they cannot crowd out recent warnings and errors.
  void setDetailedRecording(bool enabled) {
    minimumSeverity = enabled ? DiagnosticSeverity.debug : DiagnosticSeverity.warn;
    if (!enabled) {
      _entries.removeWhere((entry) => entry.event.severity.index < DiagnosticSeverity.warn.index);
      _storedBytes = _entries.fold(0, (sum, entry) => sum + entry.encodedBytes);
    }
    if (!_closed) _changes.add(null);
  }

  final int maxEvents;
  final int maxBytes;
  final void Function(DiagnosticEvent event)? onEvent;
  final int startedAtUtcMicros;

  final ListQueue<_LiveDiagnosticEntry> _entries = ListQueue<_LiveDiagnosticEntry>();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  final DiagnosticEventCodec _codec = const DiagnosticEventCodec();
  var _storedBytes = 0;
  var _droppedEvents = 0;
  var _closed = false;

  Stream<void> get changes => _changes.stream;
  int get storedBytes => _storedBytes;
  int get droppedEvents => _droppedEvents;
  int get eventCount => _entries.length;

  int get modifiedAtUtcMicros => _entries.isEmpty ? startedAtUtcMicros : _entries.last.event.occurredAtUtcMicros;

  String get sourceRunId => _entries.isEmpty ? 'current' : _entries.last.event.sourceRunId;

  List<DiagnosticEvent> snapshot({int? beforeSourceSequence, int limit = 100}) {
    if (limit <= 0) throw ArgumentError.value(limit, 'limit');
    final events = <DiagnosticEvent>[];
    for (final entry in _entries.toList(growable: false).reversed) {
      final event = entry.event;
      if (beforeSourceSequence != null && event.sourceSequence >= beforeSourceSequence) continue;
      events.add(event);
      if (events.length >= limit) break;
    }
    return List<DiagnosticEvent>.unmodifiable(events);
  }

  DiagnosticEvent? findEvent(String eventId) {
    for (final entry in _entries) {
      if (entry.event.eventId == eventId) return entry.event;
    }
    return null;
  }

  @override
  bool isEnabled({required String component, required DiagnosticSeverity severity, required DiagnosticPayloadKind payloadKind}) {
    if (_closed || payloadKind != DiagnosticPayloadKind.metadataOnly) return false;
    return severity.index >= minimumSeverity.index;
  }

  @override
  bool add(DiagnosticEvent event) {
    if (_closed || event.severity.index < minimumSeverity.index) return false;
    final encodedBytes = utf8.encode(jsonEncode(_codec.encode(event))).length;
    if (encodedBytes > maxBytes) {
      _droppedEvents += 1;
      return false;
    }
    while (_entries.isNotEmpty && (_entries.length >= maxEvents || _storedBytes + encodedBytes > maxBytes)) {
      _storedBytes -= _entries.removeFirst().encodedBytes;
      _droppedEvents += 1;
    }
    _entries.addLast(_LiveDiagnosticEntry(event, encodedBytes));
    _storedBytes += encodedBytes;
    try {
      onEvent?.call(event);
    } on Object {
      // A developer console mirror must not change event admission.
    }
    if (!_changes.isClosed) _changes.add(null);
    return true;
  }

  @override
  Future<void> flush({required Duration timeout}) async {}

  @override
  Future<void> close({required Duration timeout}) async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
    _entries.clear();
    _storedBytes = 0;
  }
}

final class _LiveDiagnosticEntry {
  const _LiveDiagnosticEntry(this.event, this.encodedBytes);

  final DiagnosticEvent event;
  final int encodedBytes;
}
