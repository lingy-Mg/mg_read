/** Version of the persisted and Facade-visible Runtime diagnostic envelope. */
export const runtimeDiagnosticEnvelopeVersion = 1 as const;

/** Hard limits applied before an event can enter the writer queue. */
export const runtimeDiagnosticValueLimits = Object.freeze({
  maxArrayItems: 256,
  maxDepth: 8,
  maxEncodedBytes: 16 * 1024,
  maxObjectKeys: 128,
  maxStringCodeUnits: 4 * 1024,
});

export type RuntimeDiagnosticSeverity =
  | "trace"
  | "debug"
  | "info"
  | "warn"
  | "error"
  | "fatal";

export type RuntimeDiagnosticPhase = "instant" | "start" | "terminal";

export type RuntimeDiagnosticOutcome =
  | "success"
  | "error"
  | "cancelled"
  | "timeout"
  | "overloaded"
  | "incomplete";

export type RuntimeDiagnosticPayloadKind =
  | "metadataOnly"
  | "safeStructured"
  | "contentPayload"
  | "restrictedRaw";

export type RuntimeDiagnosticPrivacyClass =
  | "public"
  | "internal"
  | "content"
  | "restricted"
  | "secret";

export type RuntimeDiagnosticCaptureState =
  | "captured"
  | "truncated"
  | "policyBlocked"
  | "pressureDropped"
  | "failed";

export type RuntimeDiagnosticStorageCodec = "identity";

export type RuntimeDiagnosticEventFlag =
  | "sampled"
  | "truncated"
  | "redacted"
  | "droppedPayload"
  | "incomplete";

export type RuntimeDiagnosticSessionState =
  | "active"
  | "ended"
  | "expired"
  | "deleting"
  | "deleted";

/** Stable tagged value; arbitrary objects never cross the manager boundary. */
export type RuntimeDiagnosticValue =
  | RuntimeDiagnosticNullValue
  | RuntimeDiagnosticBooleanValue
  | RuntimeDiagnosticStringValue
  | RuntimeDiagnosticInt64Value
  | RuntimeDiagnosticDoubleValue
  | RuntimeDiagnosticListValue
  | RuntimeDiagnosticObjectValue
  | RuntimeDiagnosticRedactedValue
  | RuntimeDiagnosticTruncatedValue
  | RuntimeDiagnosticAttachmentReferenceValue;

export interface RuntimeDiagnosticNullValue {
  readonly type: "null";
}

export interface RuntimeDiagnosticBooleanValue {
  readonly type: "bool";
  readonly value: boolean;
}

export interface RuntimeDiagnosticStringValue {
  readonly type: "string";
  readonly value: string;
}

export interface RuntimeDiagnosticInt64Value {
  readonly type: "int64";
  readonly value: string;
}

export interface RuntimeDiagnosticDoubleValue {
  readonly type: "double";
  readonly value: number;
}

export interface RuntimeDiagnosticListValue {
  readonly type: "list";
  readonly items: readonly RuntimeDiagnosticValue[];
}

export interface RuntimeDiagnosticObjectValue {
  readonly type: "object";
  readonly fields: Readonly<Record<string, RuntimeDiagnosticValue>>;
}

export interface RuntimeDiagnosticRedactedValue {
  readonly type: "redacted";
  readonly reason: string;
}

export interface RuntimeDiagnosticTruncatedValue {
  readonly type: "truncated";
  readonly reason: string;
  readonly originalCount?: number;
}

export interface RuntimeDiagnosticAttachmentReferenceValue {
  readonly type: "attachmentRef";
  readonly attachmentId: string;
}

