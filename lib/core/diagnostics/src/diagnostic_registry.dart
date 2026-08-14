import 'dart:collection';

import 'diagnostic_event.dart';
import 'diagnostic_value.dart';

enum DiagnosticDefinitionKind { instant, span }

enum DiagnosticFieldType {
  boolean,
  string,
  int64,
  finiteDouble,
  number,
  list,
  object,
  attachmentReference,
  any,
}

final class DiagnosticFieldDefinition {
  const DiagnosticFieldDefinition({
    required this.type,
    this.privacyClass = DiagnosticPrivacyClass.internal,
    this.requiredFor = const <DiagnosticPhase>{},
    this.allowNull = false,
  });

  final DiagnosticFieldType type;
  final DiagnosticPrivacyClass privacyClass;
  final Set<DiagnosticPhase> requiredFor;
  final bool allowNull;

  bool accepts(DiagnosticValue value) {
    if (value is DiagnosticRedactedValue || value is DiagnosticTruncatedValue) {
      return true;
    }
    if (allowNull && value is DiagnosticNullValue) return true;
    return switch (type) {
      DiagnosticFieldType.boolean => value is DiagnosticBoolValue,
      DiagnosticFieldType.string => value is DiagnosticStringValue,
      DiagnosticFieldType.int64 => value is DiagnosticInt64Value,
      DiagnosticFieldType.finiteDouble => value is DiagnosticDoubleValue,
      DiagnosticFieldType.number =>
        value is DiagnosticInt64Value || value is DiagnosticDoubleValue,
      DiagnosticFieldType.list => value is DiagnosticListValue,
      DiagnosticFieldType.object => value is DiagnosticObjectValue,
      DiagnosticFieldType.attachmentReference =>
        value is DiagnosticAttachmentReferenceValue,
      DiagnosticFieldType.any => true,
    };
  }
}

/// A registered event or owner-span schema.
final class DiagnosticEventDefinition {
  DiagnosticEventDefinition({
    required this.name,
    required this.component,
    required this.summary,
    required this.kind,
    this.schemaVersion = 1,
    this.defaultSeverity = DiagnosticSeverity.info,
    Map<String, DiagnosticFieldDefinition> fields =
        const <String, DiagnosticFieldDefinition>{},
    Set<DiagnosticOutcome> allowedOutcomes = const <DiagnosticOutcome>{
      DiagnosticOutcome.success,
      DiagnosticOutcome.error,
      DiagnosticOutcome.cancelled,
      DiagnosticOutcome.timeout,
      DiagnosticOutcome.overloaded,
      DiagnosticOutcome.incomplete,
    },
    this.maxAttributeBytes = 16 * 1024,
  }) : fields = Map<String, DiagnosticFieldDefinition>.unmodifiable(fields),
       allowedOutcomes = Set<DiagnosticOutcome>.unmodifiable(allowedOutcomes) {
    validateDiagnosticName(name, 'name');
    validateDiagnosticName(component, 'component');
    if (summary.isEmpty || summary.length > 512 || summary.contains('\n')) {
      throw ArgumentError.value(summary, 'summary');
    }
    if (schemaVersion <= 0 || maxAttributeBytes <= 0) {
      throw ArgumentError(
        'Schema version and attribute budget must be positive.',
      );
    }
    if (kind == DiagnosticDefinitionKind.instant &&
        allowedOutcomes.isNotEmpty) {
      throw ArgumentError('Instant events cannot define terminal outcomes.');
    }
    if (kind == DiagnosticDefinitionKind.span && allowedOutcomes.isEmpty) {
      throw ArgumentError(
        'Span definitions need at least one terminal outcome.',
      );
    }
    for (final entry in fields.entries) {
      validateDiagnosticFieldName(entry.key, 'field');
      if (kind == DiagnosticDefinitionKind.instant &&
          entry.value.requiredFor.any(
            (phase) => phase != DiagnosticPhase.instant,
          )) {
        throw ArgumentError('Instant field ${entry.key} has a span phase.');
      }
    }
  }

  factory DiagnosticEventDefinition.instant({
    required String name,
    required String component,
    required String summary,
    int schemaVersion = 1,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    Map<String, DiagnosticFieldDefinition> fields =
        const <String, DiagnosticFieldDefinition>{},
    int maxAttributeBytes = 16 * 1024,
  }) => DiagnosticEventDefinition(
    name: name,
    component: component,
    summary: summary,
    kind: DiagnosticDefinitionKind.instant,
    schemaVersion: schemaVersion,
    defaultSeverity: severity,
    fields: fields,
    allowedOutcomes: const <DiagnosticOutcome>{},
    maxAttributeBytes: maxAttributeBytes,
  );

