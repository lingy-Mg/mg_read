import {
  type RuntimeDiagnosticEventDefinition,
  type RuntimeDiagnosticObjectValue,
  type RuntimeDiagnosticValue,
  validateRuntimeDiagnosticEventDefinition,
} from "./contracts.js";

type RuntimeDiagnosticFieldType = RuntimeDiagnosticValue["type"] | "any";

export interface RegisteredRuntimeDiagnosticEvent
  extends RuntimeDiagnosticEventDefinition {
  readonly fields: Readonly<Record<string, RuntimeDiagnosticFieldType>>;
}

function define(
  definition: RuntimeDiagnosticEventDefinition & {
    readonly fields?: Readonly<Record<string, RuntimeDiagnosticFieldType>>;
  },
): RegisteredRuntimeDiagnosticEvent {
  validateRuntimeDiagnosticEventDefinition(definition);
  return Object.freeze({ ...definition, fields: Object.freeze(definition.fields ?? {}) });
}

const commonPerformanceFields = Object.freeze({
  buildMode: "string",
  count: "int64",
  platform: "string",
  queueDepth: "int64",
  queueWaitMicros: "int64",
  thresholdMicros: "int64",
} satisfies Readonly<Record<string, RuntimeDiagnosticFieldType>>);

/**
 * Closed event registry for Runtime D3.
 *
 * Names, summaries and field sets are versioned here rather than assembled at
 * call sites. A future field or semantic change increments only that event's
 * schema version.
 */
