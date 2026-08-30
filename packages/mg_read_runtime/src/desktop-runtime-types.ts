/**
 * Private shapes shared by the desktop Runtime control and transport paths.
 *
 * This module keeps protocol response types out of the already large Runtime
 * lifecycle owner. It contains no IO and must not become a public API surface.
 */
import type { JsonObject, JsonValue, RuntimeProtocolError } from "./protocol.js";
import type { ServerWebSocketSession } from "./websocket.js";

export type RuntimeDispatchResult = RuntimeDispatchFailure | RuntimeDispatchSuccess;

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
  readonly runtimeKind: "android-javet" | "desktop-node";
  readonly uptimeMs: number;
}

export interface RuntimeShutdownResponse extends JsonObject {
  readonly accepted: boolean;
}