  factory DiagnosticEventDefinition.span({
    required String name,
    required String component,
    required String summary,
    int schemaVersion = 1,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    Map<String, DiagnosticFieldDefinition> fields =
        const <String, DiagnosticFieldDefinition>{},
    Set<DiagnosticOutcome> allowedOutcomes = const <DiagnosticOutcome>{
      DiagnosticOutcome.success,
      DiagnosticOutcome.error,
      DiagnosticOutcome.cancelled,
      DiagnosticOutcome.timeout,
      DiagnosticOutcome.overloaded,
      DiagnosticOutcome.incomplete,
    },
    int maxAttributeBytes = 16 * 1024,
  }) => DiagnosticEventDefinition(
    name: name,
    component: component,
    summary: summary,
    kind: DiagnosticDefinitionKind.span,
    schemaVersion: schemaVersion,
    defaultSeverity: severity,
    fields: fields,
    allowedOutcomes: allowedOutcomes,
    maxAttributeBytes: maxAttributeBytes,
  );

  final String name;
  final String component;
  final String summary;
  final DiagnosticDefinitionKind kind;
  final int schemaVersion;
  final DiagnosticSeverity defaultSeverity;
  final Map<String, DiagnosticFieldDefinition> fields;
  final Set<DiagnosticOutcome> allowedOutcomes;
  final int maxAttributeBytes;

  Iterable<String> get emittedNames sync* {
    if (kind == DiagnosticDefinitionKind.instant) {
      yield name;
      return;
    }
    yield '$name.start';
    for (final outcome in allowedOutcomes) {
      yield eventName(DiagnosticPhase.terminal, outcome: outcome);
    }
  }

  String eventName(DiagnosticPhase phase, {DiagnosticOutcome? outcome}) {
    if (kind == DiagnosticDefinitionKind.instant) {
      if (phase != DiagnosticPhase.instant || outcome != null) {
        throw StateError('$name is an instant event.');
      }
      return name;
    }
    if (phase == DiagnosticPhase.start && outcome == null) {
      return '$name.start';
    }
    if (phase == DiagnosticPhase.terminal &&
        outcome != null &&
        allowedOutcomes.contains(outcome)) {
      final suffix = switch (outcome) {
        DiagnosticOutcome.success => 'complete',
        DiagnosticOutcome.error => 'error',
        DiagnosticOutcome.cancelled => 'cancelled',
        DiagnosticOutcome.timeout => 'timeout',
        DiagnosticOutcome.overloaded => 'overloaded',
        DiagnosticOutcome.incomplete => 'incomplete',
      };
      return '$name.$suffix';
    }
    throw StateError('Invalid phase/outcome for $name.');
  }

  DiagnosticSeverity severityFor({DiagnosticOutcome? outcome}) {
    return switch (outcome) {
      DiagnosticOutcome.error => DiagnosticSeverity.error,
      DiagnosticOutcome.timeout ||
      DiagnosticOutcome.overloaded ||
      DiagnosticOutcome.incomplete => DiagnosticSeverity.warn,
      _ => defaultSeverity,
    };
  }

  void validateAttributes(
    DiagnosticObjectValue attributes,
    DiagnosticPhase phase,
  ) {
    if (attributes.encodedByteLength > maxAttributeBytes) {
      throw DiagnosticSchemaError(
        '$name attributes exceed $maxAttributeBytes bytes.',
      );
    }
    for (final entry in attributes.values.entries) {
      final field = fields[entry.key];
      if (field == null) {
        throw DiagnosticSchemaError('$name has no field named ${entry.key}.');
      }
      if (!field.accepts(entry.value)) {
        throw DiagnosticSchemaError(
          '$name field ${entry.key} has an invalid diagnostic type.',
        );
      }
    }
    for (final entry in fields.entries) {
      if (entry.value.requiredFor.contains(phase) &&
          !attributes.values.containsKey(entry.key)) {
        throw DiagnosticSchemaError(
          '$name requires ${entry.key} during ${phase.name}.',
        );
      }
    }
  }
}

/// Immutable registry; an emitted event can never be invented ad hoc.
final class DiagnosticEventRegistry {
  factory DiagnosticEventRegistry(
    Iterable<DiagnosticEventDefinition> definitions,
  ) {
    final list = List<DiagnosticEventDefinition>.unmodifiable(definitions);
    return DiagnosticEventRegistry._(list);
  }