export const runtimeDiagnosticEvents = Object.freeze({
  attachment: define({
    component: "runtime.diagnostics",
    defaultSeverity: "debug",
    eventName: "diagnostics.attachment",
    eventSchemaVersion: 1,
    fields: {
      captureState: "string",
      capturedBytes: "int64",
      kind: "string",
      privacyClass: "string",
      truncationReason: "string",
    },
    summary: "Runtime diagnostic attachment capture.",
  }),
  capture: define({
    component: "runtime.diagnostics",
    defaultSeverity: "info",
    eventName: "diagnostics.capture",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      maxStoredBytes: "int64",
      payloadKind: "string",
      sessionState: "string",
    },
    summary: "Runtime diagnostic capture session.",
  }),
  control: define({
    component: "runtime.control",
    defaultSeverity: "debug",
    eventName: "runtime.control",
    eventSchemaVersion: 1,
    fields: {
      attempt: "int64",
      errorCode: "string",
      method: "string",
      requestBytes: "int64",
      responseBytes: "int64",
      ...commonPerformanceFields,
    },
    summary: "Runtime control capability request.",
  }),
  diagnosticsQuery: define({
    component: "runtime.diagnostics",
    defaultSeverity: "debug",
    eventName: "diagnostics.query",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      itemCount: "int64",
      limit: "int64",
      queryKind: "string",
      ...commonPerformanceFields,
    },
    summary: "Runtime diagnostics paged query.",
  }),
  eventsDropped: define({
    component: "runtime.diagnostics",
    defaultSeverity: "warn",
    eventName: "diagnostics.events-dropped",
    eventSchemaVersion: 1,
    fields: {
      count: "int64",
      reason: "string",
      windowMicros: "int64",
    },
    summary: "Runtime diagnostic events were dropped under pressure.",
  }),
  fatal: define({
    component: "runtime.core",
    defaultSeverity: "fatal",
    eventName: "runtime.fatal",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      recovery: "string",
      stackFingerprint: "string",
      stage: "string",
    },
    summary: "Runtime crossed an unhandled failure boundary.",
  }),
  http: define({
    component: "runtime.http",
    defaultSeverity: "debug",
    eventName: "runtime.http",
    eventSchemaVersion: 1,
    fields: {
      bodyMicros: "int64",
      cacheState: "string",
      connectMicros: "int64",
      declaredBytes: "int64",
      dnsMicros: "int64",
      downloadBytes: "int64",
      errorCode: "string",
      mimeType: "string",
      method: "string",
      origin: "string",
      parseMicros: "int64",
      range: "bool",
      redirectCount: "int64",
      retryCount: "int64",
      route: "string",
      requestHeaderNames: "list",
      responseHeaderNames: "list",
      statusCode: "int64",
      ttfbMicros: "int64",
      uploadBytes: "int64",
      ...commonPerformanceFields,
    },
    summary: "Runtime-owned HTTP exchange.",
  }),
  httpHeaders: define({
    component: "runtime.http",
    defaultSeverity: "debug",
    eventName: "runtime.http-headers",
    eventSchemaVersion: 1,
    fields: {
      declaredBytes: "int64",
      mimeType: "string",
      redirectCount: "int64",
      responseHeaderNames: "list",
      statusCode: "int64",
      ttfbMicros: "int64",
    },
    summary: "Runtime HTTP response headers received.",
  }),
  lifecycle: define({
    component: "runtime.core",
    defaultSeverity: "info",
    eventName: "runtime.lifecycle",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      recovery: "string",
      stage: "string",
      ...commonPerformanceFields,
    },
    summary: "Runtime process lifecycle transition.",
  }),
  pluginDependency: define({
    component: "runtime.plugin",
    defaultSeverity: "debug",
    eventName: "runtime.plugin-dependency",
    eventSchemaVersion: 1,
    fields: {
      dependencyCount: "int64",
      errorCode: "string",
      objectBytes: "int64",
      operation: "string",
      ...commonPerformanceFields,
    },
    summary: "Runtime plugin dependency materialization.",
  }),
  pluginInstall: define({
    component: "runtime.plugin",
    defaultSeverity: "info",
    eventName: "runtime.plugin-install",
    eventSchemaVersion: 1,
    fields: {
      archiveBytes: "int64",
      errorCode: "string",
      fileCount: "int64",
      operation: "string",
      pendingActivation: "bool",
      ...commonPerformanceFields,
    },
    summary: "Runtime plugin installation lifecycle.",
  }),
  pluginInvoke: define({
    component: "runtime.plugin",
    defaultSeverity: "debug",
    eventName: "runtime.plugin-invoke",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      operation: "string",
      resultCount: "int64",
      resultBytes: "int64",
      ...commonPerformanceFields,
    },
    summary: "Runtime plugin capability invocation.",
  }),
  pluginLoad: define({
    component: "runtime.plugin",
    defaultSeverity: "info",
    eventName: "runtime.plugin-load",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      operation: "string",
      pluginCount: "int64",
      ...commonPerformanceFields,
    },
    summary: "Runtime plugin load and activation.",
  }),
  pressure: define({
    component: "runtime.diagnostics",
    defaultSeverity: "warn",
    eventName: "diagnostics.pressure",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      queueByteHighWater: "int64",
      queueDepth: "int64",
      queueHighWater: "int64",
      state: "string",
    },
    summary: "Runtime diagnostics writer pressure summary.",
  }),
  retention: define({
    component: "runtime.diagnostics",
    defaultSeverity: "info",
    eventName: "diagnostics.retention",
    eventSchemaVersion: 1,
    fields: {
      deletedEvents: "int64",
      deletedObjects: "int64",
      deletedSessions: "int64",
      errorCode: "string",
      reclaimedBytes: "int64",
      ...commonPerformanceFields,
    },
    summary: "Runtime diagnostics retention operation.",
  }),
  slow: define({
    component: "runtime.performance",
    defaultSeverity: "warn",
    eventName: "runtime.operation-slow",
    eventSchemaVersion: 1,
    fields: {
      operation: "string",
      ...commonPerformanceFields,
    },
    summary: "Runtime operation exceeded its measured slow threshold.",
  }),
  websocket: define({
    component: "runtime.transport",
    defaultSeverity: "debug",
    eventName: "runtime.websocket",
    eventSchemaVersion: 1,
    fields: {
      errorCode: "string",
      frameBytes: "int64",
      inFlight: "int64",
      operation: "string",
      outboundQueueBytes: "int64",
      ...commonPerformanceFields,
    },
    summary: "Runtime WebSocket session lifecycle.",
  }),
  writer: define({
    component: "runtime.diagnostics",
    defaultSeverity: "info",
    eventName: "diagnostics.writer",
    eventSchemaVersion: 1,
    fields: {
      batchSize: "int64",
      commitMicros: "int64",
      errorCode: "string",
      queueByteHighWater: "int64",
      queueHighWater: "int64",
      state: "string",
    },
    summary: "Runtime diagnostics writer lifecycle.",
  }),
});

const byName = new Map<string, RegisteredRuntimeDiagnosticEvent>(
  Object.values(runtimeDiagnosticEvents).map((definition) => [
    `${definition.eventName}@${definition.eventSchemaVersion}`,
    definition,
  ]),
);

/** Rejects ad-hoc event names, fields, or mismatched value kinds. */
export function validateRegisteredRuntimeDiagnosticEvent(
  definition: RuntimeDiagnosticEventDefinition,
  attributes: RuntimeDiagnosticObjectValue,
): RegisteredRuntimeDiagnosticEvent {
  const registered = byName.get(
    `${definition.eventName}@${definition.eventSchemaVersion}`,
  );
  if (
    registered === undefined ||
    registered.component !== definition.component ||
    registered.summary !== definition.summary
  ) {
    throw new TypeError("Runtime diagnostic event is not in the registry.");
  }
  for (const [key, value] of Object.entries(attributes.fields)) {
    const expected = registered.fields[key];
    if (expected === undefined) {
      throw new TypeError(`Runtime diagnostic field is not registered: ${key}.`);
    }
    if (expected !== "any" && value.type !== expected) {
      throw new TypeError(`Runtime diagnostic field ${key} must be ${expected}.`);
    }
  }
  return registered;
}
