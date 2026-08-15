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
import {
  runtimeDiagnosticValue,
  type RuntimeDiagnosticDetailStorage,
  type RuntimeDiagnosticEvent,
  type RuntimeDiagnosticOutcome,
  type RuntimeDiagnosticPage,
  type RuntimeDiagnosticPayloadKind,
  type RuntimeDiagnosticSessionState,
  type RuntimeDiagnosticSeverity,
  type RuntimeDiagnosticTraceContext,
} from "./diagnostics/contracts.js";
import { RuntimeDiagnosticsHttpClient } from "./diagnostics/http.js";
import {
  type RuntimeDiagnosticSpan,
} from "./diagnostics/manager.js";
import { fingerprintRuntimeStack } from "./diagnostics/privacy.js";
import { runtimeDiagnosticEvents } from "./diagnostics/registry.js";
import { RuntimeDiagnosticsService } from "./diagnostics/service.js";
import { RuntimeDiagnosticsError } from "./diagnostics/service.js";
import {
  parseChaptersParams,
  parseContentParams,
  parseDetailParams,
  parseDiscoverParams,
  parseSearchParams,
  pluginContentResultCount,
  PluginContentValidationError,
  type PluginContentOperation,
} from "./plugin-content.js";

const LOOPBACK_HOST = "127.0.0.1";
const MAX_INLINE_BYTES = maxWebSocketControlFrameBytes;
const MAX_INFLIGHT_REQUESTS_PER_CONNECTION = 256;
const RUNTIME_CONTROL_METHOD = Object.freeze({
  diagnosticsAttachmentRead: "diagnostics.attachment.read.v1",
  diagnosticsAttachmentsList: "diagnostics.attachments.list.v1",
  diagnosticsCaptureStart: "diagnostics.capture.start.v1",
  diagnosticsCaptureStop: "diagnostics.capture.stop.v1",
  diagnosticsEventGet: "diagnostics.event.get.v1",
  diagnosticsEventsList: "diagnostics.events.list.v1",
  diagnosticsRetentionEnforce: "diagnostics.retention.enforce.v1",
  diagnosticsSessionDelete: "diagnostics.session.delete.v1",
  diagnosticsSessionsList: "diagnostics.sessions.list.v1",
  diagnosticsStatisticsGet: "diagnostics.statistics.get.v1",
  hello: "runtime.hello",
  ping: "runtime.ping",
  pluginsList: "plugins.list.v1",
  sourceDiscover: "source.discover.v1",
  sourceSearch: "source.search.v1",
  sourceGetDetail: "source.getDetail.v1",
  sourceGetChapters: "source.getChapters.v1",
  sourceGetContent: "source.getContent.v1",
  shutdown: "runtime.shutdown",
} as const);
const RUNTIME_CONTROL_CAPABILITIES = Object.freeze([
  RUNTIME_CONTROL_METHOD.diagnosticsSessionsList,
  RUNTIME_CONTROL_METHOD.diagnosticsEventsList,
  RUNTIME_CONTROL_METHOD.diagnosticsEventGet,
  RUNTIME_CONTROL_METHOD.diagnosticsAttachmentsList,
  RUNTIME_CONTROL_METHOD.diagnosticsAttachmentRead,
  RUNTIME_CONTROL_METHOD.diagnosticsCaptureStart,
  RUNTIME_CONTROL_METHOD.diagnosticsCaptureStop,
  RUNTIME_CONTROL_METHOD.diagnosticsSessionDelete,
  RUNTIME_CONTROL_METHOD.diagnosticsRetentionEnforce,
  RUNTIME_CONTROL_METHOD.diagnosticsStatisticsGet,
  RUNTIME_CONTROL_METHOD.ping,
  RUNTIME_CONTROL_METHOD.pluginsList,
  RUNTIME_CONTROL_METHOD.sourceDiscover,
  RUNTIME_CONTROL_METHOD.sourceSearch,
  RUNTIME_CONTROL_METHOD.sourceGetDetail,
  RUNTIME_CONTROL_METHOD.sourceGetChapters,
  RUNTIME_CONTROL_METHOD.sourceGetContent,
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
  Map<string, RuntimeInFlightRequest>
>;

interface RuntimeInFlightRequest {
  readonly cancellation: AbortController;
  readonly enqueuedAt: bigint;
  readonly method: string;
  readonly requestBytes: number;
  readonly span?: RuntimeDiagnosticSpan;
}

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
  #diagnostics: RuntimeDiagnosticsService | undefined;
  readonly #webSocketSpans = new Map<ServerWebSocketSession, RuntimeDiagnosticSpan>();

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

    try {
      this.#diagnostics = await RuntimeDiagnosticsService.open({
        dataRoot: this.#dataRoot,
      });
    } catch {
      emitRuntimeDiagnostic({
        code: "runtime_diagnostics_store_failed",
        level: "warning",
        message: "The Runtime diagnostics store is unavailable; Runtime operation will continue.",
        type: "diagnostic",
      });
    }
    const lifecycleSpan = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        platform: runtimeDiagnosticValue.string(process.platform),
        stage: runtimeDiagnosticValue.string("starting"),
      }),
      definition: runtimeDiagnosticEvents.lifecycle,
    });

    const pluginLoadSpan = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        operation: runtimeDiagnosticValue.string("coldInitialize"),
      }),
      definition: runtimeDiagnosticEvents.pluginLoad,
      ...(lifecycleSpan === undefined ? {} : { parent: lifecycleSpan.trace }),
    });
    const pluginManager = new PluginManager(this.#dataRoot, {
      events: emitPluginManagerDiagnostic,
      ...(this.#diagnostics === undefined
        ? {}
        : { http: new RuntimeDiagnosticsHttpClient(this.#diagnostics) }),
    });
    try {
      await pluginManager.initialize();
      const plugins = await pluginManager.listInstalled();
      pluginLoadSpan?.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          operation: runtimeDiagnosticValue.string("coldInitialize"),
          pluginCount: runtimeDiagnosticValue.int64(BigInt(plugins.length)),
        }),
      });
    } catch (error) {
      pluginLoadSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("plugin_initialize_failed"),
          operation: runtimeDiagnosticValue.string("coldInitialize"),
        }),
        severity: "error",
      });
      lifecycleSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("plugin_initialize_failed"),
          stage: runtimeDiagnosticValue.string("pluginInitialize"),
        }),
        severity: "error",
      });
      await this.#diagnostics?.manager.flush();
      throw error;
    }
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
      lifecycleSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("loopback_bind_failed"),
          stage: runtimeDiagnosticValue.string("loopbackBind"),
        }),
        severity: "error",
      });
      await this.#diagnostics?.manager.flush();
      throw error;
    }

    const address = server.address();
    if (address === null || typeof address === "string") {
      lifecycleSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("loopback_address_invalid"),
          stage: runtimeDiagnosticValue.string("ready"),
        }),
        severity: "error",
      });
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
    lifecycleSpan?.end("success", {
      attributes: () => runtimeDiagnosticValue.object({
        platform: runtimeDiagnosticValue.string(process.platform),
        stage: runtimeDiagnosticValue.string("ready"),
      }),
    });
    return ready;
  }

  /** Performs ordered shutdown so handlers cannot outlive their transport. */
  async #stop(): Promise<void> {
    const server = this.#server;
    const diagnostics = this.#diagnostics;
    const shutdownSpan = diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        stage: runtimeDiagnosticValue.string("shutdown"),
      }),
      definition: runtimeDiagnosticEvents.lifecycle,
    });
    try {
      if (server !== undefined) {
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
      shutdownSpan?.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          stage: runtimeDiagnosticValue.string("stopped"),
        }),
      });
    } catch (error) {
      shutdownSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("shutdown_failed"),
          stage: runtimeDiagnosticValue.string("shutdown"),
        }),
        severity: "error",
      });
      throw error;
    } finally {
      await diagnostics?.close();
      this.#diagnostics = undefined;
    }
  }

  /** Persists only a fingerprint and stable code before fatal cleanup. */
  async recordFatal(errorCode: string, failure: unknown): Promise<void> {
    const diagnostics = this.#diagnostics;
    diagnostics?.manager.emit({
      attributes: () => runtimeDiagnosticValue.object({
        errorCode: runtimeDiagnosticValue.string(errorCode),
        recovery: runtimeDiagnosticValue.string("shutdown"),
        stackFingerprint: runtimeDiagnosticValue.string(
          fingerprintRuntimeStack(failure),
        ),
        stage: runtimeDiagnosticValue.string("uncaughtBoundary"),
      }),
      definition: runtimeDiagnosticEvents.fatal,
      severity: "fatal",
    });
    await diagnostics?.manager.flush();
  }

  /** Serves no-store liveness/readiness checks on the Runtime loopback plane. */
  #handleHttp(request: IncomingMessage, response: ServerResponse): void {
    const url = new URL(request.url ?? "/", `http://${LOOPBACK_HOST}`);
    const route = internalHttpRoute(url.pathname);
    const method = stableHttpMethod(request.method);
    const span = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        method: runtimeDiagnosticValue.string(method),
        origin: runtimeDiagnosticValue.string("http://loopback"),
        route: runtimeDiagnosticValue.string(route),
      }),
      definition: runtimeDiagnosticEvents.http,
    });
    const finish = (statusCode: number): void => {
      span?.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          bodyMicros: runtimeDiagnosticValue.int64(0n),
          downloadBytes: runtimeDiagnosticValue.int64(0n),
          method: runtimeDiagnosticValue.string(method),
          origin: runtimeDiagnosticValue.string("http://loopback"),
          redirectCount: runtimeDiagnosticValue.int64(0n),
          route: runtimeDiagnosticValue.string(route),
          statusCode: runtimeDiagnosticValue.int64(BigInt(statusCode)),
          ttfbMicros: runtimeDiagnosticValue.int64(0n),
        }),
      });
    };
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      response.end();
      finish(405);
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
      finish(200);
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
      finish(200);
      return;
    }

    this.#writeJson(response, 404, { code: "not_found" });
    finish(404);
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
    const upgradeSpan = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        operation: runtimeDiagnosticValue.string("upgrade"),
      }),
      definition: runtimeDiagnosticEvents.websocket,
    });

    if (
      url.pathname !== RUNTIME_RPC_PATH ||
      typeof key !== "string" ||
      upgrade?.toLowerCase() !== "websocket"
    ) {
      upgradeSpan?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("upgrade_invalid"),
          operation: runtimeDiagnosticValue.string("upgrade"),
        }),
        severity: "warn",
      });
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
    let sessionSpan: RuntimeDiagnosticSpan | undefined;
    session = new ServerWebSocketSession(socket, {
      onClosed: () => {
        if (session !== undefined) {
          this.#sessions.delete(session);
          this.#abortSessionRequests(session);
          if (sessionSpan !== undefined && !sessionSpan.isEnded) {
            sessionSpan.end("success", {
              attributes: () => runtimeDiagnosticValue.object({
                operation: runtimeDiagnosticValue.string("session"),
              }),
            });
          }
          this.#webSocketSpans.delete(session);
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
    upgradeSpan?.end("success", {
      attributes: () => runtimeDiagnosticValue.object({
        operation: runtimeDiagnosticValue.string("upgrade"),
      }),
    });
    sessionSpan = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        operation: runtimeDiagnosticValue.string("session"),
      }),
      definition: runtimeDiagnosticEvents.websocket,
    });
    if (sessionSpan !== undefined) this.#webSocketSpans.set(session, sessionSpan);

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
    const method = diagnosticControlMethod(request.method);
    const requestBytes = Buffer.byteLength(text, "utf8");
    const span = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        method: runtimeDiagnosticValue.string(method),
        queueDepth: runtimeDiagnosticValue.int64(BigInt(requests.size)),
        requestBytes: runtimeDiagnosticValue.int64(BigInt(requestBytes)),
      }),
      definition: runtimeDiagnosticEvents.control,
      traceId: normalizeDiagnosticTraceId(request.traceId),
    });
    if (requests.has(request.id)) {
      span?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("duplicate_request"),
          method: runtimeDiagnosticValue.string(method),
          requestBytes: runtimeDiagnosticValue.int64(BigInt(requestBytes)),
        }),
        severity: "warn",
      });
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
      span?.end("overloaded", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("inflight_limit"),
          method: runtimeDiagnosticValue.string(method),
          queueDepth: runtimeDiagnosticValue.int64(BigInt(requests.size)),
          requestBytes: runtimeDiagnosticValue.int64(BigInt(requestBytes)),
        }),
        severity: "warn",
      });
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
    const inFlight = Object.freeze({
      cancellation,
      enqueuedAt: process.hrtime.bigint(),
      method,
      requestBytes,
      ...(span === undefined ? {} : { span }),
    });
    requests.set(request.id, inFlight);
    void this.#dispatchAsync(session, request, inFlight);
  }

  async #dispatchAsync(
    session: ServerWebSocketSession,
    request: RuntimeRequest,
    inFlight: RuntimeInFlightRequest,
  ): Promise<void> {
    // Yield before dispatch so parsing can keep accepting independent control
    // frames instead of a request-response lock serializing the connection.
    await Promise.resolve();
    if (inFlight.cancellation.signal.aborted || session.isClosed) {
      this.#finishControlSpan(inFlight, request, "cancelled", "cancelled");
      return;
    }

    let result: RuntimeDispatchResult;
    try {
      result = await this.#dispatch(
        request,
        inFlight.cancellation.signal,
        inFlight.span?.trace,
      );
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
    if (requests?.get(request.id) !== inFlight) {
      return;
    }
    requests.delete(request.id);
    if (inFlight.cancellation.signal.aborted || session.isClosed) {
      this.#finishControlSpan(inFlight, request, "cancelled", "cancelled");
      return;
    }

    if ("error" in result) {
      this.#finishControlSpan(
        inFlight,
        request,
        controlOutcome(result.error.code),
        result.error.code,
      );
      this.#sendProtocolError(session, result.error);
      return;
    }
    this.#finishControlSpan(
      inFlight,
      request,
      "success",
      undefined,
      Buffer.byteLength(JSON.stringify(result.result), "utf8"),
    );
    this.#sendJson(session, makeResponse(this.#bootId, request, result.result));
  }

  /**
   * Dispatches bootstrap and standard-plugin capabilities owned by Core.
   *
   * Future Runtime-owned capabilities extend this switch; they must preserve
   * deadline/cancellation checks and return JSON-compatible data rather than
   * creating an app-to-plugin callback or alternate transport path.
   */
  async #dispatch(
    request: RuntimeRequest,
    cancellation: AbortSignal,
    controlTrace?: RuntimeDiagnosticTraceContext,
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
      case RUNTIME_CONTROL_METHOD.sourceDiscover:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "discover",
          controlTrace,
        );
      case RUNTIME_CONTROL_METHOD.sourceSearch:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "search",
          controlTrace,
        );
      case RUNTIME_CONTROL_METHOD.sourceGetDetail:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "getDetail",
          controlTrace,
        );
      case RUNTIME_CONTROL_METHOD.sourceGetChapters:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "getChapters",
          controlTrace,
        );
      case RUNTIME_CONTROL_METHOD.sourceGetContent:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "getContent",
          controlTrace,
        );
      case RUNTIME_CONTROL_METHOD.diagnosticsSessionsList:
      case RUNTIME_CONTROL_METHOD.diagnosticsEventsList:
      case RUNTIME_CONTROL_METHOD.diagnosticsEventGet:
      case RUNTIME_CONTROL_METHOD.diagnosticsAttachmentsList:
      case RUNTIME_CONTROL_METHOD.diagnosticsAttachmentRead:
      case RUNTIME_CONTROL_METHOD.diagnosticsCaptureStart:
      case RUNTIME_CONTROL_METHOD.diagnosticsCaptureStop:
      case RUNTIME_CONTROL_METHOD.diagnosticsSessionDelete:
      case RUNTIME_CONTROL_METHOD.diagnosticsRetentionEnforce:
      case RUNTIME_CONTROL_METHOD.diagnosticsStatisticsGet:
        return this.#dispatchDiagnostics(request);
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

  /** Versioned, bounded diagnostics query/capture Facade implementation. */
  async #dispatchDiagnostics(request: RuntimeRequest): Promise<RuntimeDispatchResult> {
    const diagnostics = this.#diagnostics;
    if (diagnostics === undefined) {
      return {
        error: this.#requestError(
          request,
          "diagnostics_unavailable",
          "Runtime diagnostics are currently unavailable.",
        ),
      };
    }
    try {
      switch (request.method) {
        case RUNTIME_CONTROL_METHOD.diagnosticsSessionsList: {
          if (!hasOnlyKeys(request.params, ["cursor", "limit", "states"])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const limit = readPageLimit(request.params.limit, 100);
          const states = readEnumSet(
            request.params.states,
            runtimeDiagnosticSessionStates,
            16,
          );
          const cursor = readOptionalCursor(request.params.cursor);
          const page = await diagnostics.listSessions(
            states === undefined ? {} : { states },
            cursor,
            limit,
          );
          return { result: toJsonValue(page) };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsEventsList: {
          if (!hasOnlyKeys(request.params, [
            "components",
            "cursor",
            "eventNames",
            "limit",
            "minimumSeverity",
            "occurredAfterUtcMicros",
            "occurredBeforeUtcMicros",
            "sessionId",
            "traceId",
          ])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const limit = Math.min(readPageLimit(request.params.limit, 20), 20);
          const components = readStringSet(request.params.components, 32);
          const eventNames = readStringSet(request.params.eventNames, 32);
          const minimumSeverity = readOptionalEnum(
            request.params.minimumSeverity,
            runtimeDiagnosticSeverities,
          );
          const filter = {
            ...(components === undefined ? {} : { components }),
            ...(eventNames === undefined ? {} : { eventNames }),
            ...(minimumSeverity === undefined ? {} : { minimumSeverity }),
            ...(readOptionalSafeInteger(request.params.occurredAfterUtcMicros) === undefined
              ? {}
              : { occurredAfterUtcMicros: readOptionalSafeInteger(request.params.occurredAfterUtcMicros)! }),
            ...(readOptionalSafeInteger(request.params.occurredBeforeUtcMicros) === undefined
              ? {}
              : { occurredBeforeUtcMicros: readOptionalSafeInteger(request.params.occurredBeforeUtcMicros)! }),
            ...(readOptionalOpaqueId(request.params.sessionId) === undefined
              ? {}
              : { sessionId: readOptionalOpaqueId(request.params.sessionId)! }),
            ...(readOptionalOpaqueId(request.params.traceId) === undefined
              ? {}
              : { traceId: readOptionalOpaqueId(request.params.traceId)! }),
          };
          const page = await diagnostics.listEvents(
            filter,
            readOptionalCursor(request.params.cursor),
            limit,
          );
          return { result: toJsonValue(compactEventPage(page)) };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsEventGet: {
          if (!hasOnlyKeys(request.params, ["eventId"])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const eventId = readRequiredOpaqueId(request.params.eventId);
          return { result: toJsonValue((await diagnostics.getEvent(eventId)) ?? null) };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsAttachmentsList: {
          if (!hasOnlyKeys(request.params, ["eventId"])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const attachments = await diagnostics.listAttachments(
            readRequiredOpaqueId(request.params.eventId),
          );
          return { result: toJsonValue(attachments.slice(0, 64)) };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsAttachmentRead: {
          if (!hasOnlyKeys(request.params, ["attachmentId", "length", "offset"])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const length = readRequiredSafeInteger(request.params.length);
          const offset = readRequiredSafeInteger(request.params.offset);
          if (length <= 0 || length > 32 * 1024 || offset < 0) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const chunk = await diagnostics.readAttachment(
            readRequiredOpaqueId(request.params.attachmentId),
            { length, offset },
          );
          return { result: toJsonValue(chunk) };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsCaptureStart: {
          if (!hasOnlyKeys(request.params, [
            "components",
            "detailStorage",
            "durationMillis",
            "maxStoredBytes",
            "origins",
            "payloadKind",
          ])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const payloadKind = readOptionalEnum(
            request.params.payloadKind,
            runtimeDiagnosticPayloadKinds,
          );
          if (payloadKind === undefined) return this.#invalidDiagnosticsRequest(request);
          const detailStorage = request.params.detailStorage === undefined
            ? "persistToText"
            : readOptionalEnum(request.params.detailStorage, runtimeDiagnosticDetailStorage);
          if (detailStorage === undefined) return this.#invalidDiagnosticsRequest(request);
          const durationMillis = readRequiredSafeInteger(request.params.durationMillis);
          const maxStoredBytes = readRequiredSafeInteger(request.params.maxStoredBytes);
          if (
            durationMillis <= 0 || durationMillis > 60 * 60 * 1_000 ||
            maxStoredBytes <= 0 || maxStoredBytes > 256 * 1024 * 1024
          ) {
            return this.#invalidDiagnosticsRequest(request);
          }
          const session = await diagnostics.startCapture({
            components: readStringSet(request.params.components, 32) ?? new Set(),
            detailStorage,
            durationMillis,
            maxStoredBytes,
            origins: readOriginSet(request.params.origins, 32),
            payloadKind,
          });
          return { result: toJsonValue(session) };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsCaptureStop: {
          if (!hasOnlyKeys(request.params, ["sessionId"])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          await diagnostics.stopCapture(readRequiredOpaqueId(request.params.sessionId));
          return { result: { stopped: true } };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsSessionDelete: {
          if (!hasOnlyKeys(request.params, ["sessionId"])) {
            return this.#invalidDiagnosticsRequest(request);
          }
          return {
            result: toJsonValue(
              await diagnostics.deleteSession(readRequiredOpaqueId(request.params.sessionId)),
            ),
          };
        }
        case RUNTIME_CONTROL_METHOD.diagnosticsRetentionEnforce:
          if (Object.keys(request.params).length !== 0) {
            return this.#invalidDiagnosticsRequest(request);
          }
          return { result: toJsonValue(await diagnostics.enforceRetention()) };
        case RUNTIME_CONTROL_METHOD.diagnosticsStatisticsGet:
          if (Object.keys(request.params).length !== 0) {
            return this.#invalidDiagnosticsRequest(request);
          }
          return { result: toJsonValue(await diagnostics.getStorageStatistics()) };
      }
    } catch (error) {
      if (
        error instanceof RuntimeDiagnosticsError &&
        error.code === "capture_mode_unsupported"
      ) {
        return {
          error: this.#requestError(
            request,
            "capture_mode_unsupported",
            "Restricted raw capture is unavailable until its security gate is implemented.",
          ),
        };
      }
      if (error instanceof TypeError || error instanceof RangeError) {
        return this.#invalidDiagnosticsRequest(request);
      }
      return {
        error: this.#requestError(
          request,
          "internal",
          "The Runtime diagnostics operation could not be completed.",
        ),
      };
    }
    return this.#invalidDiagnosticsRequest(request);
  }

  #invalidDiagnosticsRequest(request: RuntimeRequest): RuntimeDispatchFailure {
    return {
      error: this.#requestError(
        request,
        "invalid_request",
        "The Runtime diagnostics request is invalid.",
      ),
    };
  }

  /**
   * Invokes one standard Node plugin named export through a bounded v1 schema.
   */
  async #dispatchPluginContent(
    request: RuntimeRequest,
    cancellation: AbortSignal,
    operation: PluginContentOperation,
    controlTrace?: RuntimeDiagnosticTraceContext,
  ): Promise<RuntimeDispatchResult> {
    const span = this.#diagnostics?.manager.startSpan({
      attributes: () => runtimeDiagnosticValue.object({
        operation: runtimeDiagnosticValue.string(operation),
      }),
      definition: runtimeDiagnosticEvents.pluginInvoke,
      ...(controlTrace === undefined ? {} : { parent: controlTrace }),
    });
    try {
      const manager = this.#pluginManager;
      if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
      let result: JsonObject;
      switch (operation) {
        case "discover": {
          const parsed = parseDiscoverParams(request.params);
          result = await manager.discover(
            parsed.pluginId,
            parsed.request,
            cancellation,
            request.deadlineUnixMs,
            span?.trace,
          );
          break;
        }
        case "search": {
          const parsed = parseSearchParams(request.params);
          result = await manager.search(
            parsed.pluginId,
            parsed.request,
            cancellation,
            request.deadlineUnixMs,
            span?.trace,
          );
          break;
        }
        case "getDetail": {
          const parsed = parseDetailParams(request.params);
          result = await manager.getDetail(
            parsed.pluginId,
            parsed.request,
            cancellation,
            request.deadlineUnixMs,
            span?.trace,
          );
          break;
        }
        case "getChapters": {
          const parsed = parseChaptersParams(request.params);
          result = await manager.getChapters(
            parsed.pluginId,
            parsed.request,
            cancellation,
            request.deadlineUnixMs,
            span?.trace,
          );
          break;
        }
        case "getContent": {
          const parsed = parseContentParams(request.params);
          result = await manager.getContent(
            parsed.pluginId,
            parsed.request,
            cancellation,
            request.deadlineUnixMs,
            span?.trace,
          );
          break;
        }
      }
      span?.end("success", {
        attributes: () => runtimeDiagnosticValue.object({
          operation: runtimeDiagnosticValue.string(operation),
          resultBytes: runtimeDiagnosticValue.int64(
            BigInt(Buffer.byteLength(JSON.stringify(result), "utf8")),
          ),
          resultCount: runtimeDiagnosticValue.int64(
            BigInt(pluginContentResultCount(result)),
          ),
        }),
      });
      return { result: result };
    } catch (error) {
      if (error instanceof PluginContentValidationError) {
        span?.end("error", {
          attributes: () => runtimeDiagnosticValue.object({
            errorCode: runtimeDiagnosticValue.string("invalid_request"),
            operation: runtimeDiagnosticValue.string(operation),
          }),
          severity: "warn",
        });
        return {
          error: this.#requestError(
            request,
            "invalid_request",
            "The source capability request is invalid.",
          ),
        };
      }
      if (error instanceof PluginManagerError) {
        span?.end(controlOutcome(error.code), {
          attributes: () => runtimeDiagnosticValue.object({
            errorCode: runtimeDiagnosticValue.string(error.code),
            operation: runtimeDiagnosticValue.string(operation),
          }),
          severity: error.code === "cancelled" ? "info" : "warn",
        });
        return {
          error: this.#requestError(
            request,
            error.code,
            pluginManagerErrorMessage(error.code),
          ),
        };
      }
      if (cancellation.aborted) {
        span?.end("cancelled", {
          attributes: () => runtimeDiagnosticValue.object({
            errorCode: runtimeDiagnosticValue.string("cancelled"),
            operation: runtimeDiagnosticValue.string(operation),
          }),
          severity: "info",
        });
        return {
          error: this.#requestError(
            request,
            "cancelled",
            "The plugin request was cancelled.",
          ),
        };
      }
      if (Number(request.deadlineUnixMs) <= Date.now()) {
        span?.end("timeout", {
          attributes: () => runtimeDiagnosticValue.object({
            errorCode: runtimeDiagnosticValue.string("timeout"),
            operation: runtimeDiagnosticValue.string(operation),
          }),
          severity: "warn",
        });
        return {
          error: this.#requestError(
            request,
            "timeout",
            "The plugin request deadline has elapsed.",
          ),
        };
      }
      span?.end("error", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("internal"),
          operation: runtimeDiagnosticValue.string(operation),
        }),
        severity: "error",
      });
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
    const inFlight = requests?.get(targetId);
    if (inFlight === undefined) {
      return;
    }
    requests?.delete(targetId);
    inFlight.cancellation.abort();
    if (inFlight.span !== undefined && !inFlight.span.isEnded) {
      inFlight.span.end("cancelled", {
        attributes: () => runtimeDiagnosticValue.object({
          errorCode: runtimeDiagnosticValue.string("cancelled"),
          method: runtimeDiagnosticValue.string(inFlight.method),
          queueWaitMicros: runtimeDiagnosticValue.int64(
            BigInt(elapsedMicros(inFlight.enqueuedAt)),
          ),
          requestBytes: runtimeDiagnosticValue.int64(BigInt(inFlight.requestBytes)),
        }),
        severity: "info",
      });
    }
  }

  /** Releases all cancellation state when one session closes. */
  #abortSessionRequests(session: ServerWebSocketSession): void {
    const requests = this.#inFlightRequests.get(session);
    this.#inFlightRequests.delete(session);
    if (requests === undefined) {
      return;
    }
    for (const inFlight of requests.values()) {
      inFlight.cancellation.abort();
      if (inFlight.span !== undefined && !inFlight.span.isEnded) {
        inFlight.span.end("cancelled", {
          attributes: () => runtimeDiagnosticValue.object({
            errorCode: runtimeDiagnosticValue.string("session_closed"),
            method: runtimeDiagnosticValue.string(inFlight.method),
            queueWaitMicros: runtimeDiagnosticValue.int64(
              BigInt(elapsedMicros(inFlight.enqueuedAt)),
            ),
            requestBytes: runtimeDiagnosticValue.int64(BigInt(inFlight.requestBytes)),
          }),
          severity: "info",
        });
      }
    }
    requests.clear();
  }

  /** Releases every request before the server listener is closed. */
  #abortAllInFlightRequests(): void {
    for (const session of this.#inFlightRequests.keys()) {
      this.#abortSessionRequests(session);
    }
  }

  #finishControlSpan(
    inFlight: RuntimeInFlightRequest,
    request: RuntimeRequest,
    outcome: RuntimeDiagnosticOutcome,
    errorCode?: string,
    responseBytes?: number,
  ): void {
    const span = inFlight.span;
    if (span === undefined || span.isEnded) return;
    const severity = outcome === "error"
      ? "error"
      : outcome === "cancelled"
        ? "info"
        : outcome === "timeout" || outcome === "overloaded"
          ? "warn"
          : undefined;
    span.end(outcome, {
      attributes: () => runtimeDiagnosticValue.object({
        ...(errorCode === undefined
          ? {}
          : { errorCode: runtimeDiagnosticValue.string(errorCode) }),
        method: runtimeDiagnosticValue.string(diagnosticControlMethod(request.method)),
        queueWaitMicros: runtimeDiagnosticValue.int64(
          BigInt(elapsedMicros(inFlight.enqueuedAt)),
        ),
        requestBytes: runtimeDiagnosticValue.int64(BigInt(inFlight.requestBytes)),
        ...(responseBytes === undefined
          ? {}
          : { responseBytes: runtimeDiagnosticValue.int64(BigInt(responseBytes)) }),
      }),
      ...(severity === undefined ? {} : { severity }),
    });
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

function diagnosticControlMethod(method: string): string {
  return Object.values(RUNTIME_CONTROL_METHOD).includes(
    method as (typeof RUNTIME_CONTROL_METHOD)[keyof typeof RUNTIME_CONTROL_METHOD],
  )
    ? method
    : "unknown";
}

function normalizeDiagnosticTraceId(traceId: string): string {
  if (/^[A-Za-z0-9_-]{16,128}$/.test(traceId)) return traceId;
  return `trace-${createHash("sha256").update(traceId, "utf8").digest("hex").slice(0, 32)}`;
}

function controlOutcome(code: RuntimeErrorCode | PluginManagerError["code"]): RuntimeDiagnosticOutcome {
  switch (code) {
    case "cancelled":
      return "cancelled";
    case "timeout":
      return "timeout";
    case "overloaded":
      return "overloaded";
    default:
      return "error";
  }
}

function internalHttpRoute(pathname: string): string {
  if (pathname === "/health/live") return "/health/live";
  if (pathname === "/health/ready") return "/health/ready";
  if (pathname === RUNTIME_RPC_PATH) return RUNTIME_RPC_PATH;
  return "/other";
}

function stableHttpMethod(method: string | undefined): string {
  const normalized = (method ?? "UNKNOWN").toUpperCase();
  return /^[A-Z]{1,16}$/.test(normalized) ? normalized : "OTHER";
}

function elapsedMicros(startedAt: bigint): number {
  return Number((process.hrtime.bigint() - startedAt) / 1_000n);
}

const runtimeDiagnosticSeverities = Object.freeze(new Set<RuntimeDiagnosticSeverity>([
  "trace",
  "debug",
  "info",
  "warn",
  "error",
  "fatal",
]));
const runtimeDiagnosticSessionStates = Object.freeze(new Set<RuntimeDiagnosticSessionState>([
  "active",
  "ended",
  "expired",
  "deleting",
  "deleted",
]));
const runtimeDiagnosticPayloadKinds = Object.freeze(new Set<RuntimeDiagnosticPayloadKind>([
  "metadataOnly",
  "safeStructured",
  "contentPayload",
  "restrictedRaw",
]));
const runtimeDiagnosticDetailStorage = Object.freeze(new Set<RuntimeDiagnosticDetailStorage>([
  "memoryOnly",
  "persistToText",
]));

function hasOnlyKeys(value: JsonObject, allowed: readonly string[]): boolean {
  const accepted = new Set(allowed);
  return Object.keys(value).every((key) => accepted.has(key));
}

function readPageLimit(value: JsonValue | undefined, fallback: number): number {
  if (value === undefined) return fallback;
  const limit = readRequiredSafeInteger(value);
  if (limit <= 0 || limit > 200) throw new RangeError("Invalid diagnostics page limit.");
  return limit;
}

function readRequiredSafeInteger(value: JsonValue | undefined): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw new TypeError("Diagnostics field must be a safe integer.");
  }
  return value;
}

