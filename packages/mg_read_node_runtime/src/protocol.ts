/**
 * Runtime 内部控制协议信封与稳定错误类型。
 * 职责：解析、校验并构造有界 JSON RPC 请求、响应和取消信封。
 * 注意：不得把路径、端口实现细节或任意动态错误穿透到 Flutter Facade。
 */
import { protocolVersion } from "./runtime-version.js";

/** Primitive values permitted in a Runtime JSON payload. */
export type JsonPrimitive = boolean | null | number | string;

/** Recursive JSON value accepted by the bounded WebSocket control plane. */
export type JsonValue = JsonObject | JsonPrimitive | readonly JsonValue[];

/** A JSON object with string keys and JSON-compatible values only. */
export interface JsonObject {
  readonly [key: string]: JsonValue;
}

/**
 * Stable protocol error codes. These cross the Runtime boundary and therefore
 * must remain explicit rather than leaking Node or WebSocket implementation
 * errors to the Flutter Facade.
 */
export type RuntimeErrorCode =
  | "cancelled"
  | "capture_mode_unsupported"
  | "diagnostics_unavailable"
  | "internal"
  | "interaction_required"
  | "invalid_request"
  | "method_not_found"
  | "overloaded"
  | "plugin_disabled"
  | "plugin_execution_failed"
  | "plugin_invalid_response"
  | "plugin_load_failed"
  | "plugin_not_found"
  | "source_access_blocked"
  | "source_media_resolution_failed"
  | "plugin_transfer_artifact_missing"
  | "plugin_transfer_artifact_too_large"
  | "plugin_transfer_batch_too_large"
  | "plugin_transfer_build_failed"
  | "plugin_transfer_checksum_mismatch"
  | "plugin_transfer_size_mismatch"
  | "timeout"
  | "unsupported"
  | "version_incompatible";

/**
 * A validated client-to-Runtime control request.
 *
 * `deadlineUnixMs` intentionally remains a decimal string: it avoids a JSON
 * number precision mismatch between the Dart and Node implementations.
 */
export interface RuntimeRequest {
  /** Runtime instance identity recovered from the authenticated ready record. */
  readonly bootId: string;

  /** Decimal Unix-millisecond deadline, validated before dispatch. */
  readonly deadlineUnixMs: string;

  /** Unique client-direction correlation identifier for this live request. */
  readonly id: string;

  /** Optional replay-safety key required by selected lifecycle operations. */
  readonly idempotencyKey: null | string | undefined;

  /** Versioned Runtime-owned control method; not a host callback name. */
  readonly method: string;

  /** JSON object parameters decoded only by the Runtime's own capability code. */
  readonly params: JsonObject;

  /** Caller-provided tracing value echoed unchanged in correlated responses. */
  readonly traceId: string;

  /** Validated protocol version, narrowed to the local supported literal. */
  readonly v: typeof protocolVersion;
}

/** Identifiers recovered from an untrusted envelope, when present. */
export interface RuntimeEnvelopeIdentifiers {
  readonly requestId?: string | undefined;
  readonly traceId?: string | undefined;
}

/** A safe error description ready to become a protocol error response. */
export interface RuntimeProtocolError {
  /** Stable error class suitable for a Flutter-facing failure projection. */
  readonly code: RuntimeErrorCode;

  /** Fixed, safe human-readable explanation with no raw transport details. */
  readonly message: string;

  /** Request ID when it was safe to recover from the malformed envelope. */
  readonly requestId: string | undefined;

  /** Trace ID when it was safe to recover from the malformed envelope. */
  readonly traceId: string | undefined;
}

/**
 * A best-effort client cancellation. It has no response: a race with a
 * completed request is benign, while a queued/in-flight request is aborted.
 */
export interface RuntimeCancellation {
  /** Runtime instance identity that prevents a cross-restart cancellation. */
  readonly bootId: string;

  /** Unique ID of this cancellation command (it has no response). */
  readonly id: string;

  /** Client-direction request ID to abort only on the current session. */
  readonly targetId: string;

  /** Trace identifier associated with the target request. */
  readonly traceId: string;

  /** Validated protocol version, narrowed to the local supported literal. */
  readonly v: typeof protocolVersion;
}

/** JSON body embedded in a Runtime `error` response envelope. */
export interface RuntimeErrorPayload extends JsonObject {
  /** Stable protocol error code. */
  readonly code: RuntimeErrorCode;

  /** Safe, fixed error text. */
  readonly message: string;

  /** Whether a caller may retry after overload/backpressure subsides. */
  readonly retryable: boolean;
}

/** Server-to-client success response that correlates with one request. */
export interface RuntimeResponseEnvelope extends JsonObject {
  /** Runtime identity shared with the ready/hello transaction. */
  readonly bootId: string;