  DiagnosticEventRegistry._(List<DiagnosticEventDefinition> definitions)
    : _byBaseName = UnmodifiableMapView<String, DiagnosticEventDefinition>(
        <String, DiagnosticEventDefinition>{
          for (final definition in definitions) definition.name: definition,
        },
      ),
      _byEmittedName = _indexEmittedNames(definitions) {
    if (_byBaseName.length != definitions.length) {
      throw const DiagnosticSchemaError('Duplicate diagnostic base name.');
    }
  }

  final Map<String, DiagnosticEventDefinition> _byBaseName;
  final Map<String, DiagnosticEventDefinition> _byEmittedName;

  Iterable<DiagnosticEventDefinition> get definitions => _byBaseName.values;

  DiagnosticEventDefinition requireDefinition(
    DiagnosticEventDefinition definition,
  ) {
    final registered = _byBaseName[definition.name];
    if (registered == null ||
        registered.schemaVersion != definition.schemaVersion ||
        registered.component != definition.component ||
        registered.kind != definition.kind) {
      throw DiagnosticSchemaError(
        '${definition.name}@${definition.schemaVersion} is not registered.',
      );
    }
    return registered;
  }

  DiagnosticEventDefinition? definitionForEventName(String eventName) =>
      _byEmittedName[eventName];

  static Map<String, DiagnosticEventDefinition> _indexEmittedNames(
    Iterable<DiagnosticEventDefinition> definitions,
  ) {
    final result = <String, DiagnosticEventDefinition>{};
    for (final definition in definitions) {
      for (final emittedName in definition.emittedNames) {
        if (result.containsKey(emittedName)) {
          throw DiagnosticSchemaError(
            'Duplicate emitted diagnostic name: $emittedName.',
          );
        }
        result[emittedName] = definition;
      }
    }
    return UnmodifiableMapView<String, DiagnosticEventDefinition>(result);
  }
}

final class DiagnosticSchemaError implements Exception {
  const DiagnosticSchemaError(this.message);

  final String message;

  @override
  String toString() => 'DiagnosticSchemaError: $message';
}

