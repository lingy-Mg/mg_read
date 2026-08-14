import { createHash, randomUUID } from "node:crypto";
import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { Duplex } from "node:stream";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import {
  type JsonObject,
  type JsonValue,
  isRuntimeCancellationEnvelope,
  makeError,
  makeResponse,
  parseRuntimeCancellation,
  parseRuntimeRequest,
  type RuntimeErrorCode,
  type RuntimeProtocolError,
  type RuntimeRequest,
} from "./protocol.js";
import {
  expectedNodeVersion,
  protocolVersion,
  runtimeVersion,
} from "./runtime-version.js";
import {
  maxWebSocketControlFrameBytes,
  maxWebSocketOutboundQueueBytes,
  ServerWebSocketSession,
} from "./websocket.js";
import {
  PluginManager,
  PluginManagerError,
  type PluginManagerEvent,
} from "./plugin-manager.js";
import { emitRuntimeDiagnostic } from "./runtime-diagnostics.js";

const LOOPBACK_HOST = "127.0.0.1";
const MAX_INLINE_BYTES = maxWebSocketControlFrameBytes;
const MAX_INFLIGHT_REQUESTS_PER_CONNECTION = 256;
const RUNTIME_CONTROL_METHOD = Object.freeze({
  hello: "runtime.hello",
  ping: "runtime.ping",
  pluginSearch: "plugin.search.v1",
  pluginsList: "plugins.list.v1",
  shutdown: "runtime.shutdown",
} as const);
const RUNTIME_CONTROL_CAPABILITIES = Object.freeze([
  RUNTIME_CONTROL_METHOD.ping,
  RUNTIME_CONTROL_METHOD.pluginsList,
  RUNTIME_CONTROL_METHOD.pluginSearch,
  RUNTIME_CONTROL_METHOD.shutdown,
]);
const RUNTIME_RPC_PATH = "/v1/rpc";
const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** Result of a control handler before it is encoded on the WebSocket. */
type RuntimeDispatchResult = RuntimeDispatchFailure | RuntimeDispatchSuccess;

/** A handler failure that will become a correlated protocol error envelope. */
interface RuntimeDispatchFailure {
  readonly error: RuntimeProtocolError;
}

/** A handler success that will become a correlated protocol response envelope. */
interface RuntimeDispatchSuccess {
  readonly result: JsonValue;
}

/** Request cancellations grouped by the connection that owns them. */
type InFlightRequestsBySession = Map<
  ServerWebSocketSession,
  Map<string, AbortController>
>;

/** Shape returned by the two loopback health endpoints. */
interface RuntimeHealthResponse extends JsonObject {
  readonly bootId: string;
  readonly nodeVersion: string;
  readonly protocolVersion: string;
  readonly runtimeVersion: string;
  readonly status: "live" | "ready";
}

/** Negotiated limits and identity returned by `runtime.hello`. */
interface RuntimeHelloResponse extends JsonObject {
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

/** Result of the minimal diagnostic capability used by the desktop tests. */
interface RuntimePingResponse extends JsonObject {
  readonly bootId: string;
  readonly nodeVersion: string;
  readonly ok: boolean;
  readonly runtimeVersion: string;
}

/** Acknowledgement sent before the Core begins asynchronous shutdown. */
interface RuntimeShutdownResponse extends JsonObject {
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
  readonly host: typeof LOOPBACK_HOST;
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

/** Construction-only options for the Node Runtime Core. */
export interface DesktopRuntimeOptions {
  /**
   * Requested loopback port. Production uses `0` for an OS-selected port;
   * nonzero values exist only for deterministic Runtime-owned tests.
   */
  readonly port?: number;

  /** Runtime-owned data root; production resolves it in the platform adapter. */
  readonly dataRoot?: string;
}

/**
 * A single desktop Node Runtime Core. Its HTTP and WebSocket endpoints are
 * Runtime internals; Flutter callers must use the Runtime Facade instead.
 */
export class DesktopRuntime {
  /** Immutable per-process identity; never reused by a restart. */
  readonly #bootId = randomUUID();

  /** Per-session cancellation state, bounded before a handler is scheduled. */
  readonly #inFlightRequests: InFlightRequestsBySession = new Map();

  /** Requested port captured at construction to avoid mutable launch options. */
  readonly #port: number;

  /** Runtime-owned plugin/dependency/data root, never exposed through Facade. */
  readonly #dataRoot: string;

  /** All currently open RPC sessions, closed before server shutdown. */
  readonly #sessions = new Set<ServerWebSocketSession>();