function readOptionalSafeInteger(value: JsonValue | undefined): number | undefined {
  return value === undefined ? undefined : readRequiredSafeInteger(value);
}

function readRequiredOpaqueId(value: JsonValue | undefined): string {
  const id = readOptionalOpaqueId(value);
  if (id === undefined) throw new TypeError("Diagnostics identifier is required.");
  return id;
}

function readOptionalOpaqueId(value: JsonValue | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(value)) {
    throw new TypeError("Invalid diagnostics identifier.");
  }
  return value;
}

function readOptionalCursor(value: JsonValue | undefined): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{8,512}$/.test(value)) {
    throw new TypeError("Invalid diagnostics cursor.");
  }
  return value;
}

function readOptionalEnum<T extends string>(
  value: JsonValue | undefined,
  values: ReadonlySet<T>,
): T | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || !values.has(value as T)) {
    throw new TypeError("Invalid diagnostics enum value.");
  }
  return value as T;
}

function readEnumSet<T extends string>(
  value: JsonValue | undefined,
  values: ReadonlySet<T>,
  maximumItems: number,
): ReadonlySet<T> | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > maximumItems) {
    throw new TypeError("Invalid diagnostics enum list.");
  }
  const result = new Set<T>();
  for (const item of value) {
    if (typeof item !== "string" || !values.has(item as T)) {
      throw new TypeError("Invalid diagnostics enum list item.");
    }
    result.add(item as T);
  }
  return result;
}