/** Explicit constructors keep callers from passing arbitrary dynamic values. */
export const runtimeDiagnosticValue = Object.freeze({
  attachment(attachmentId: string): RuntimeDiagnosticAttachmentReferenceValue {
    validateRuntimeDiagnosticOpaqueId(attachmentId, "attachmentId");
    return Object.freeze({ attachmentId, type: "attachmentRef" });
  },
  boolean(value: boolean): RuntimeDiagnosticBooleanValue {
    return Object.freeze({ type: "bool", value });
  },
  double(value: number): RuntimeDiagnosticDoubleValue {
    if (!Number.isFinite(value)) {
      throw new TypeError("Diagnostic doubles must be finite.");
    }
    return Object.freeze({ type: "double", value });
  },
  int64(value: bigint | string): RuntimeDiagnosticInt64Value {
    const encoded = typeof value === "bigint" ? value.toString(10) : value;
    if (!/^-?(?:0|[1-9][0-9]*)$/.test(encoded)) {
      throw new TypeError("Diagnostic int64 values use canonical decimal text.");
    }
    return Object.freeze({ type: "int64", value: encoded });
  },
  list(items: readonly RuntimeDiagnosticValue[]): RuntimeDiagnosticListValue {
    return Object.freeze({ items: Object.freeze([...items]), type: "list" });
  },
  null(): RuntimeDiagnosticNullValue {
    return Object.freeze({ type: "null" });
  },
  object(
    fields: Readonly<Record<string, RuntimeDiagnosticValue>>,
  ): RuntimeDiagnosticObjectValue {
    for (const key of Object.keys(fields)) {
      validateRuntimeDiagnosticFieldName(key, "attribute key");
    }
    return Object.freeze({ fields: Object.freeze({ ...fields }), type: "object" });
  },
  redacted(reason = "policy"): RuntimeDiagnosticRedactedValue {
    validateBoundedToken(reason, "redaction reason");
    return Object.freeze({ reason, type: "redacted" });
  },
  string(value: string): RuntimeDiagnosticStringValue {
    if (value.length > runtimeDiagnosticValueLimits.maxStringCodeUnits) {
      throw new RangeError("Diagnostic strings exceed the bounded field limit.");
    }
    return Object.freeze({ type: "string", value });
  },
  truncated(
    reason: string,
    originalCount?: number,
  ): RuntimeDiagnosticTruncatedValue {
    validateBoundedToken(reason, "truncation reason");
    if (originalCount !== undefined && (!Number.isSafeInteger(originalCount) || originalCount < 0)) {
      throw new RangeError("Diagnostic truncation counts must be safe non-negative integers.");
    }
    return Object.freeze({
      ...(originalCount === undefined ? {} : { originalCount }),
      reason,
      type: "truncated",
    });
  },
});

export interface RuntimeDiagnosticTraceContext {
  readonly traceId: string;
  readonly spanId: string;
  readonly parentSpanId?: string;
}

export interface RuntimeDiagnosticEventDefinition {
  readonly component: string;
  readonly defaultSeverity: RuntimeDiagnosticSeverity;
  readonly eventName: string;
  readonly eventSchemaVersion: number;
  readonly summary: string;
}

export interface RuntimeDiagnosticEventDraft {
  readonly attributes?: RuntimeDiagnosticObjectValue;
  readonly captureSessionId?: string;
  readonly definition: RuntimeDiagnosticEventDefinition;
  readonly durationMicros?: number;
  readonly flags?: ReadonlySet<RuntimeDiagnosticEventFlag>;
  readonly outcome?: RuntimeDiagnosticOutcome;
  readonly phase?: RuntimeDiagnosticPhase;
  readonly severity?: RuntimeDiagnosticSeverity;
  readonly trace?: RuntimeDiagnosticTraceContext;
}