  /** Fixed start timestamp included in the stdout readiness record. */
  readonly #startedAt = new Date().toISOString();
  #ready: DesktopRuntimeReady | undefined;
  #server: Server | undefined;
  #startPromise: Promise<DesktopRuntimeReady> | undefined;
  #stopPromise: Promise<void> | undefined;
  #pluginManager: PluginManager | undefined;

  constructor(options: DesktopRuntimeOptions = {}) {
    this.#port = options.port ?? 0;
    this.#dataRoot =
      options.dataRoot ??
      resolve(tmpdir(), "mgread-runtime-tests", process.pid.toString());
  }

  /**
   * Starts the bounded loopback server exactly once and returns its ready
   * record. Concurrent callers share the same promise rather than binding a
   * second listener or creating a second VM.
   */
  start(): Promise<DesktopRuntimeReady> {
    if (this.#ready !== undefined) {
      return Promise.resolve(this.#ready);
    }

    if (this.#startPromise === undefined) {
      this.#startPromise = this.#start();
    }

    return this.#startPromise;
  }

  /**
   * Stops all sessions, aborts pending handlers, and closes the listener once.
   * Concurrent stop requests share one cleanup operation.
   */
  stop(): Promise<void> {
    if (this.#stopPromise === undefined) {
      this.#stopPromise = this.#stop();
    }

    return this.#stopPromise;
  }

  /** Performs the single Core launch after `start` has claimed the promise. */
  async #start(): Promise<DesktopRuntimeReady> {
    if (process.versions.node !== expectedNodeVersion) {
      throw new Error(
        `Runtime requires Node ${expectedNodeVersion}, received ${process.versions.node}.`,
      );
    }

    const pluginManager = new PluginManager(this.#dataRoot, {
      events: emitPluginManagerDiagnostic,
    });
    await pluginManager.initialize();
    this.#pluginManager = pluginManager;
    emitRuntimeDiagnostic({
      code: "plugin_runtime_initialized",
      level: "info",
      message: "The standard Node plugin runtime initialized successfully.",
      type: "diagnostic",
    });

    const server = createServer((request, response) => {
      this.#handleHttp(request, response);
    });
    server.on("upgrade", (request, socket, head) => {
      this.#handleUpgrade(request, socket, head);
    });
    this.#server = server;

    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (error: Error): void => {
          server.off("listening", onListening);
          reject(error);
        };
        const onListening = (): void => {
          server.off("error", onError);
          resolve();
        };

        server.once("error", onError);
        server.once("listening", onListening);
        server.listen({ host: LOOPBACK_HOST, port: this.#port });
      });
    } catch (error) {
      this.#server = undefined;
      server.close();
      throw error;
    }

    const address = server.address();
    if (address === null || typeof address === "string") {
      throw new Error("Runtime did not expose a TCP loopback address.");
    }

    const ready: DesktopRuntimeReady = Object.freeze({
      bootId: this.#bootId,
      host: LOOPBACK_HOST,
      nodeVersion: process.versions.node,
      pid: process.pid,
      port: address.port,
      protocolVersion,
      runtimeVersion,
      startedAt: this.#startedAt,
      type: "ready",
    });
    this.#ready = ready;
    return ready;
  }

  /** Performs ordered shutdown so handlers cannot outlive their transport. */
  async #stop(): Promise<void> {
    const server = this.#server;
    if (server === undefined) {
      return;
    }

    for (const session of [...this.#sessions]) {
      session.close(1001, "Runtime is stopping.");
    }
    this.#sessions.clear();
    this.#abortAllInFlightRequests();
    server.closeAllConnections();

    await new Promise<void>((resolve, reject) => {
      server.close((error) => {
        const code = (error as NodeJS.ErrnoException | undefined)?.code;
        if (error !== undefined && code !== "ERR_SERVER_NOT_RUNNING") {
          reject(error);
          return;
        }

        resolve();
      });
    });
    this.#server = undefined;
  }

