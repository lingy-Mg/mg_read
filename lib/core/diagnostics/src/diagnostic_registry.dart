/// 应用诊断事件注册表。
///
/// 职责：
/// - 为跨功能诊断提供版本化且有界的事件 schema。
/// - 拒绝未注册事件和未声明字段。
///
/// 注意：
/// - 字段值按调用方提供的内容原样编码，不做检测或改写。
/// - 事件名与字段语义变更必须版本化。
///
library;

import 'dart:collection';

import 'diagnostic_event.dart';
import 'diagnostic_value.dart';

enum DiagnosticDefinitionKind { instant, span }

enum DiagnosticFieldType { boolean, string, int64, finiteDouble, number, list, object, attachmentReference, any }

final class DiagnosticFieldDefinition {
  const DiagnosticFieldDefinition({required this.type, this.requiredFor = const <DiagnosticPhase>{}, this.allowNull = false});

  final DiagnosticFieldType type;
  final Set<DiagnosticPhase> requiredFor;
  final bool allowNull;

  bool accepts(DiagnosticValue value) {
    if (value is DiagnosticTruncatedValue) {
      return true;
    }
    if (allowNull && value is DiagnosticNullValue) return true;
    return switch (type) {
      DiagnosticFieldType.boolean => value is DiagnosticBoolValue,
      DiagnosticFieldType.string => value is DiagnosticStringValue,
      DiagnosticFieldType.int64 => value is DiagnosticInt64Value,
      DiagnosticFieldType.finiteDouble => value is DiagnosticDoubleValue,
      DiagnosticFieldType.number => value is DiagnosticInt64Value || value is DiagnosticDoubleValue,
      DiagnosticFieldType.list => value is DiagnosticListValue,
      DiagnosticFieldType.object => value is DiagnosticObjectValue,
      DiagnosticFieldType.attachmentReference => value is DiagnosticAttachmentReferenceValue,
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
    Map<String, DiagnosticFieldDefinition> fields = const <String, DiagnosticFieldDefinition>{},
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
      throw ArgumentError('Schema version and attribute budget must be positive.');
    }
    if (kind == DiagnosticDefinitionKind.instant && allowedOutcomes.isNotEmpty) {
      throw ArgumentError('Instant events cannot define terminal outcomes.');
    }
    if (kind == DiagnosticDefinitionKind.span && allowedOutcomes.isEmpty) {
      throw ArgumentError('Span definitions need at least one terminal outcome.');
    }
    for (final entry in fields.entries) {
      validateDiagnosticFieldName(entry.key, 'field');
      if (kind == DiagnosticDefinitionKind.instant && entry.value.requiredFor.any((phase) => phase != DiagnosticPhase.instant)) {
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
    Map<String, DiagnosticFieldDefinition> fields = const <String, DiagnosticFieldDefinition>{},
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
    Map<String, DiagnosticFieldDefinition> fields = const <String, DiagnosticFieldDefinition>{},
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
    if (phase == DiagnosticPhase.terminal && outcome != null && allowedOutcomes.contains(outcome)) {
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
      DiagnosticOutcome.timeout || DiagnosticOutcome.overloaded || DiagnosticOutcome.incomplete => DiagnosticSeverity.warn,
      _ => defaultSeverity,
    };
  }

  void validateAttributes(DiagnosticObjectValue attributes, DiagnosticPhase phase) {
    if (attributes.encodedByteLength > maxAttributeBytes) {
      throw DiagnosticSchemaError('$name attributes exceed $maxAttributeBytes bytes.');
    }
    for (final entry in attributes.values.entries) {
      final field = fields[entry.key];
      if (field == null) {
        throw DiagnosticSchemaError('$name has no field named ${entry.key}.');
      }
      if (!field.accepts(entry.value)) {
        throw DiagnosticSchemaError('$name field ${entry.key} has an invalid diagnostic type.');
      }
    }
    for (final entry in fields.entries) {
      if (entry.value.requiredFor.contains(phase) && !attributes.values.containsKey(entry.key)) {
        throw DiagnosticSchemaError('$name requires ${entry.key} during ${phase.name}.');
      }
    }
  }
}

/// Immutable registry; an emitted event can never be invented ad hoc.
final class DiagnosticEventRegistry {
  factory DiagnosticEventRegistry(Iterable<DiagnosticEventDefinition> definitions) {
    final list = List<DiagnosticEventDefinition>.unmodifiable(definitions);
    return DiagnosticEventRegistry._(list);
  }

  DiagnosticEventRegistry._(List<DiagnosticEventDefinition> definitions)
    : _byBaseName = UnmodifiableMapView<String, DiagnosticEventDefinition>(<String, DiagnosticEventDefinition>{
        for (final definition in definitions) definition.name: definition,
      }),
      _byEmittedName = _indexEmittedNames(definitions) {
    if (_byBaseName.length != definitions.length) {
      throw const DiagnosticSchemaError('Duplicate diagnostic base name.');
    }
  }

  final Map<String, DiagnosticEventDefinition> _byBaseName;
  final Map<String, DiagnosticEventDefinition> _byEmittedName;

  Iterable<DiagnosticEventDefinition> get definitions => _byBaseName.values;

  DiagnosticEventDefinition requireDefinition(DiagnosticEventDefinition definition) {
    final registered = _byBaseName[definition.name];
    if (registered == null ||
        registered.schemaVersion != definition.schemaVersion ||
        registered.component != definition.component ||
        registered.kind != definition.kind) {
      throw DiagnosticSchemaError('${definition.name}@${definition.schemaVersion} is not registered.');
    }
    return registered;
  }

  DiagnosticEventDefinition? definitionForEventName(String eventName) => _byEmittedName[eventName];

  static Map<String, DiagnosticEventDefinition> _indexEmittedNames(Iterable<DiagnosticEventDefinition> definitions) {
    final result = <String, DiagnosticEventDefinition>{};
    for (final definition in definitions) {
      for (final emittedName in definition.emittedNames) {
        if (result.containsKey(emittedName)) {
          throw DiagnosticSchemaError('Duplicate emitted diagnostic name: $emittedName.');
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
  static final DiagnosticEventDefinition diagnosticsRun = DiagnosticEventDefinition.span(
    name: 'diagnostics.run',
    component: 'app.diagnostics',
    summary: 'Application diagnostics lifecycle.',
    fields: <String, DiagnosticFieldDefinition>{'buildMode': _string, 'platform': _string, 'errorCode': _string},
  );

  static final DiagnosticEventDefinition bootstrap = DiagnosticEventDefinition.span(
    name: 'app.bootstrap',
    component: 'app.bootstrap',
    summary: 'Application bootstrap lifecycle.',
    fields: <String, DiagnosticFieldDefinition>{'stage': _string, 'errorCode': _string},
  );

  static final DiagnosticEventDefinition startupStage = DiagnosticEventDefinition.instant(
    name: 'app.startup.stage',
    component: 'app.bootstrap',
    summary: 'A bounded application startup stage marker.',
    fields: <String, DiagnosticFieldDefinition>{
      'stage': _requiredInstantString,
      'durationMicros': _requiredInstantInt64,
      'resultState': _requiredInstantString,
      'errorCode': _string,
      'attempt': _requiredInstantInt64,
    },
  );

  static final DiagnosticEventDefinition lifecycleChanged = DiagnosticEventDefinition.instant(
    name: 'app.lifecycle.changed',
    component: 'app.lifecycle',
    summary: 'Application lifecycle changed.',
    fields: <String, DiagnosticFieldDefinition>{'fromState': _nullableString, 'toState': _requiredInstantString},
  );

  static final DiagnosticEventDefinition routeChanged = DiagnosticEventDefinition.instant(
    name: 'app.route.changed',
    component: 'app.router',
    summary: 'Application route changed.',
    fields: <String, DiagnosticFieldDefinition>{'fromRoute': _nullableString, 'toRoute': _requiredInstantString, 'navigationType': _string},
  );

  static final DiagnosticEventDefinition unhandledError = DiagnosticEventDefinition.instant(
    name: 'app.error.unhandled',
    component: 'app.error',
    summary: 'An unhandled application error reached a guarded boundary.',
    severity: DiagnosticSeverity.error,
    fields: <String, DiagnosticFieldDefinition>{
      'boundary': _requiredInstantString,
      'errorCode': _requiredInstantString,
      'errorText': _string,
      'stackTrace': _string,
      'fatal': _boolean,
    },
  );

  static final DiagnosticEventDefinition settingsInitialize = DiagnosticEventDefinition.span(
    name: 'settings.initialize',
    component: 'app.settings',
    summary: 'Application settings initialization.',
    fields: <String, DiagnosticFieldDefinition>{'settingCount': _int64, 'errorCode': _string},
  );

  static final DiagnosticEventDefinition settingsWrite = DiagnosticEventDefinition.span(
    name: 'settings.write',
    component: 'app.settings',
    summary: 'Application setting write.',
    schemaVersion: 2,
    fields: <String, DiagnosticFieldDefinition>{
      'settingKey': _string,
      'documentCount': _int64,
      'attempt': _int64,
      'revision': _int64,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition settingsMutation = DiagnosticEventDefinition.span(
    name: 'settings.mutation',
    component: 'app.settings',
    summary: 'In-memory application setting mutation.',
    fields: <String, DiagnosticFieldDefinition>{
      'operation': _string,
      'keyCount': _int64,
      'documentCount': _int64,
      'source': _string,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition persistenceOpen = DiagnosticEventDefinition.span(
    name: 'persistence.open',
    component: 'app.persistence',
    summary: 'Application persistence open.',
    fields: <String, DiagnosticFieldDefinition>{'store': _string, 'schemaVersion': _int64, 'errorCode': _string},
  );

  static final DiagnosticEventDefinition persistenceOperation = DiagnosticEventDefinition.span(
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

  static final DiagnosticEventDefinition persistenceClose = DiagnosticEventDefinition.span(
    name: 'persistence.close',
    component: 'app.persistence',
    summary: 'Application persistence close.',
    fields: <String, DiagnosticFieldDefinition>{'store': _string, 'errorCode': _string},
  );

  static final DiagnosticEventDefinition libraryLoad = DiagnosticEventDefinition.span(
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

  static final DiagnosticEventDefinition discoveryNavigation = DiagnosticEventDefinition.span(
    name: 'discovery.navigation',
    component: 'feature.discovery',
    summary: 'Discovery internal page navigation and document load.',
    schemaVersion: 2,
    fields: <String, DiagnosticFieldDefinition>{
      'operation': _string,
      'capability': _string,
      'pluginId': _string,
      'requestGeneration': _int64,
      'navigationDepth': _int64,
      'itemCount': _int64,
      'resultState': _string,
      'errorCode': _string,
      'errorLocation': _string,
      'errorText': _string,
      'stackTrace': _string,
    },
    maxAttributeBytes: 64 * 1024,
  );

  static final DiagnosticEventDefinition libraryOperation = DiagnosticEventDefinition.span(
    name: 'library.operation',
    component: 'core.content-library',
    summary: 'Content library operation.',
    fields: <String, DiagnosticFieldDefinition>{
      'operation': _string,
      'contentKind': _string,
      'itemCount': _int64,
      'bytes': _int64,
      'resultState': _string,
      'errorCode': _string,
      'errorText': _string,
      'stackTrace': _string,
      'thresholdMicros': _int64,
    },
  );

  static final DiagnosticEventDefinition readerLaunch = DiagnosticEventDefinition.span(
    name: 'reader.launch',
    component: 'feature.reader',
    summary: 'Reader launch.',
    fields: <String, DiagnosticFieldDefinition>{
      'readerMode': _string,
      'sourceKind': _string,
      'pathCategory': _string,
      'cacheHit': _boolean,
      'windowClass': _string,
      'resultState': _string,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition readerLaunchStage = DiagnosticEventDefinition.span(
    name: 'reader.launch.stage',
    component: 'feature.reader',
    summary: 'Reader launch stage timing.',
    fields: <String, DiagnosticFieldDefinition>{
      'stage': _string,
      'pathCategory': _string,
      'cacheHit': _boolean,
      'itemCount': _int64,
      'durationMicros': _int64,
      'windowClass': _string,
      'resultState': _string,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition readerPrefetch = DiagnosticEventDefinition.span(
    name: 'reader.prefetch',
    component: 'feature.reader',
    summary: 'Background preparation after a source book enters the shelf.',
    fields: <String, DiagnosticFieldDefinition>{
      'contentKind': _string,
      'chapterCount': _int64,
      'cachedChapterCount': _int64,
      'resultState': _string,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition readerChapterPerformance = DiagnosticEventDefinition.span(
    name: 'reader.chapter.performance',
    component: 'feature.reader',
    summary: 'Adjacent chapter layout and transition performance.',
    fields: <String, DiagnosticFieldDefinition>{
      'phase': _string,
      'preparationKind': _string,
      'cacheHit': _boolean,
      'operationId': _int64,
      'pageCount': _int64,
      'paragraphCount': _int64,
      'durationMicros': _int64,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition runtimeFacadeCall = DiagnosticEventDefinition.span(
    name: 'runtime.facade.call',
    component: 'feature.plugins',
    summary: 'Versioned Runtime Facade capability call.',
    schemaVersion: 2,
    fields: <String, DiagnosticFieldDefinition>{
      'capability': _string,
      'pluginId': _string,
      'attempt': _int64,
      'pluginCount': _int64,
      'resultCount': _int64,
      'resultState': _string,
      'errorCode': _string,
      'errorLocation': _string,
      'errorText': _string,
      'stackTrace': _string,
    },
    maxAttributeBytes: 64 * 1024,
  );

  static final DiagnosticEventDefinition lanSyncSession = DiagnosticEventDefinition.span(
    name: 'lan.sync.session',
    component: 'feature.lan-sync',
    summary: 'Foreground local-network synchronization session.',
    fields: <String, DiagnosticFieldDefinition>{
      'role': _string,
      'stage': _string,
      'operation': _string,
      'automatic': _boolean,
      'peerPlatform': _string,
      'pluginCount': _int64,
      'itemCount': _int64,
      'skippedItemCount': _int64,
      'bytes': _int64,
      'resultState': _string,
      'errorCode': _string,
      'errorLocation': _string,
      'errorText': _string,
      'stackTrace': _string,
    },
    maxAttributeBytes: 64 * 1024,
  );

  static final DiagnosticEventDefinition lanSyncStage = DiagnosticEventDefinition.instant(
    name: 'lan.sync.stage',
    component: 'feature.lan-sync',
    summary: 'One bounded foreground local-network synchronization stage.',
    fields: <String, DiagnosticFieldDefinition>{'role': _string, 'stage': _requiredInstantString, 'bytes': _int64, 'elapsedMicros': _int64},
  );

  static final DiagnosticEventDefinition writerState = DiagnosticEventDefinition.instant(
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

  static final DiagnosticEventDefinition performanceSlow = DiagnosticEventDefinition.instant(
    name: 'performance.slow',
    component: 'app.performance',
    summary: 'An operation exceeded its configured performance baseline.',
    severity: DiagnosticSeverity.warn,
    fields: <String, DiagnosticFieldDefinition>{
      'subjectComponent': _requiredInstantString,
      'operation': _requiredInstantString,
      'durationMicros': _requiredInstantInt64,
      'thresholdMicros': _requiredInstantInt64,
      'outcome': _requiredInstantString,
      'buildMode': _requiredInstantString,
      'platform': _requiredInstantString,
    },
  );

  static final DiagnosticEventDefinition eventsDropped = DiagnosticEventDefinition.instant(
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

  static final DiagnosticEventDefinition retention = DiagnosticEventDefinition.span(
    name: 'diagnostics.retention',
    component: 'app.diagnostics',
    summary: 'Diagnostics retention maintenance.',
    severity: DiagnosticSeverity.debug,
    fields: <String, DiagnosticFieldDefinition>{
      'sessionCount': _int64,
      'eventCount': _int64,
      'reclaimedBytes': _int64,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition capture = DiagnosticEventDefinition.span(
    name: 'diagnostics.capture',
    component: 'app.diagnostics',
    summary: 'Explicit diagnostic capture session.',
    fields: <String, DiagnosticFieldDefinition>{
      'payloadKind': _string,
      'durationMicros': _int64,
      'maxBytes': _int64,
      'detailStorage': _string,
      'componentCount': _int64,
      'originCount': _int64,
      'sessionState': _string,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition attachment = DiagnosticEventDefinition.span(
    name: 'diagnostics.attachment',
    component: 'app.diagnostics',
    summary: 'Diagnostic attachment capture.',
    severity: DiagnosticSeverity.debug,
    fields: <String, DiagnosticFieldDefinition>{
      'kind': _string,
      'captureState': _string,
      'rawBytes': _int64,
      'storedBytes': _int64,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition viewerOperation = DiagnosticEventDefinition.span(
    name: 'diagnostics.viewer.operation',
    component: 'app.diagnostics',
    summary: 'Dedicated diagnostics viewer operation.',
    severity: DiagnosticSeverity.debug,
    fields: <String, DiagnosticFieldDefinition>{
      'operation': _string,
      'source': _string,
      'resultCount': _int64,
      'bytes': _int64,
      'resultState': _string,
      'errorCode': _string,
    },
  );

  static final DiagnosticEventDefinition export = DiagnosticEventDefinition.span(
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

  static final DiagnosticEventRegistry registry = DiagnosticEventRegistry(<DiagnosticEventDefinition>[
    diagnosticsRun,
    bootstrap,
    startupStage,
    lifecycleChanged,
    routeChanged,
    unhandledError,
    settingsInitialize,
    settingsMutation,
    settingsWrite,
    persistenceOpen,
    persistenceOperation,
    persistenceClose,
    libraryLoad,
    discoveryNavigation,
    libraryOperation,
    readerLaunch,
    readerLaunchStage,
    readerPrefetch,
    readerChapterPerformance,
    runtimeFacadeCall,
    lanSyncSession,
    lanSyncStage,
    performanceSlow,
    writerState,
    eventsDropped,
    retention,
    capture,
    attachment,
    viewerOperation,
    export,
  ]);

  static const DiagnosticFieldDefinition _string = DiagnosticFieldDefinition(type: DiagnosticFieldType.string);
  static const DiagnosticFieldDefinition _nullableString = DiagnosticFieldDefinition(type: DiagnosticFieldType.string, allowNull: true);
  static const DiagnosticFieldDefinition _requiredInstantString = DiagnosticFieldDefinition(
    type: DiagnosticFieldType.string,
    requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
  );
  static const DiagnosticFieldDefinition _boolean = DiagnosticFieldDefinition(type: DiagnosticFieldType.boolean);
  static const DiagnosticFieldDefinition _int64 = DiagnosticFieldDefinition(type: DiagnosticFieldType.int64);
  static const DiagnosticFieldDefinition _requiredInstantInt64 = DiagnosticFieldDefinition(
    type: DiagnosticFieldType.int64,
    requiredFor: <DiagnosticPhase>{DiagnosticPhase.instant},
  );
}
