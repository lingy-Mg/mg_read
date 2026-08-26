/**
 * Runtime Core and its private transports.
 *
 * Responsibilities:
 * - own the Node Runtime lifecycle, private loopback plane and Debug inspector;
 * - resolve source directories for the Flutter Supervisor without launching
 *   user-facing shell processes from the Job-managed Node child.
 *
 * Boundaries:
 * - paths in control responses are consumed only by the package Supervisor;
 * - the optional LAN inspector never exposes control RPC or raw resource URLs;
 * - the public Flutter Facade exposes typed results and never exposes paths.
 */
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
import { RuntimeDebugHttpServer, RuntimeDebugLogBuffer, type RuntimeDebugHttpStatus } from "./debug-http.js";
import { createRuntimeDebugHttpServer } from "./debug-http-bridge.js";
import { readDebugHttpEnabled } from "./debug-http-control.js";
import { RuntimeDebugHttpSettings } from "./debug-http-settings.js";
import { servePluginIconResource, servePluginTransferResource, serveSourceResource } from "./loopback-resources.js";
import {
  PluginManager,
  PluginManagerError,
  type PluginManagerEvent,
} from "./plugin-manager.js";
import { installPluginArtifactInbox, seedBundledPluginArtifacts } from "./plugin-artifact-inbox.js";
import { dispatchPluginEnabled, dispatchPluginUninstall } from "./plugin-uninstall-dispatch.js";
import {
  dispatchPluginDevelopmentPackage,
  dispatchPluginTransferExport,
  dispatchPluginTransferList,
  dispatchPluginTransferPlan,
  dispatchPluginTransferVerify,
} from "./desktop-plugin-transfer-dispatch.js";
import { emitRuntimeDiagnostic, observeRuntimeDiagnostics } from "./runtime-diagnostics.js";
import {
  parseChaptersParams,
  parseContentParams,
  parseDetailParams,
  parseDiscoverParams,
  parseSearchParams,
  parseSearchSuggestionsParams,
  PluginContentValidationError,
  type PluginContentOperation,
} from "./plugin-content.js";

const LOOPBACK_HOST = "127.0.0.1";
const MAX_INLINE_BYTES = maxWebSocketControlFrameBytes;
const MAX_INFLIGHT_REQUESTS_PER_CONNECTION = 256;
const RUNTIME_CONTROL_METHOD = Object.freeze({
  debugHttpStatus: "runtime.debugHttp.status.v1",
  debugHttpSetEnabled: "runtime.debugHttp.setEnabled.v1",
  hello: "runtime.hello",
  ping: "runtime.ping",
  status: "runtime.status.v1",
  pluginsCacheClear: "plugins.cache.clear.v1",
  pluginsCacheClearAll: "plugins.cache.clearAll.v1",
  pluginsCacheUsage: "plugins.cache.usage.v1",
  pluginsInstallationUsage: "plugins.installation.usage.v1",
  pluginsList: "plugins.list.v1",
  pluginsRecoveryConsume: "plugins.recovery.consume.v1",
  pluginsOpenCodeDirectory: "plugins.openCodeDirectory.v1",
  pluginsDevelopmentPackage: "plugins.development.package.v1",
  pluginsSetEnabled: "plugins.setEnabled.v1",
  pluginsUninstall: "plugins.uninstall.v1",
  pluginsTransferList: "plugins.transfer.list.v2",
  pluginsTransferPlan: "plugins.transfer.plan.v2",
  pluginsTransferExport: "plugins.transfer.export.v2",
  pluginsTransferVerify: "plugins.transfer.verify.v2",
  sourceDiscover: "source.discover.v1",
  sourceSearch: "source.search.v1",
  sourceSearchSuggestions: "source.searchSuggestions.v1",
  sourceGetDetail: "source.getDetail.v1",
  sourceGetChapters: "source.getChapters.v1",
  sourceGetContent: "source.getContent.v1",
  shutdown: "runtime.shutdown",
} as const);

