import 'diagnostic_event.dart';
import 'diagnostic_value.dart';

/// Creates human-readable developer-console output from safe events.
///
/// The persisted TXT envelope remains the complete structured diagnostic
/// record. The console intentionally shows only user-flow milestones and all
/// warnings/errors, so it remains useful while a feature is running. ANSI
/// styling is applied only by [formatForConsole]; [format] stays plain text for
/// storage, copying, and tests that inspect diagnostic content. Error events
/// retain their complete explicit error text and stack trace for debugging.
final class DiagnosticConsoleFormatter {
  const DiagnosticConsoleFormatter();

  static const String _ansiReset = '\x1B[0m';

  static const Set<String> _summaryTerminalComponents = <String>{'app.bootstrap', 'feature.library', 'feature.reader', 'feature.plugins'};

  bool shouldMirror(DiagnosticEvent event) {
    if (event.severity.index >= DiagnosticSeverity.warn.index) return true;
    if (event.eventName == 'app.route.changed') {
      return true;
    }
    if (event.phase == DiagnosticPhase.start && event.parentSpanId == null && _summaryTerminalComponents.contains(event.component)) {
      return true;
    }
    return event.phase == DiagnosticPhase.terminal && _summaryTerminalComponents.contains(event.component);
  }

  String format(DiagnosticEvent event) {
    final fields = <String>['[MgRead][${_time(event.occurredAtUtcMicros)}][${_level(event)}]', event.eventName];
    if (event.durationMicros case final duration?) {
      fields.add('duration=${_duration(duration)}');
    }
    final fullError = event.severity.index >= DiagnosticSeverity.error.index;
    final attributes = _orderedAttributes(event.attributes);
    for (final entry in fullError ? attributes : attributes.take(8)) {
      fields.add('${_label(entry.key)}=${_value(entry.value, key: entry.key, preserveText: fullError)}');
    }
    return fields.join(' ');
  }

  /// Formats a mirrored developer-console line with a status-specific color.
  String formatForConsole(DiagnosticEvent event) {
    final color = _ansiColor(event);
    return '$color${format(event)}$_ansiReset';
  }

  Iterable<MapEntry<String, DiagnosticValue>> _orderedAttributes(DiagnosticObjectValue attributes) sync* {
    const preferred = <String>[
      'stage',
      'operation',
      'capability',
      'toRoute',
      'resultState',
      'errorCode',
      'subjectComponent',
      'outcome',
      'itemCount',
      'resultCount',
      'count',
      'bytes',
      'rawBytes',
      'storedBytes',
      'thresholdMicros',
    ];
    final values = attributes.values;
    final emitted = <String>{};
    for (final key in preferred) {
      final value = values[key];
      if (value == null) continue;
      emitted.add(key);
      yield MapEntry<String, DiagnosticValue>(key, value);
    }
    for (final entry in values.entries) {
      if (!emitted.contains(entry.key)) yield entry;
    }
  }

  String _level(DiagnosticEvent event) {
    if (event.phase == DiagnosticPhase.start) return 'START';
    if (event.outcome case final outcome?) {
      return switch (outcome) {
        DiagnosticOutcome.success => 'OK',
        DiagnosticOutcome.cancelled => 'CANCELLED',
        DiagnosticOutcome.timeout => 'TIMEOUT',
        DiagnosticOutcome.overloaded => 'OVERLOADED',
        DiagnosticOutcome.incomplete => 'INCOMPLETE',
        DiagnosticOutcome.error => 'ERROR',
      };
    }
    return event.severity.name.toUpperCase();
  }

  String _ansiColor(DiagnosticEvent event) {
    if (event.phase == DiagnosticPhase.start) return '\x1B[96m';
    if (event.outcome case final outcome?) {
      return switch (outcome) {
        DiagnosticOutcome.success => '\x1B[92m',
        DiagnosticOutcome.timeout || DiagnosticOutcome.overloaded => '\x1B[93m',
        DiagnosticOutcome.error => '\x1B[91m',
        DiagnosticOutcome.cancelled || DiagnosticOutcome.incomplete => '\x1B[95m',
      };
    }
    return switch (event.severity) {
      DiagnosticSeverity.trace || DiagnosticSeverity.debug => '\x1B[90m',
      DiagnosticSeverity.info => '\x1B[94m',
      DiagnosticSeverity.warn => '\x1B[93m',
      DiagnosticSeverity.error || DiagnosticSeverity.fatal => '\x1B[91m',
    };
  }

  String _time(int utcMicros) {
    final value = DateTime.fromMicrosecondsSinceEpoch(utcMicros, isUtc: true).toLocal();
    return '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}.'
        '${value.millisecond.toString().padLeft(3, '0')}';
  }

  String _value(DiagnosticValue value, {required String key, required bool preserveText}) => switch (value) {
    DiagnosticNullValue() => 'null',
    DiagnosticBoolValue(:final value) => '$value',
    DiagnosticStringValue(:final value) => preserveText ? value : _shortText(value),
    DiagnosticInt64Value(:final decimal) when key.endsWith('Micros') => _duration(int.parse(decimal)),
    DiagnosticInt64Value(:final decimal) when key.toLowerCase().contains('bytes') => _bytes(int.parse(decimal)),
    DiagnosticInt64Value(:final decimal) => decimal,
    DiagnosticDoubleValue(:final value) => value.toStringAsFixed(3),
    DiagnosticTruncatedValue() => '<truncated>',
    DiagnosticAttachmentReferenceValue() => '<attachment>',
    DiagnosticListValue() => '[…]',
    DiagnosticObjectValue() => '{…}',
  };

  String _shortText(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), ' ');
    if (compact.length <= 80) return compact;
    return '${compact.substring(0, 79)}…';
  }

  String _duration(int micros) {
    if (micros >= 1000000) return '${(micros / 1000000).toStringAsFixed(3)}s';
    if (micros >= 1000) return '${(micros / 1000).toStringAsFixed(1)}ms';
    return '$microsµs';
  }

  String _bytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KiB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MiB';
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  String _label(String key) => switch (key) {
    'durationMicros' => 'duration',
    'thresholdMicros' => 'threshold',
    'subjectComponent' => 'component',
    _ => key,
  };
}
