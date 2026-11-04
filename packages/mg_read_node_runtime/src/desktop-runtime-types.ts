/**
 * Private shapes shared by the desktop Runtime control and transport paths.
 *
 * This module keeps protocol response types out of the already large Runtime
 * lifecycle owner. It contains no IO and must not become a public API surface.
 */
import type {
  JsonObject,
  JsonValue,
  RuntimeErrorCode,
  RuntimeProtocolError,
  RuntimeRequest,
} from "./protocol.js";
import type { ServerWebSocketSession } from "./websocket.js";

export type RuntimeDispatchResult = RuntimeDispatchFailure | RuntimeDispatchSuccess;

/** Builds a correlated protocol error after the outer envelope is validated. */
export type RuntimeRequestErrorFactory = (
  request: RuntimeRequest,
  code: RuntimeErrorCode,
  message: string,
) => RuntimeProtocolError;

export interface RuntimeDispatchFailure {
  readonly error: RuntimeProtocolError;
}

interface RuntimeDispatchSuccess {
  readonly result: JsonValue;
}

export type InFlightRequestsBySession = Map<
  ServerWebSocketSession,
  Map<string, RuntimeInFlightRequest>
>;

export interface RuntimeInFlightRequest {
  readonly cancellation: AbortController;
}

export interface RuntimeHealthResponse extends JsonObject {
  readonly bootId: string;
  readonly nodeVersion: string;
  readonly protocolVersion: string;
  readonly runtimeVersion: string;
  readonly status: "live" | "ready";
}

export interface RuntimeHelloResponse extends JsonObject {
  readonly bootId: string;
  readonly capabilities: readonly string[];
  readonly maxFrameBytes: number;
  readonly maxInFlightRequests: number;
  readonly maxInlineBytes: number;
  readonly maxOutboundQueueBytes: number;
  readonly nodeVersion: string;
  readonly protocolVersion: string;
  readonly runtimeVersion: string;
  readonly supportsCancellation: boolean;
}

export interface RuntimePingResponse extends JsonObject {
  readonly bootId: string;
  readonly nodeVersion: string;
  readonly ok: boolean;
  readonly runtimeVersion: string;
}

export interface RuntimeStatusResponse extends JsonObject {
  readonly arch: string;
  readonly bootId: string;
  readonly memory: {
    readonly arrayBuffers: number;
    readonly external: number;
    readonly heapTotal: number;
    readonly heapUsed: number;
    readonly rss: number;
  };
  readonly nodeVersion: string;
  readonly ok: boolean;
  readonly platform: string;
  readonly plugins: readonly JsonObject[];
  readonly runtimeVersion: string;
  readonly runtimeKind: "android-javet" | "android-node-process" | "desktop-node" | "desktop-bun";
  readonly uptimeMs: number;
}

export interface RuntimeShutdownResponse extends JsonObject {
  readonly accepted: boolean;
}

/**
 * One stdout-only startup record emitted after the loopback server is usable.
 * It is consumed by the Runtime-owned Flutter supervisor, never by app code.
 */
export interface DesktopRuntimeReady {
  /** Fresh identity that binds HTTP, WebSocket, and Flutter startup together. */
  readonly bootId: string;
  /** Fixed loopback-only host; this Runtime never listens on LAN interfaces. */
  readonly host: "127.0.0.1";
  /** Exact Node binary version that started the Core. */
  readonly nodeVersion: string;
  /** Runtime child process identifier, used only for lifecycle diagnostics. */
  readonly pid: number;
  /** Ephemeral loopback port selected by Node or supplied by a test. */
  readonly port: number;
  /** Wire-protocol version that the Flutter connection must validate. */
  readonly protocolVersion: string;
  /** Runtime implementation version for compatibility and diagnostics. */
  readonly runtimeVersion: string;
  /** ISO-8601 timestamp captured once when this Core instance is created. */
  readonly startedAt: string;
  /** Distinguishes this stdout record from structured diagnostic records. */
  readonly type: "ready";
}