  /** Serves no-store liveness/readiness checks on the Runtime loopback plane. */
  #handleHttp(request: IncomingMessage, response: ServerResponse): void {
    const url = new URL(request.url ?? "/", `http://${LOOPBACK_HOST}`);
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      response.end();
      return;
    }

    if (url.pathname === "/health/live") {
      const live: RuntimeHealthResponse = {
        bootId: this.#bootId,
        nodeVersion: process.versions.node,
        protocolVersion,
        runtimeVersion,
        status: "live",
      };
      this.#writeJson(response, 200, live);
      return;
    }

    if (url.pathname === "/health/ready" && this.#ready !== undefined) {
      const ready: RuntimeHealthResponse = {
        bootId: this.#bootId,
        nodeVersion: process.versions.node,
        protocolVersion,
        runtimeVersion,
        status: "ready",
      };
      this.#writeJson(response, 200, ready);
      return;
    }

    this.#writeJson(response, 404, { code: "not_found" });
  }

  /**
   * Completes the one internal WebSocket upgrade endpoint.
   *
   * It constructs the session before processing `head`, so bytes received with
   * the HTTP upgrade cannot bypass the same framing and request limits.
   */
  #handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    const url = new URL(request.url ?? "/", `http://${LOOPBACK_HOST}`);
    const key = request.headers["sec-websocket-key"];
    const upgrade = request.headers.upgrade;

    if (
      url.pathname !== RUNTIME_RPC_PATH ||
      typeof key !== "string" ||
      upgrade?.toLowerCase() !== "websocket"
    ) {
      this.#rejectUpgrade(socket, 400, "Invalid Runtime WebSocket upgrade.");
      return;
    }

    const accept = createHash("sha1")
      .update(`${key}${WEBSOCKET_GUID}`)
      .digest("base64");
    socket.write(
      [
        "HTTP/1.1 101 Switching Protocols",
        "Connection: Upgrade",
        "Upgrade: websocket",
        `Sec-WebSocket-Accept: ${accept}`,
        "",
        "",
      ].join("\r\n"),
    );

    let session: ServerWebSocketSession | undefined;
    session = new ServerWebSocketSession(socket, {
      onClosed: () => {
        if (session !== undefined) {
          this.#sessions.delete(session);
          this.#abortSessionRequests(session);
        }
      },
      onText: (text) => {
        if (session !== undefined) {
          this.#handleWireText(session, text);
        }
      },
    });
    this.#sessions.add(session);
    this.#inFlightRequests.set(session, new Map());

    if (head.length > 0) {
      session.receive(head);
    }
  }

  /**
   * Validates and schedules one control envelope without serializing unrelated
   * requests on the same session. Each accepted request owns one abort signal.
   */
  #handleWireText(session: ServerWebSocketSession, text: string): void {
    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(text) as unknown;
    } catch {
      session.close(1007, "Runtime control frame must contain JSON.");
      return;
    }

    if (isRuntimeCancellationEnvelope(parsedJson)) {
      const parsedCancellation = parseRuntimeCancellation(parsedJson, this.#bootId);
      if (!parsedCancellation.ok) {
        this.#sendProtocolError(session, parsedCancellation.error);
        return;
      }
      this.#cancelRequest(session, parsedCancellation.cancellation.targetId);
      return;
    }

    const parsedRequest = parseRuntimeRequest(parsedJson, this.#bootId);
    if (!parsedRequest.ok) {
      this.#sendProtocolError(session, parsedRequest.error);
      return;
    }

    const request = parsedRequest.request;
    const requests = this.#inFlightRequests.get(session);
    if (requests === undefined || session.isClosed) {
      return;
    }
    if (requests.has(request.id)) {
      this.#sendProtocolError(
        session,
        this.#requestError(
          request,
          "invalid_request",
          "A Runtime request id may only be in flight once.",
        ),
      );
      return;
    }
    if (requests.size >= MAX_INFLIGHT_REQUESTS_PER_CONNECTION) {
      this.#sendProtocolError(
        session,
        this.#requestError(
          request,
          "overloaded",
          "The Runtime control plane is at its in-flight request limit.",
        ),
      );
      return;
    }

    const cancellation = new AbortController();
    requests.set(request.id, cancellation);
    void this.#dispatchAsync(session, request, cancellation);
  }

  async #dispatchAsync(
    session: ServerWebSocketSession,
    request: RuntimeRequest,
    cancellation: AbortController,
  ): Promise<void> {
    // Yield before dispatch so parsing can keep accepting independent control
    // frames instead of a request-response lock serializing the connection.
    await Promise.resolve();
    if (cancellation.signal.aborted || session.isClosed) {
      return;
    }

    let result: RuntimeDispatchResult;
    try {
      result = await this.#dispatch(request, cancellation.signal);
    } catch {
      result = {
        error: this.#requestError(
          request,
          "internal",
          "The Runtime could not complete the control request.",
        ),
      };
    }

    const requests = this.#inFlightRequests.get(session);
    if (requests?.get(request.id) !== cancellation) {
      return;
    }
    requests.delete(request.id);
    if (cancellation.signal.aborted || session.isClosed) {
      return;
    }

    if ("error" in result) {
      this.#sendProtocolError(session, result.error);
      return;
    }
    this.#sendJson(session, makeResponse(this.#bootId, request, result.result));
  }

  /**
   * Dispatches M1.2 bootstrap calls plus the explicitly enabled M1.3 fixture.
   *
   * Future Runtime-owned capabilities extend this switch; they must preserve
   * deadline/cancellation checks and return JSON-compatible data rather than
   * creating an app-to-plugin callback or alternate transport path.
   */
  async #dispatch(
    request: RuntimeRequest,
    cancellation: AbortSignal,
  ): Promise<RuntimeDispatchResult> {
    if (cancellation.aborted) {
      return {
        error: this.#requestError(
          request,
          "cancelled",
          "The Runtime request was cancelled.",
        ),
      };
    }
    if (Number(request.deadlineUnixMs) <= Date.now()) {
      return {
        error: this.#requestError(
          request,
          "timeout",
          "The Runtime request deadline has elapsed.",
        ),
      };
    }
    switch (request.method) {
      case RUNTIME_CONTROL_METHOD.hello: {
        const hello: RuntimeHelloResponse = {
          bootId: this.#bootId,
          capabilities: this.#runtimeControlCapabilities,
          maxFrameBytes: maxWebSocketControlFrameBytes,
          maxInlineBytes: MAX_INLINE_BYTES,
          maxInFlightRequests: MAX_INFLIGHT_REQUESTS_PER_CONNECTION,
          maxOutboundQueueBytes: maxWebSocketOutboundQueueBytes,
          nodeVersion: process.versions.node,
          protocolVersion,
          runtimeVersion,
          supportsCancellation: true,
        };
        return {
          result: hello,
        };
      }
      case RUNTIME_CONTROL_METHOD.ping: {
        const ping: RuntimePingResponse = {
          bootId: this.#bootId,
          nodeVersion: process.versions.node,
          ok: true,
          runtimeVersion,
        };
        return {
          result: ping,
        };
      }
      case RUNTIME_CONTROL_METHOD.pluginsList: {
        if (Object.keys(request.params).length !== 0) {
          return {
            error: this.#requestError(
              request,
              "invalid_request",
              "The installed-plugin query accepts no parameters.",
            ),
          };
        }
        const plugins = await this.#pluginManager?.listInstalled();
        return { result: plugins ?? [] };
      }
      case RUNTIME_CONTROL_METHOD.pluginSearch:
        return this.#dispatchPluginSearch(request, cancellation);
      case RUNTIME_CONTROL_METHOD.shutdown:
        if (
          request.idempotencyKey === undefined ||
          request.idempotencyKey === null ||
          request.idempotencyKey.length === 0
        ) {
          return {
            error: this.#requestError(
              request,
              "invalid_request",
              "Runtime shutdown requires an idempotency key.",
            ),
          };
        }

        setImmediate(() => {
          void this.stop().catch(() => {
            // Shutdown failures cannot be sent after the transport closes.
          });
        });
        return { result: { accepted: true } satisfies RuntimeShutdownResponse };
      default:
        return {
          error: this.#requestError(
            request,
            "method_not_found",
            "The Runtime method is not implemented.",
          ),
        };
    }
  }

  /** Returns the versioned product capability list negotiated by the Facade. */
  get #runtimeControlCapabilities(): readonly string[] {
    return RUNTIME_CONTROL_CAPABILITIES;
  }

  /**
   * Invokes one standard Node plugin named export through a bounded v1 schema.
   */
  async #dispatchPluginSearch(
    request: RuntimeRequest,
    cancellation: AbortSignal,
  ): Promise<RuntimeDispatchResult> {
    const pluginId = request.params.pluginId;
    const keyword = request.params.keyword;
    if (typeof pluginId !== "string" || typeof keyword !== "string") {
      return {
        error: this.#requestError(
          request,
          "invalid_request",
          "The plugin search request is invalid.",
        ),
      };
    }
    try {
      const result = await this.#pluginManager?.search(
        pluginId,
        keyword,
        cancellation,
        request.deadlineUnixMs,
      );
      if (result === undefined) {
        throw new PluginManagerError("plugin_load_failed");
      }
      return { result: result };
    } catch (error) {
      if (error instanceof PluginManagerError) {
        return {
          error: this.#requestError(
            request,
            error.code,
            pluginManagerErrorMessage(error.code),
          ),
        };
      }
      if (cancellation.aborted) {
        return {
          error: this.#requestError(
            request,
            "cancelled",
            "The plugin request was cancelled.",
          ),
        };
      }
      if (Number(request.deadlineUnixMs) <= Date.now()) {
        return {
          error: this.#requestError(
            request,
            "timeout",
            "The plugin request deadline has elapsed.",
          ),
        };
      }
      return {
        error: this.#requestError(
          request,
          "internal",
          "The plugin request could not be completed.",
        ),
      };
    }
  }

  /** Writes a minimal HTTP rejection before destroying an invalid upgrade. */
  #rejectUpgrade(socket: Duplex, status: number, message: string): void {
    socket.write(
      [
        `HTTP/1.1 ${status} Bad Request`,
        "Connection: close",
        "Content-Type: text/plain; charset=utf-8",
        `Content-Length: ${Buffer.byteLength(message)}`,
        "",
        message,
      ].join("\r\n"),
    );
    socket.destroy();
  }

  /** Serializes a known JSON-safe envelope within the session's frame budget. */
  #sendJson(session: ServerWebSocketSession, value: JsonObject): void {
    try {
      session.sendText(JSON.stringify(value));
    } catch {
      session.close(1011, "Runtime could not encode a control response.");
    }
  }

  /** Sends a correlated error, or closes if the envelope had no safe identity. */
  #sendProtocolError(
    session: ServerWebSocketSession,
    error: RuntimeProtocolError,
  ): void {
    const response = makeError(this.#bootId, error);
    if (response === undefined) {
      session.close(1002, "Runtime request envelope is invalid.");
      return;
    }
    this.#sendJson(session, response);
  }

  /** Cancels only the target request owned by the same WebSocket session. */
  #cancelRequest(session: ServerWebSocketSession, targetId: string): void {
    const requests = this.#inFlightRequests.get(session);
    const cancellation = requests?.get(targetId);
    if (cancellation === undefined) {
      return;
    }
    requests?.delete(targetId);
    cancellation.abort();
  }

  /** Releases all cancellation state when one session closes. */
  #abortSessionRequests(session: ServerWebSocketSession): void {
    const requests = this.#inFlightRequests.get(session);
    this.#inFlightRequests.delete(session);
    if (requests === undefined) {
      return;
    }
    for (const cancellation of requests.values()) {
      cancellation.abort();
    }
    requests.clear();
  }

  /** Releases every request before the server listener is closed. */
  #abortAllInFlightRequests(): void {
    for (const session of this.#inFlightRequests.keys()) {
      this.#abortSessionRequests(session);
    }
  }

  /** Creates an error tied to a request that was already fully validated. */
  #requestError(
    request: RuntimeRequest,
    code: RuntimeErrorCode,
    message: string,
  ): RuntimeProtocolError {
    return {
      code,
      message,
      requestId: request.id,
      traceId: request.traceId,
    };
  }

  /** Writes a no-store HTTP JSON response without accepting request bodies. */
  #writeJson(response: ServerResponse, status: number, body: JsonObject): void {
    const payload = JSON.stringify(body);
    response.writeHead(status, {
      "Cache-Control": "no-store",
      "Content-Length": Buffer.byteLength(payload),
      "Content-Type": "application/json; charset=utf-8",
    });
    response.end(payload);
  }
}