/** Immutable event projection persisted in the Runtime-owned index. */
export interface RuntimeDiagnosticEvent {
  readonly attachmentCount: number;
  readonly attributes: RuntimeDiagnosticObjectValue;
  readonly capturedBytes: number;
  readonly captureSessionId: string;
  readonly component: string;
  readonly durationMicros?: number;
  readonly envelopeVersion: number;
  readonly eventId: string;
  readonly eventName: string;
  readonly eventSchemaVersion: number;
  readonly flags: readonly RuntimeDiagnosticEventFlag[];
  readonly monotonicOffsetMicros: number;
  readonly occurredAtUtcMicros: number;
  readonly outcome?: RuntimeDiagnosticOutcome;
  readonly parentSpanId?: string;
  readonly phase: RuntimeDiagnosticPhase;
  readonly severity: RuntimeDiagnosticSeverity;
  readonly source: "runtime";
  readonly sourceRunId: string;
  readonly sourceSequence: number;
  readonly spanId?: string;
  readonly summary: string;
  readonly traceId?: string;
}

export interface RuntimeDiagnosticSession {
  readonly attachmentCount: number;
  readonly endedAtUtcMicros?: number;
  readonly eventCount: number;
  readonly expiresAtUtcMicros?: number;
  readonly payloadKind: RuntimeDiagnosticPayloadKind;
  readonly sessionId: string;
  readonly source: "runtime";
  readonly sourceRunId: string;
  readonly startedAtUtcMicros: number;
  readonly state: RuntimeDiagnosticSessionState;
  readonly storedBytes: number;
}

export interface RuntimeDiagnosticAttachmentDescriptor {
  readonly attachmentId: string;
  readonly captureState: RuntimeDiagnosticCaptureState;
  readonly charset?: string;
  readonly eventId: string;
  readonly formatId: string;
  readonly formatVersion: number;
  readonly kind: string;
  readonly mediaType: string;
  readonly privacyClass: RuntimeDiagnosticPrivacyClass;
  readonly rawByteLength: number;
  readonly redactionVersion: number;
  readonly schemaId?: string;
  readonly schemaVersion?: number;
  readonly sha256?: string;
  readonly storageCodec: RuntimeDiagnosticStorageCodec;
  readonly storedByteLength: number;
  readonly truncationReason?: string;
}

export interface RuntimeDiagnosticCapturePolicy {
  readonly components: ReadonlySet<string>;
  readonly durationMillis: number;
  readonly maxStoredBytes: number;
  readonly origins: ReadonlySet<string>;
  readonly payloadKind: RuntimeDiagnosticPayloadKind;
}

export interface RuntimeDiagnosticSessionFilter {
  readonly startedAfterUtcMicros?: number;
  readonly startedBeforeUtcMicros?: number;
  readonly states?: ReadonlySet<RuntimeDiagnosticSessionState>;
}

export interface RuntimeDiagnosticEventFilter {
  readonly components?: ReadonlySet<string>;
  readonly eventNames?: ReadonlySet<string>;
  readonly minimumSeverity?: RuntimeDiagnosticSeverity;
  readonly occurredAfterUtcMicros?: number;
  readonly occurredBeforeUtcMicros?: number;
  readonly sessionId?: string;
  readonly traceId?: string;
}

export interface RuntimeDiagnosticPage<T> {
  readonly items: readonly T[];
  readonly nextCursor?: string;
}

export interface RuntimeDiagnosticAttachmentRange {
  readonly length: number;
  readonly offset: number;
}

export interface RuntimeDiagnosticAttachmentChunk {
  readonly bytesBase64: string;
  readonly eof: boolean;
  readonly nextOffset: number;
  readonly totalStoredBytes: number;
}