  /** Request ID that selects exactly one pending caller completion. */
  readonly id: string;

  /** JSON-safe successful capability result. */
  readonly result: JsonValue;

  /** Trace ID that must match the pending request before it is completed. */
  readonly traceId: string;

  /** Discriminant for a successful control response. */
  readonly type: "response";

  /** Protocol version echoed by the Runtime Core. */
  readonly v: typeof protocolVersion;
}

/** Server-to-client failure response that correlates with one request. */
export interface RuntimeErrorEnvelope extends JsonObject {
  /** Runtime identity shared with the ready/hello transaction. */
  readonly bootId: string;

  /** Safe protocol failure payload. */
  readonly error: RuntimeErrorPayload;

  /** Request ID that selects exactly one pending caller completion. */
  readonly id: string;

  /** Trace ID that must match the pending request before it is completed. */
  readonly traceId: string;

  /** Discriminant for a failed control response. */
  readonly type: "error";

  /** Protocol version echoed by the Runtime Core. */
  readonly v: typeof protocolVersion;
}

export type DevelopmentPluginChangeKind =
  | "activation_failed"
  | "added"
  | "build_failed"
  | "removed"
  | "updated";

/** One path-free desktop development-source change. */
export interface RuntimeDevelopmentPluginChange extends JsonObject {
  /** Display name from the development project's package.json. */
  readonly pluginName?: string;
  /** Bounded raw stdout/stderr from a failed development build. */
  readonly buildOutput?: string;
  readonly kind: DevelopmentPluginChangeKind;
  readonly pluginId?: string;
}

/** Uncorrelated server event delivered beside normal RPC responses. */
export interface RuntimeEventEnvelope extends JsonObject {
  readonly bootId: string;
  readonly changes: readonly RuntimeDevelopmentPluginChange[];
  readonly event: "development.plugins.changed";
  readonly revision: number;
  readonly type: "event";
  readonly v: typeof protocolVersion;
}

export function makeDevelopmentPluginEvent(
  bootId: string,
  revision: number,
  changes: readonly RuntimeDevelopmentPluginChange[],
): RuntimeEventEnvelope {
  return Object.freeze({
    bootId,
    changes: Object.freeze([...changes]),
    event: "development.plugins.changed",
    revision,
    type: "event",
    v: protocolVersion,
  });
}

/** Result of validating a normal request envelope. */
export type ParseRequestResult =
  | { readonly error: RuntimeProtocolError; readonly ok: false }
  | { readonly ok: true; readonly request: RuntimeRequest };

/** Result of validating a cancellation envelope. */
export type ParseCancellationResult =
  | { readonly cancellation: RuntimeCancellation; readonly ok: true }
  | { readonly error: RuntimeProtocolError; readonly ok: false };

/**
 * Validates an untrusted WebSocket JSON value as a control request.
 *
 * Validation is deliberately completed before dispatch. This keeps the Core's
 * request multiplexer free of malformed payloads and gives valid envelopes a
 * bounded, correlated error response on failure.
 */
export function parseRuntimeRequest(
  value: unknown,
  expectedBootId: string,
  nowUnixMs: number = Date.now(),
): ParseRequestResult {
  if (!isJsonObject(value)) {
    return invalidRequest("Wire envelope must be a JSON object.");
  }

  const requestId = readString(value, "id");
  const traceId = readString(value, "traceId");
  const common = { requestId, traceId };

  if (readString(value, "v") !== protocolVersion) {
    return {
      error: {
        ...common,
        code: "version_incompatible",
        message: "The Runtime protocol version is incompatible.",
      },
      ok: false,
    };
  }

  if (value.type !== "request") {
    return invalidRequest("Wire envelope type must be request.", common);
  }

  if (readString(value, "bootId") !== expectedBootId) {
    return invalidRequest("Wire envelope bootId does not match this Runtime.", common);
  }

  if (requestId === undefined || !requestId.startsWith("c:")) {
    return invalidRequest("Request id must be a client-direction id.", common);
  }

  if (traceId === undefined || traceId.length === 0) {
    return invalidRequest("Request traceId is required.", common);
  }

  const method = readString(value, "method");
  if (method === undefined || method.length === 0) {
    return invalidRequest("Request method is required.", common);
  }

  const deadlineUnixMs = readString(value, "deadlineUnixMs");
  if (!isSafeUnixMs(deadlineUnixMs)) {
    return invalidRequest("Request deadlineUnixMs must be a safe integer string.", common);
  }

  if (Number(deadlineUnixMs) <= nowUnixMs) {
    return {
      error: {
        ...common,
        code: "timeout",
        message: "The Runtime request deadline has elapsed.",
      },
      ok: false,
    };
  }

  if (!isJsonObject(value.params)) {
    return invalidRequest("Request params must be a JSON object.", common);
  }

  const idempotencyKey = value.idempotencyKey;
  if (
    idempotencyKey !== undefined &&
    idempotencyKey !== null &&
    typeof idempotencyKey !== "string"
  ) {
    return invalidRequest("Request idempotencyKey must be a string or null.", common);
  }

  return {
    ok: true,
    request: {
      bootId: expectedBootId,
      deadlineUnixMs,
      id: requestId,
      idempotencyKey,
      method,
      params: value.params,
      traceId,
      v: protocolVersion,
    },
  };
}