/** Emits only stable plugin lifecycle codes; plugin log text is discarded. */
function emitPluginManagerDiagnostic(event: PluginManagerEvent): void {
  const messages: Record<PluginManagerEvent["code"], string> = {
    plugin_invocation_completed: "A plugin capability completed successfully.",
    plugin_invocation_failed: "A plugin capability failed.",
    plugin_invocation_started: "A plugin capability started.",
    plugin_load_completed: "A standard Node plugin loaded successfully.",
    plugin_load_failed: "A standard Node plugin could not be loaded.",
    plugin_load_started: "A standard Node plugin load started.",
    plugin_log_emitted: "A plugin emitted a redacted diagnostic event.",
    plugin_uninstall_completed: "A pending plugin uninstall completed.",
  };
  emitRuntimeDiagnostic({
    code: event.code,
    component: "runtime.plugin",
    ...(event.durationMs === undefined
      ? {}
      : { durationMicros: Math.max(0, Math.round(event.durationMs * 1_000)) }),
    level: event.outcome === "error" ? "error" : "info",
    message: messages[event.code],
    outcome: event.outcome,
    type: "diagnostic",
  });
}

/** Maps internal plugin errors to reviewed wire text. */
function pluginManagerErrorMessage(code: PluginManagerError["code"]): string {
  switch (code) {
    case "cancelled":
      return "The plugin request was cancelled.";
    case "invalid_request":
      return "The plugin request is invalid.";
    case "plugin_disabled":
      return "The requested plugin is disabled.";
    case "plugin_invalid_response":
      return "The plugin returned an invalid response.";
    case "plugin_load_failed":
      return "The plugin does not provide the requested capability.";
    case "plugin_not_found":
      return "The requested plugin is not installed or active.";
    case "timeout":
      return "The plugin request deadline has elapsed.";
  }
}