/** Validates a small value recursively and returns its encoded byte estimate. */
export function validateRuntimeDiagnosticValue(
  value: RuntimeDiagnosticValue,
): number {
  let nodes = 0;
  const visit = (current: RuntimeDiagnosticValue, depth: number): void => {
    nodes += 1;
    if (depth > runtimeDiagnosticValueLimits.maxDepth) {
      throw new RangeError("Diagnostic values exceed the maximum depth.");
    }
    switch (current.type) {
      case "null":
      case "bool":
      case "int64":
      case "double":
      case "redacted":
      case "truncated":
      case "attachmentRef":
        return;
      case "string":
        if (current.value.length > runtimeDiagnosticValueLimits.maxStringCodeUnits) {
          throw new RangeError("Diagnostic strings exceed the bounded field limit.");
        }
        return;
      case "list":
        if (current.items.length > runtimeDiagnosticValueLimits.maxArrayItems) {
          throw new RangeError("Diagnostic lists exceed the bounded item limit.");
        }
        for (const item of current.items) visit(item, depth + 1);
        return;
      case "object": {
        const entries = Object.entries(current.fields);
        if (entries.length > runtimeDiagnosticValueLimits.maxObjectKeys) {
          throw new RangeError("Diagnostic objects exceed the bounded key limit.");
        }
        for (const [key, item] of entries) {
          validateRuntimeDiagnosticFieldName(key, "attribute key");
          visit(item, depth + 1);
        }
      }
    }
  };
  visit(value, 0);
  if (nodes > 4096) {
    throw new RangeError("Diagnostic values exceed the bounded node limit.");
  }
  const encodedBytes = Buffer.byteLength(JSON.stringify(value), "utf8");
  if (encodedBytes > runtimeDiagnosticValueLimits.maxEncodedBytes) {
    throw new RangeError("Diagnostic attributes exceed the encoded byte limit.");
  }
  return encodedBytes;
}

export function validateRuntimeDiagnosticEventDefinition(
  definition: RuntimeDiagnosticEventDefinition,
): void {
  validateRuntimeDiagnosticName(definition.component, "component");
  validateRuntimeDiagnosticName(definition.eventName, "eventName");
  if (!Number.isSafeInteger(definition.eventSchemaVersion) || definition.eventSchemaVersion <= 0) {
    throw new RangeError("Diagnostic schema versions must be positive integers.");
  }
  if (
    definition.summary.length === 0 ||
    definition.summary.length > 512 ||
    /[\r\n]/.test(definition.summary)
  ) {
    throw new RangeError("Diagnostic summaries must be bounded single-line text.");
  }
}

export function validateRuntimeDiagnosticCapturePolicy(
  policy: RuntimeDiagnosticCapturePolicy,
): void {
  if (
    !Number.isSafeInteger(policy.durationMillis) ||
    policy.durationMillis <= 0 ||
    !Number.isSafeInteger(policy.maxStoredBytes) ||
    policy.maxStoredBytes <= 0
  ) {
    throw new RangeError("Capture duration and byte quota must be positive integers.");
  }
  if (policy.payloadKind === "restrictedRaw") {
    throw new Error("restrictedRaw capture is unsupported until the D5 security decision.");
  }
  if (
    policy.payloadKind !== "metadataOnly" &&
    policy.components.size === 0 &&
    policy.origins.size === 0
  ) {
    throw new Error("Payload capture requires a component or origin allowlist.");
  }
  for (const component of policy.components) {
    validateRuntimeDiagnosticName(component, "capture component");
  }
  for (const origin of policy.origins) {
    if (!/^https?:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?$/i.test(origin) || origin.length > 256) {
      throw new TypeError("Capture origins must be bounded HTTP(S) origins without paths.");
    }
  }
}

export function validateRuntimeDiagnosticName(value: string, label: string): void {
  if (!/^[a-z][a-z0-9]*(?:[._-][a-z][a-z0-9]*)*$/.test(value)) {
    throw new TypeError(`${label} must be a stable diagnostic name.`);
  }
}

export function validateRuntimeDiagnosticFieldName(value: string, label: string): void {
  if (!/^[A-Za-z][A-Za-z0-9_.-]{0,127}$/.test(value)) {
    throw new TypeError(`${label} must be a stable diagnostic field name.`);
  }
}

export function validateRuntimeDiagnosticOpaqueId(value: string, label: string): void {
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(value)) {
    throw new TypeError(`${label} must be an opaque diagnostic identifier.`);
  }
}

function validateBoundedToken(value: string, label: string): void {
  if (!/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/.test(value)) {
    throw new TypeError(`${label} must be a bounded stable token.`);
  }
}