const RUNTIME_CONTROL_CAPABILITIES = Object.freeze([
  RUNTIME_CONTROL_METHOD.ping,
  RUNTIME_CONTROL_METHOD.status,
  RUNTIME_CONTROL_METHOD.pluginsCacheUsage,
  RUNTIME_CONTROL_METHOD.pluginsInstallationUsage,
  RUNTIME_CONTROL_METHOD.pluginsCacheClear,
  RUNTIME_CONTROL_METHOD.pluginsCacheClearAll,
  RUNTIME_CONTROL_METHOD.pluginsList,
  RUNTIME_CONTROL_METHOD.pluginsRecoveryConsume,
  RUNTIME_CONTROL_METHOD.pluginsOpenCodeDirectory,
  RUNTIME_CONTROL_METHOD.pluginsDevelopmentPackage,
  RUNTIME_CONTROL_METHOD.pluginsSetEnabled,
  RUNTIME_CONTROL_METHOD.pluginsUninstall,
  RUNTIME_CONTROL_METHOD.pluginsTransferList,
  RUNTIME_CONTROL_METHOD.pluginsTransferPlan,
  RUNTIME_CONTROL_METHOD.pluginsTransferExport,
  RUNTIME_CONTROL_METHOD.pluginsTransferVerify,
  RUNTIME_CONTROL_METHOD.sourceDiscover,
  RUNTIME_CONTROL_METHOD.sourceSearch,
  RUNTIME_CONTROL_METHOD.sourceSearchSuggestions,
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

/** Safe process snapshot exposed to the Flutter status page. */
interface RuntimeStatusResponse extends JsonObject {
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

/** Safe, bounded progress emitted while Runtime-owned work is running. */
export interface DesktopRuntimeProgress {
  readonly completedBytes: number;
  readonly detail?: string;
  readonly stage:
    | "assets_copying"
    | "assets_copied"
    | "assets_reused"
    | "node_starting"
    | "plugin_copying"
    | "plugin_copied"
    | "plugin_installing"
    | "ready";
  readonly totalBytes: number;
}

export type DesktopRuntimeProgressSink = (
  progress: DesktopRuntimeProgress,
) => void;

/** Construction-only options for the Node Runtime Core. */
export interface DesktopRuntimeOptions {
  /**
   * Requested loopback port. Production uses `0` for an OS-selected port;
   * nonzero values exist only for deterministic Runtime-owned tests.
   */
  readonly port?: number;

  /** Runtime-owned data root; production resolves it in the platform adapter. */
  readonly dataRoot?: string;

  /** Windows debug-only parent directory of directly loaded source projects. */
  readonly developmentPluginRoot?: string;

  /** Android adapter-owned inbox populated by the approved ADB test tool. */
  readonly pluginImportInboxRoot?: string;

  /**
   * Runtime-package-owned directory of first-run `.mgplugin` seed archives.
   *
   * The desktop platform adapter supplies this from its immutable Flutter
   * package assets. It is deliberately not exposed through the main app or
   * the Flutter Facade, and is only consumed while this Runtime is cold.
   */
  readonly bundledPluginRoot?: string;

  /** Runtime-owned in-process adapter mode; skips the desktop loopback listener. */
  readonly embedded?: boolean;

  /** Platform build gate for the optional unauthenticated Debug listener. */
  readonly debugHttpAllowed?: boolean;

  /** Safe progress sink used by the platform adapter; never receives paths or raw errors. */
  readonly onProgress?: DesktopRuntimeProgressSink;
}

/** Result returned by the Runtime-owned Android Javet adapter. */
export type EmbeddedRuntimeResult =
  | { readonly ok: true; readonly result: JsonValue }
  | { readonly error: RuntimeProtocolError; readonly ok: false };

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
  readonly #developmentPluginRoot: string | undefined;
  readonly #pluginImportInboxRoot: string | undefined;

  /** Immutable platform-package seed directory, if this launch supplies one. */
  readonly #bundledPluginRoot: string | undefined;
  readonly #embedded: boolean;
  readonly #debugHttpAllowed: boolean;
  readonly #debugHttpSettings: RuntimeDebugHttpSettings;
  readonly #onProgress: DesktopRuntimeProgressSink;

  /** All currently open RPC sessions, closed before server shutdown. */
  readonly #sessions = new Set<ServerWebSocketSession>();

  /** Fixed start timestamp included in the stdout readiness record. */
  readonly #startedAt = new Date().toISOString();
  #ready: DesktopRuntimeReady | undefined;
  #server: Server | undefined;
  #startPromise: Promise<DesktopRuntimeReady> | undefined;
  #stopPromise: Promise<void> | undefined;
  #pluginManager: PluginManager | undefined;
  /** Optional, separately-bound Debug inspector; never carries Runtime RPC. */
  #debugHttp: RuntimeDebugHttpServer | undefined;
  #debugHttpConfiguredEnabled = false;
  /** Transient tail for the Debug inspector; never persisted to disk. */
  readonly #debugLogs = new RuntimeDebugLogBuffer();
  #removeDebugDiagnosticObserver: (() => void) | undefined;
  constructor(options: DesktopRuntimeOptions = {}) {
    this.#port = options.port ?? 0;
    this.#dataRoot =
      options.dataRoot ??
      resolve(tmpdir(), "mgread-runtime-tests", process.pid.toString());
    this.#developmentPluginRoot = options.developmentPluginRoot;
    this.#pluginImportInboxRoot = options.pluginImportInboxRoot;
    this.#bundledPluginRoot = options.bundledPluginRoot;
    this.#embedded = options.embedded ?? false;
    this.#debugHttpAllowed = options.debugHttpAllowed ?? false;
    this.#debugHttpSettings = new RuntimeDebugHttpSettings(this.#dataRoot);
    this.#onProgress = options.onProgress ?? (() => {});
    this.#removeDebugDiagnosticObserver = observeRuntimeDiagnostics((record) => {
      if (!this.#debugHttp?.status().enabled) return;
      this.#debugLogs.append({
        code: record.code,
        level: record.level === "warning" ? "warn" : record.level ?? "info",
        message: record.message,
        source: "runtime",
      });
    });
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
   * Dispatches one capability for the Runtime-owned Android Javet adapter.
   *
   * The adapter is inside the Runtime package and calls the same Core dispatch
   * path as the loopback WebSocket server. It does not expose a host callback,
   * a second VM, or an alternate plugin protocol to the main Flutter app.
   */
  async invokeEmbedded(
    method: string,
    params: JsonObject,
    deadlineUnixMs = Date.now() + 5_000,
  ): Promise<EmbeddedRuntimeResult> {
    const request: RuntimeRequest = {
      bootId: this.#bootId,
      deadlineUnixMs: String(deadlineUnixMs),
      id: "android-embedded",
      idempotencyKey: method === RUNTIME_CONTROL_METHOD.shutdown
        ? "android-embedded-shutdown"
        : null,
      method,
      params,
      traceId: "trace:android-embedded",
      v: protocolVersion,
    };
    const dispatched = await this.#dispatch(
      request,
      new AbortController().signal,
    );
    return "error" in dispatched
      ? { error: dispatched.error, ok: false }
      : { ok: true, result: dispatched.result };
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
      await installPluginArtifactInbox(this.#dataRoot, this.#pluginImportInboxRoot, this.#onProgress);
      await seedBundledPluginArtifacts(this.#dataRoot, this.#bundledPluginRoot, this.#onProgress);
    } catch (error) {
      throw error;
    }
    const pluginManager = new PluginManager(this.#dataRoot, {
      embedded: this.#embedded,
      ...(this.#developmentPluginRoot === undefined
        ? {}
        : { developmentPluginRoot: this.#developmentPluginRoot }),
      events: (event) => this.#handlePluginManagerEvent(event),
    });
    try {
      await pluginManager.initialize();
    } catch (error) {
      throw error;
    }
    this.#pluginManager = pluginManager;
    if (this.#debugHttpAllowed) {
      this.#debugHttp = createRuntimeDebugHttpServer(
        this.#bootId,
        this.#debugLogs,
        (request) => this.#dispatch(request, new AbortController().signal),
      );
      this.#debugHttpConfiguredEnabled = await this.#debugHttpSettings.readEnabled();
      if (this.#debugHttpConfiguredEnabled) {
        try {
          await this.#debugHttp.setEnabled(true);
        } catch {
          emitRuntimeDiagnostic({
            code: "runtime_debug_http_port_unavailable",
            level: "warning",
            message: "The fixed Debug inspector port was unavailable.",
            type: "diagnostic",
          });
        }
      }
    }
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
    pluginManager.setResourceOrigin(`http://${LOOPBACK_HOST}:${address.port}`);
    this.#ready = ready;
    return ready;
  }

  /** Mirrors plugin ctx.log only while the separately enabled Debug listener is live. */
  #handlePluginManagerEvent(event: PluginManagerEvent): void {
    if (
      event.code === "plugin_log_emitted" &&
      event.logMessage !== undefined &&
      this.#debugHttp?.status().enabled
    ) {
      this.#debugLogs.append({
        level: event.logLevel ?? "info",
        message: event.logMessage,
        source: "plugin",
        ...(event.pluginId === undefined ? {} : { pluginId: event.pluginId }),
      });
    }
    emitPluginManagerDiagnostic(event);
  }

  /** Projects the durable preference separately from the current listener state. */
  #debugHttpStatus(): RuntimeDebugHttpStatus {
    return this.#debugHttp?.status(this.#debugHttpConfiguredEnabled) ?? Object.freeze({
      configuredEnabled: this.#debugHttpConfiguredEnabled,
      enabled: false,
      endpoints: Object.freeze([]),
      startedAt: null,
    });
  }

  /** Performs ordered shutdown so handlers cannot outlive their transport. */
  async #stop(): Promise<void> {
    const server = this.#server;
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
    } catch (error) {
      throw error;
    } finally {
      await this.#debugHttp?.dispose();
      this.#debugHttp = undefined;
      this.#debugLogs.clear();
      this.#removeDebugDiagnosticObserver?.();
      this.#removeDebugDiagnosticObserver = undefined;
      await this.#pluginManager?.close();
      this.#pluginManager = undefined;
    }
  }

  /** Serves no-store liveness/readiness checks on the Runtime loopback plane. */
  #handleHttp(request: IncomingMessage, response: ServerResponse): void {
    const url = new URL(request.url ?? "/", `http://${LOOPBACK_HOST}`);
    const finish = (_statusCode: number, _downloadedBytes = 0): void => {};
    const resourceMatch = /^\/v1\/source-resource\/([A-Za-z0-9_-]{32,128})$/.exec(url.pathname);
    if (resourceMatch !== null) {
      if (request.method !== "GET") { response.writeHead(405, { Allow: "GET" }); response.end(); finish(405); return; }
      void serveSourceResource(this.#pluginManager, resourceMatch[1]!, response, finish);
      return;
    }
    const iconMatch = /^\/v1\/plugin-icon\/([A-Za-z0-9_-]{32,128})$/.exec(url.pathname);
    if (iconMatch !== null) {
      if (request.method !== "GET") { response.writeHead(405, { Allow: "GET" }); response.end(); finish(405); return; }
      void servePluginIconResource(this.#pluginManager, iconMatch[1]!, response, finish);
      return;
    }
    const transferMatch = /^\/v2\/plugin-artifact\/([A-Za-z0-9_-]{32,128})$/.exec(url.pathname);
    if (transferMatch !== null) {
      if (request.method !== "GET") { response.writeHead(405, { Allow: "GET" }); response.end(); finish(405); return; }
      void servePluginTransferResource(this.#pluginManager, transferMatch[1]!, response, finish);
      return;
    }
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
    const inFlight = Object.freeze({ cancellation });
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
      return;
    }

    let result: RuntimeDispatchResult;
    try {
      result = await this.#dispatch(
        request,
        inFlight.cancellation.signal,
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
      return;
    }

    if ("error" in result) {
      this.#sendProtocolError(session, result.error);
      return;
    }
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
      case RUNTIME_CONTROL_METHOD.status: {
        if (Object.keys(request.params).length !== 0) {
          return {
            error: this.#requestError(
              request,
              "invalid_request",
              "The Runtime status query accepts no parameters.",
            ),
          };
        }
        const memory = process.memoryUsage();
        const plugins = await this.#pluginManager?.listInstalled();
        const status: RuntimeStatusResponse = {
          arch: process.arch,
          bootId: this.#bootId,
          memory: {
            arrayBuffers: memory.arrayBuffers,
            external: memory.external,
            heapTotal: memory.heapTotal,
            heapUsed: memory.heapUsed,
            rss: memory.rss,
          },
          nodeVersion: process.versions.node,
          ok: true,
          platform: process.platform,
          plugins: plugins ?? [],
          runtimeVersion,
          runtimeKind: process.platform === "android" ? "android-javet" : "desktop-node",
          uptimeMs: Math.max(0, Math.floor(process.uptime() * 1000)),
        };
        return { result: status };
      }
      case RUNTIME_CONTROL_METHOD.debugHttpSetEnabled:
        if (!this.#debugHttpAllowed) {
          return {
            error: this.#requestError(request, "method_not_found", "The Runtime method is not implemented."),
          };
        }
        {
          const enabled = readDebugHttpEnabled(request);
          if (typeof enabled !== "boolean") return enabled;
          try {
            await this.#debugHttpSettings.writeEnabled(enabled);
            this.#debugHttpConfiguredEnabled = enabled;
            if (!enabled) {
              await this.#debugHttp?.setEnabled(false);
              this.#debugLogs.clear();
            } else {
              try {
                await this.#debugHttp?.setEnabled(true);
              } catch {
                // The durable preference remains enabled so the next Runtime
                // start retries the fixed listener without breaking Runtime work.
              }
            }
            return { result: this.#debugHttpStatus() };
          } catch {
            return {
              error: this.#requestError(
                request,
                "internal",
                "The Runtime Debug HTTP setting could not be saved.",
              ),
            };
          }
        }
      case RUNTIME_CONTROL_METHOD.debugHttpStatus:
        if (!this.#debugHttpAllowed) {
          return {
            error: this.#requestError(request, "method_not_found", "The Runtime method is not implemented."),
          };
        }
        if (Object.keys(request.params).length !== 0) {
          return {
            error: this.#requestError(request, "invalid_request", "The Debug HTTP status query accepts no parameters."),
          };
        }
        return { result: this.#debugHttpStatus() };
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
      case RUNTIME_CONTROL_METHOD.pluginsRecoveryConsume: {
        if (Object.keys(request.params).length !== 0) {
          return {
            error: this.#requestError(
              request,
              "invalid_request",
              "The plugin recovery query accepts no parameters.",
            ),
          };
        }
        const manager = this.#pluginManager;
        if (manager === undefined) {
          return {
            error: this.#requestError(
              request,
              "plugin_load_failed",
              "The plugin recovery summary is unavailable.",
            ),
          };
        }
        return { result: await manager.consumeStartupRecovery() };
      }
      case RUNTIME_CONTROL_METHOD.pluginsOpenCodeDirectory:
        return this.#dispatchPluginOpenCodeDirectory(request);
      case RUNTIME_CONTROL_METHOD.pluginsDevelopmentPackage:
        return dispatchPluginDevelopmentPackage(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.pluginsCacheUsage:
        return this.#dispatchPluginCacheUsage(request);
      case RUNTIME_CONTROL_METHOD.pluginsInstallationUsage:
        return this.#dispatchPluginInstallationUsage(request);
      case RUNTIME_CONTROL_METHOD.pluginsCacheClear:
        return this.#dispatchPluginCacheClear(request);
      case RUNTIME_CONTROL_METHOD.pluginsCacheClearAll:
        return this.#dispatchPluginCacheClearAll(request);
      case RUNTIME_CONTROL_METHOD.pluginsSetEnabled:
        return dispatchPluginEnabled(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.pluginsUninstall:
        return dispatchPluginUninstall(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.pluginsTransferList:
        return dispatchPluginTransferList(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.pluginsTransferPlan:
        return dispatchPluginTransferPlan(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.pluginsTransferExport:
        return dispatchPluginTransferExport(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.pluginsTransferVerify:
        return dispatchPluginTransferVerify(request, this.#pluginManager, this.#requestError.bind(this));
      case RUNTIME_CONTROL_METHOD.sourceDiscover:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "discover",
        );
      case RUNTIME_CONTROL_METHOD.sourceSearch:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "search",
        );
      case RUNTIME_CONTROL_METHOD.sourceSearchSuggestions:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "searchSuggestions",
        );
      case RUNTIME_CONTROL_METHOD.sourceGetDetail:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "getDetail",
        );
      case RUNTIME_CONTROL_METHOD.sourceGetChapters:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "getChapters",
        );
      case RUNTIME_CONTROL_METHOD.sourceGetContent:
        return this.#dispatchPluginContent(
          request,
          cancellation,
          "getContent",
        );
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

  /** Opens an internal source directory and returns only its stable kind. */
  async #dispatchPluginOpenCodeDirectory(
    request: RuntimeRequest,
  ): Promise<RuntimeDispatchResult> {
    if (
      Object.keys(request.params).length !== 1 ||
      typeof request.params.pluginId !== "string"
    ) {
      return {
        error: this.#requestError(
          request,
          "invalid_request",
          "The source directory request is invalid.",
        ),
      };
    }
    if (process.platform !== "win32") {
      return {
        error: this.#requestError(
          request,
          "unsupported",
          "Opening source directories is available on Windows only.",
        ),
      };
    }
    try {
      const manager = this.#pluginManager;
      if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
      const directory = await manager.resolveCodeDirectory(request.params.pluginId);
      // The absolute path is an internal Supervisor hand-off only. The
      // Flutter Facade consumes the kind and opens the path from its own
      // desktop process, so the application layer never observes it.
      return {
        result: {
          directory: directory.directory,
          kind: directory.kind,
        },
      };
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
      return {
        error: this.#requestError(
          request,
          "internal",
          "The source directory could not be opened.",
        ),
      };
    }
  }

  /** Returns only cache byte totals; cache paths remain Runtime-private. */
  async #dispatchPluginCacheUsage(
    request: RuntimeRequest,
  ): Promise<RuntimeDispatchResult> {
    if (Object.keys(request.params).length !== 0) {
      return this.#pluginCacheInvalidRequest(request);
    }
    try {
      const manager = this.#pluginManager;
      if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
      return { result: await manager.listCacheUsage() };
    } catch (error) {
      return this.#pluginCacheFailure(request, error);
    }
  }

  /** Returns retained archive, source data and materialized npm byte totals. */
  async #dispatchPluginInstallationUsage(
    request: RuntimeRequest,
  ): Promise<RuntimeDispatchResult> {
    const pluginId = request.params.pluginId;
    const scope = request.params.scope;
    if (
      Object.keys(request.params).length !== 2 ||
      typeof pluginId !== "string" ||
      (scope !== "archive" && scope !== "data" && scope !== "npm")
    ) {
      return {
        error: this.#requestError(
          request,
          "invalid_request",
          "The installed source size request is invalid.",
        ),
      };
    }
    try {
      const manager = this.#pluginManager;
      if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
      return {
        result: await manager.measureInstallationUsage(pluginId, scope),
      };
    } catch (error) {
      return this.#pluginCacheFailure(request, error);
    }
  }

  /** Clears one plugin cache and returns a terminal, path-free status. */
  async #dispatchPluginCacheClear(
    request: RuntimeRequest,
  ): Promise<RuntimeDispatchResult> {
    if (Object.keys(request.params).length !== 1 || typeof request.params.pluginId !== "string") {
      return this.#pluginCacheInvalidRequest(request);
    }
    try {
      const manager = this.#pluginManager;
      if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
      return { result: await manager.clearPluginCache(request.params.pluginId) };
    } catch (error) {
      return this.#pluginCacheFailure(request, error);
    }
  }

  /** Clears every installed plugin cache while retaining individual failures. */
  async #dispatchPluginCacheClearAll(
    request: RuntimeRequest,
  ): Promise<RuntimeDispatchResult> {
    if (Object.keys(request.params).length !== 0) {
      return this.#pluginCacheInvalidRequest(request);
    }
    try {
      const manager = this.#pluginManager;
      if (manager === undefined) throw new PluginManagerError("plugin_load_failed");
      return { result: await manager.clearAllPluginCaches() };
    } catch (error) {
      return this.#pluginCacheFailure(request, error);
    }
  }

  #pluginCacheInvalidRequest(request: RuntimeRequest): RuntimeDispatchFailure {
    return {
      error: this.#requestError(
        request,
        "invalid_request",
        "The plugin cache request is invalid.",
      ),
    };
  }

  #pluginCacheFailure(
    request: RuntimeRequest,
    error: unknown,
  ): RuntimeDispatchFailure {
    if (error instanceof PluginManagerError) {
      return {
        error: this.#requestError(
          request,
          error.code,
          pluginManagerErrorMessage(error.code),
        ),
      };
    }
    return {
      error: this.#requestError(
        request,
        "internal",
        "The plugin cache request could not be completed.",
      ),
    };
  }

  /** Returns the versioned product capability list negotiated by the Facade. */
  get #runtimeControlCapabilities(): readonly string[] {
    return RUNTIME_CONTROL_CAPABILITIES;
  }

  /**
   * Invokes one standard Node plugin named export through a bounded v1 schema.
   */
  async #dispatchPluginContent(
    request: RuntimeRequest,
    cancellation: AbortSignal,
    operation: PluginContentOperation,
  ): Promise<RuntimeDispatchResult> {
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
          );
          break;
        }
        case "searchSuggestions": {
          const parsed = parseSearchSuggestionsParams(request.params);
          result = await manager.searchSuggestions(
            parsed.pluginId,
            parsed.request,
            cancellation,
            request.deadlineUnixMs,
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
          );
          break;
        }
      }
      return { result: result };
    } catch (error) {
      if (error instanceof PluginContentValidationError) {
        return {
          error: this.#requestError(
            request,
            "invalid_request",
            "The source capability request is invalid.",
          ),
        };
      }
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
    const inFlight = requests?.get(targetId);
    if (inFlight === undefined) {
      return;
    }
    requests?.delete(targetId);
    inFlight.cancellation.abort();
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
    plugin_disabled: "A plugin source was disabled.",
    plugin_enabled: "A plugin source was enabled.",
    plugin_invocation_completed: "A plugin capability completed successfully.",
    plugin_invocation_failed: "A plugin capability failed.",
    plugin_invocation_started: "A plugin capability started.",
    plugin_load_completed: "A standard Node plugin loaded successfully.",
    plugin_load_failed: "A standard Node plugin could not be loaded.",
    plugin_load_started: "A standard Node plugin load started.",
    plugin_log_emitted: "A plugin emitted a redacted diagnostic event.",
    plugin_quarantined: "A broken plugin source was isolated during startup.",
    plugin_uninstall_scheduled: "A plugin source was scheduled for removal at the next cold start.",
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
    case "plugin_execution_failed":
      return "The plugin could not complete the requested operation.";
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