/// Registered app events used by existing application infrastructure.
abstract final class AppDiagnosticEvents {
  static final DiagnosticEventDefinition diagnosticsRun =
      DiagnosticEventDefinition.span(
        name: 'diagnostics.run',
        component: 'app.diagnostics',
        summary: 'Application diagnostics lifecycle.',
        fields: <String, DiagnosticFieldDefinition>{
          'buildMode': _string,
          'platform': _string,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition bootstrap =
      DiagnosticEventDefinition.span(
        name: 'app.bootstrap',
        component: 'app.bootstrap',
        summary: 'Application bootstrap lifecycle.',
        fields: <String, DiagnosticFieldDefinition>{
          'stage': _string,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition lifecycleChanged =
      DiagnosticEventDefinition.instant(
        name: 'app.lifecycle.changed',
        component: 'app.lifecycle',
        summary: 'Application lifecycle changed.',
        fields: <String, DiagnosticFieldDefinition>{
          'fromState': _nullableString,
          'toState': _requiredInstantString,
        },
      );

  static final DiagnosticEventDefinition routeChanged =
      DiagnosticEventDefinition.instant(
        name: 'app.route.changed',
        component: 'app.router',
        summary: 'Application route changed.',
        fields: <String, DiagnosticFieldDefinition>{
          'fromRoute': _nullableString,
          'toRoute': _requiredInstantString,
          'navigationType': _string,
        },
      );

  static final DiagnosticEventDefinition unhandledError =
      DiagnosticEventDefinition.instant(
        name: 'app.error.unhandled',
        component: 'app.error',
        summary: 'An unhandled application error reached a guarded boundary.',
        severity: DiagnosticSeverity.error,
        fields: <String, DiagnosticFieldDefinition>{
          'boundary': _requiredInstantString,
          'errorCode': _requiredInstantString,
          'stackFingerprint': _string,
          'fatal': _boolean,
        },
      );

  static final DiagnosticEventDefinition settingsInitialize =
      DiagnosticEventDefinition.span(
        name: 'settings.initialize',
        component: 'app.settings',
        summary: 'Application settings initialization.',
        fields: <String, DiagnosticFieldDefinition>{
          'settingCount': _int64,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition settingsWrite =
      DiagnosticEventDefinition.span(
        name: 'settings.write',
        component: 'app.settings',
        summary: 'Application setting write.',
        fields: <String, DiagnosticFieldDefinition>{
          'settingKey': _string,
          'revision': _int64,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition persistenceOpen =
      DiagnosticEventDefinition.span(
        name: 'persistence.open',
        component: 'app.persistence',
        summary: 'Application persistence open.',
        fields: <String, DiagnosticFieldDefinition>{
          'store': _string,
          'schemaVersion': _int64,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition persistenceOperation =
      DiagnosticEventDefinition.span(
        name: 'persistence.operation',
        component: 'app.persistence',
        summary: 'Application persistence operation.',
        severity: DiagnosticSeverity.debug,
        fields: <String, DiagnosticFieldDefinition>{
          'store': _string,
          'operation': _string,
          'recordKind': _string,
          'count': _int64,
          'bytes': _int64,
          'revision': _int64,
          'errorCode': _string,
          'thresholdMicros': _int64,
        },
      );

  static final DiagnosticEventDefinition persistenceClose =
      DiagnosticEventDefinition.span(
        name: 'persistence.close',
        component: 'app.persistence',
        summary: 'Application persistence close.',
        fields: <String, DiagnosticFieldDefinition>{
          'store': _string,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition libraryLoad =
      DiagnosticEventDefinition.span(
        name: 'library.load',
        component: 'feature.library',
        summary: 'Library overview load.',
        fields: <String, DiagnosticFieldDefinition>{
          'requestGeneration': _int64,
          'itemCount': _int64,
          'resultState': _string,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition readerLaunch =
      DiagnosticEventDefinition.span(
        name: 'reader.launch',
        component: 'feature.reader',
        summary: 'Reader launch.',
        fields: <String, DiagnosticFieldDefinition>{
          'readerMode': _string,
          'sourceKind': _string,
          'resultState': _string,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition writerState =
      DiagnosticEventDefinition.instant(
        name: 'diagnostics.writer.state',
        component: 'app.diagnostics',
        summary: 'Diagnostics writer state changed.',
        severity: DiagnosticSeverity.debug,
        fields: <String, DiagnosticFieldDefinition>{
          'state': _requiredInstantString,
          'queueDepth': _int64,
          'queueBytes': _int64,
          'batchSize': _int64,
          'commitMicros': _int64,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition eventsDropped =
      DiagnosticEventDefinition.instant(
        name: 'diagnostics.events.dropped',
        component: 'app.diagnostics',
        summary: 'Diagnostic events were dropped under pressure.',
        severity: DiagnosticSeverity.warn,
        fields: <String, DiagnosticFieldDefinition>{
          'reason': _requiredInstantString,
          'dropCount': _requiredInstantInt64,
          'windowMicros': _int64,
          'lowestSeverity': _string,
        },
      );

  static final DiagnosticEventDefinition retention =
      DiagnosticEventDefinition.span(
        name: 'diagnostics.retention',
        component: 'app.diagnostics',
        summary: 'Diagnostics retention maintenance.',
        severity: DiagnosticSeverity.debug,
        fields: <String, DiagnosticFieldDefinition>{
          'sessionCount': _int64,
          'eventCount': _int64,
          'objectBytes': _int64,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventDefinition export =
      DiagnosticEventDefinition.span(
        name: 'diagnostics.export',
        component: 'app.diagnostics',
        summary: 'Diagnostics export operation.',
        fields: <String, DiagnosticFieldDefinition>{
          'sessionCount': _int64,
          'eventCount': _int64,
          'attachmentCount': _int64,
          'bytes': _int64,
          'errorCode': _string,
        },
      );

  static final DiagnosticEventRegistry registry =
      DiagnosticEventRegistry(<DiagnosticEventDefinition>[
        diagnosticsRun,
        bootstrap,
        lifecycleChanged,
        routeChanged,
        unhandledError,
        settingsInitialize,
        settingsWrite,
        persistenceOpen,
        persistenceOperation,
        persistenceClose,
        libraryLoad,
        readerLaunch,
        writerState,
        eventsDropped,
        retention,
        export,
      ]);

  static const DiagnosticFieldDefinition _string = DiagnosticFieldDefinition(
    type: DiagnosticFieldType.string,
  );
  static const DiagnosticFieldDefinition _nullableString =
      DiagnosticFieldDefinition(
        type: DiagnosticFieldType.string,
        allowNull: true,
      );
  static const DiagnosticFieldDefinition _requiredInstantString =
      DiagnosticFieldDefinition(
        type: DiagnosticFieldType.string,
        requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
      );
  static const DiagnosticFieldDefinition _boolean = DiagnosticFieldDefinition(
    type: DiagnosticFieldType.boolean,
  );
  static const DiagnosticFieldDefinition _int64 = DiagnosticFieldDefinition(
    type: DiagnosticFieldType.int64,
  );
  static const DiagnosticFieldDefinition _requiredInstantInt64 =
      DiagnosticFieldDefinition(
        type: DiagnosticFieldType.int64,
        requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
      );
}