function readStringSet(
  value: JsonValue | undefined,
  maximumItems: number,
): ReadonlySet<string> | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > maximumItems) {
    throw new TypeError("Invalid diagnostics string list.");
  }
  const result = new Set<string>();
  for (const item of value) {
    if (typeof item !== "string" || item.length === 0 || item.length > 256) {
      throw new TypeError("Invalid diagnostics string list item.");
    }
    result.add(item);
  }
  return result;
}

function readOriginSet(
  value: JsonValue | undefined,
  maximumItems: number,
): ReadonlySet<string> {
  const strings = readStringSet(value, maximumItems) ?? new Set<string>();
  const origins = new Set<string>();
  for (const item of strings) {
    const url = new URL(item);
    if (
      (url.protocol !== "http:" && url.protocol !== "https:") ||
      url.origin !== item ||
      url.username.length > 0 ||
      url.password.length > 0
    ) {
      throw new TypeError("Diagnostics capture origin is invalid.");
    }
    origins.add(item);
  }
  return origins;
}

function compactEventPage(
  page: RuntimeDiagnosticPage<RuntimeDiagnosticEvent>,
): JsonObject {
  const items = page.items.map((event) => {
    const { attributes: _attributes, ...projection } = event;
    return projection;
  });
  return {
    items: toJsonValue(items) as readonly JsonValue[],
    ...(page.nextCursor === undefined ? {} : { nextCursor: page.nextCursor }),
  };
}

function toJsonValue(value: unknown): JsonValue {
  const encoded = JSON.stringify(value);
  if (encoded === undefined || Buffer.byteLength(encoded, "utf8") > MAX_INLINE_BYTES - 4_096) {
    throw new RangeError("Runtime diagnostics response exceeds its inline budget.");
  }
  return JSON.parse(encoded) as JsonValue;
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