/**
 * Validates a best-effort client cancellation envelope.
 *
 * Cancellation has no success response: it removes queued/in-flight Runtime
 * work if it is still present, while a race with completed work is harmless.
 */
export function parseRuntimeCancellation(
  value: unknown,
  expectedBootId: string,
): ParseCancellationResult {
  if (!isJsonObject(value)) {
    return invalidCancellation("Wire envelope must be a JSON object.");
  }

  const requestId = readString(value, "id");
  const traceId = readString(value, "traceId");
  const common = { requestId, traceId };

  if (readString(value, "v") !== protocolVersion) {
    return {
      error: {
        ...common,
        code: "version_incompatible",
        message: "The Runtime protocol version is incompatible.",
      },
      ok: false,
    };
  }

  if (value.type !== "cancel") {
    return invalidCancellation("Wire envelope type must be cancel.", common);
  }

  if (readString(value, "bootId") !== expectedBootId) {
    return invalidCancellation("Wire envelope bootId does not match this Runtime.", common);
  }

  const targetId = readString(value, "targetId");
  if (requestId === undefined || !requestId.startsWith("c:")) {
    return invalidCancellation("Cancel id must be a client-direction id.", common);
  }
  if (targetId === undefined || !targetId.startsWith("c:")) {
    return invalidCancellation("Cancel targetId must be a client-direction id.", common);
  }
  if (traceId === undefined || traceId.length === 0) {
    return invalidCancellation("Cancel traceId is required.", common);
  }

  return {
    cancellation: {
      bootId: expectedBootId,
      id: requestId,
      targetId,
      traceId,
      v: protocolVersion,
    },
    ok: true,
  };
}

/** Fast discriminator used before parsing a cancellation's full schema. */
export function isRuntimeCancellationEnvelope(value: unknown): boolean {
  return isJsonObject(value) && value.type === "cancel";
}

/** Builds the protocol-prescribed success envelope for a validated request. */
export function makeResponse(
  bootId: string,
  request: RuntimeRequest,
  result: JsonValue,
): RuntimeResponseEnvelope {
  return {
    bootId,
    id: request.id,
    result,
    traceId: request.traceId,
    type: "response",
    v: protocolVersion,
  };
}

/**
 * Builds a correlated protocol error envelope when both client identifiers are
 * trustworthy. Callers must close malformed sessions when this returns
 * `undefined`, because there is no safe request to answer.
 */
export function makeError(
  bootId: string,
  error: RuntimeProtocolError,
): RuntimeErrorEnvelope | undefined {
  if (error.requestId === undefined || error.traceId === undefined) {
    return undefined;
  }

  return {
    bootId,
    error: {
      code: error.code,
      message: error.message,
      retryable:
        error.code === "overloaded" ||
        error.code === "source_access_blocked" ||
        error.code === "source_media_resolution_failed",
    },
    id: error.requestId,
    traceId: error.traceId,
    type: "error",
    v: protocolVersion,
  };
}

function invalidRequest(
  message: string,
  identifiers: RuntimeEnvelopeIdentifiers = {},
): ParseRequestResult {
  return {
    error: {
      code: "invalid_request",
      message,
      requestId: identifiers.requestId,
      traceId: identifiers.traceId,
    },
    ok: false,
  };
}

function invalidCancellation(
  message: string,
  identifiers: RuntimeEnvelopeIdentifiers = {},
): ParseCancellationResult {
  return {
    error: {
      code: "invalid_request",
      message,
      requestId: identifiers.requestId,
      traceId: identifiers.traceId,
    },
    ok: false,
  };
}

/** Narrows an unknown value to the Runtime's JSON-object subset. */
function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Accepts only non-negative, exactly representable Unix millisecond strings. */
function isSafeUnixMs(value: string | undefined): value is string {
  if (value === undefined || !/^(0|[1-9][0-9]*)$/.test(value)) {
    return false;
  }

  const numericValue = Number(value);
  return Number.isSafeInteger(numericValue) && numericValue >= 0;
}

/** Reads a string property without treating a non-string JSON value as valid. */
function readString(value: JsonObject, key: string): string | undefined {
  const candidate = value[key];
  return typeof candidate === "string" ? candidate : undefined;
}
