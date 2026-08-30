/**
 * Debug-only Runtime HTTP inspector.
 *
 * Responsibilities:
 * - own the separately-bound LAN debug listener and its static inspector page;
 * - project bounded source search/discovery fields for direct inspection;
 * - retain bounded, in-memory cover probes and an unbounded listener-scoped log stream.
 *
 * Boundaries:
 * - never exposes Runtime RPC, health, cookies, headers, HTML, or raw plugin objects;
 * - Debug projections intentionally preserve URL, query, and log values verbatim;
 * - do not add masking, redaction, persistence, or automatic log pruning here;
 * - delegates all source calls and resource reads to the owning Runtime Core.
 */
import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { networkInterfaces } from "node:os";
import { Readable } from "node:stream";

import type { JsonObject, JsonValue } from "./protocol.js";
import { readDebugInspectorAsset } from "./debug-ui-assets.js";

const debugHost = "0.0.0.0";
/** Preferred, intentionally uncommon Debug-only LAN port owned by Runtime. */
export const runtimeDebugHttpPort = 52_173;
const maxPageSize = 50;
const maxQueryLength = 160;
const probeTtlMs = 15 * 60 * 1_000;
const maxProbeEntries = 300;
const maxLogMessageLength = 64_000;
const maxLogPageSize = 1_000;

/** Fixed categories make high-volume Runtime internals independently filterable. */
export type RuntimeDebugLogCategory =
  | "plugin.custom"
  | "plugin.http"
  | "plugin.webview"
  | "runtime.diagnostic"
  | "runtime.plugin.invocation"
  | "runtime.plugin.resource_proxy";

export interface RuntimeDebugHttpStatus extends JsonObject {
  readonly configuredEnabled: boolean;
  readonly enabled: boolean;
  readonly endpoints: readonly string[];
  readonly startedAt: string | null;
  readonly usingTemporaryPort: boolean;
}

export interface RuntimeDebugHttpHost {
  readonly chapters: (params: JsonObject) => Promise<JsonValue>;
  readonly content: (params: JsonObject) => Promise<JsonValue>;
  readonly detail: (params: JsonObject) => Promise<JsonValue>;
  readonly discover: (params: JsonObject) => Promise<JsonValue>;
  readonly logs: (after: number, limit: number) => JsonObject;
  readonly plugins: () => Promise<JsonValue>;
  readonly search: (params: JsonObject) => Promise<JsonValue>;
  readonly status: () => Promise<JsonObject>;
}

/** Debug-only in-memory logs retained for the listener lifetime and never persisted. */
export class RuntimeDebugLogBuffer {
  readonly #entries: RuntimeDebugLogEntry[] = [];
  #nextSequence = 1;

  append(entry: RuntimeDebugLogInput): void {
    const message = entry.message.slice(0, maxLogMessageLength);
    this.#entries.push(Object.freeze({
      category: entry.category,
      level: entry.level,
      message,
      source: entry.source,
      sequence: this.#nextSequence++,
      timestamp: new Date().toISOString(),
      ...(entry.code === undefined ? {} : { code: entry.code }),
      ...(entry.pluginId === undefined ? {} : { pluginId: entry.pluginId }),
    }));
  }

  clear(): void {
    this.#entries.length = 0;
  }

  page(after: number, limit: number): JsonObject {
    // Keep cursor order. Returning the newest page here would make the browser
    // advance past older entries when a burst exceeds its per-request limit.
    const items = this.#entries.filter((entry) => entry.sequence > after).slice(0, limit);
    return Object.freeze({
      items: Object.freeze(items.map((entry) => Object.freeze({ ...entry }))),
      latestSequence: this.#nextSequence - 1,
      nextSequence: items.at(-1)?.sequence ?? Math.max(after, this.#nextSequence - 1),
    });
  }
}

export interface RuntimeDebugLogInput {
  readonly category: RuntimeDebugLogCategory;
  readonly code?: string;
  readonly level: "debug" | "error" | "info" | "warn";
  readonly message: string;
  readonly pluginId?: string;
  readonly source: "plugin" | "runtime";
}

export interface RuntimeDebugLogEntry extends JsonObject {
  readonly category: RuntimeDebugLogCategory;
  readonly code?: string;
  readonly level: "debug" | "error" | "info" | "warn";
  readonly message: string;
  readonly pluginId?: string;
  readonly sequence: number;
  readonly source: "plugin" | "runtime";
  readonly timestamp: string;
}

interface DebugProbe {
  readonly coverUrl: string;
  readonly expiresAtMs: number;
}

/** Owns one optional LAN-only Debug listener for an already-running Runtime. */
export class RuntimeDebugHttpServer {
  readonly #host: RuntimeDebugHttpHost;
  readonly #preferredPort: number;
  readonly #probes = new Map<string, DebugProbe>();
  #server: Server | undefined;
  #startedAt: string | undefined;

  constructor(host: RuntimeDebugHttpHost, preferredPort = runtimeDebugHttpPort) {
    this.#host = host;
    this.#preferredPort = preferredPort;
  }

  async setEnabled(enabled: boolean): Promise<RuntimeDebugHttpStatus> {
    if (!enabled) {
      await this.#stop();
      return this.status();
    }
    if (this.#server === undefined) await this.#start();
    return this.status();
  }

  status(configuredEnabled = this.#server !== undefined): RuntimeDebugHttpStatus {
    const address = this.#server?.address();
    if (address === undefined || address === null || typeof address === "string") {
      return Object.freeze({ configuredEnabled, enabled: false, endpoints: Object.freeze([]), startedAt: null, usingTemporaryPort: false });
    }
    const endpoints = debugEndpoints(address.port);
    return Object.freeze({
      configuredEnabled,
      enabled: true,
      endpoints,
      startedAt: this.#startedAt ?? null,
      usingTemporaryPort: address.port !== this.#preferredPort,
    });
  }

  async dispose(): Promise<void> {
    await this.#stop();
  }

  async #start(): Promise<void> {
    const server = createServer((request, response) => {
      void this.#handle(request, response);
    });
    try {
      await listenDebugServer(server, this.#preferredPort);
    } catch (error) {
      if (!isPreferredPortUnavailable(error)) throw error;
      await listenDebugServer(server, 0);
    }
    this.#server = server;
    this.#startedAt = new Date().toISOString();
  }

  async #stop(): Promise<void> {
    const server = this.#server;
    this.#server = undefined;
    this.#startedAt = undefined;
    this.#probes.clear();
    if (server === undefined) return;
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://runtime-debug.invalid");
    if (request.method !== "GET") {
      response.writeHead(405, { Allow: "GET" });
      response.end();
      return;
    }
    try {
      switch (url.pathname) {
        case "/__debug":
        case "/__debug/search":
        case "/__debug/discover":
        case "/__debug/logs":
          writeHtml(response, await readDebugInspectorAsset("index.html"));
          return;
        case "/__debug/app.css":
          writeText(response, 200, await readDebugInspectorAsset("app.css"), "text/css; charset=utf-8");
          return;
        case "/__debug/app.js":
          writeText(response, 200, await readDebugInspectorAsset("app.js"), "text/javascript; charset=utf-8");
          return;
        case "/__debug/api/status":
          writeJson(response, 200, await this.#host.status());
          return;
        case "/__debug/api/plugins":
          writeJson(response, 200, { plugins: await this.#host.plugins() });
          return;
        case "/__debug/api/logs":
          writeJson(response, 200, this.#logs(url));
          return;
        case "/__debug/api/search":
          writeJson(response, 200, await this.#search(url));
          return;
        case "/__debug/api/discover":
          writeJson(response, 200, await this.#discover(url));
          return;
        case "/__debug/api/detail":
          writeJson(response, 200, await this.#detail(url));
          return;
        case "/__debug/api/chapters":
          writeJson(response, 200, await this.#chapters(url));
          return;
        case "/__debug/api/content":
          writeJson(response, 200, await this.#content(url));
          return;
        case "/__debug/api/resource-probe":
          await this.#probe(url, request, response);
          return;
        default:
          writeJson(response, 404, { code: "not_found" });
      }
    } catch (error) {
      writeJson(response, 400, { code: stableDebugError(error) });
    }
  }

  async #search(url: URL): Promise<JsonObject> {
    const pluginId = readPluginId(url);
    const query = requiredText(url.searchParams.get("q"), "query");
    if (query.length > maxQueryLength) throw new Error("query_too_long");
    const pageSize = readPageSize(url);
    const startedAt = performance.now();
    const result = await this.#host.search(Object.freeze({
      cursor: nullableQuery(url, "cursor"),
      pageSize,
      pluginId,
      query,
    }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: this.#projectResult(result) });
  }

  async #discover(url: URL): Promise<JsonObject> {
    const pluginId = readPluginId(url);
    const pageSize = readPageSize(url);
    const startedAt = performance.now();
    const result = await this.#host.discover(Object.freeze({
      collectionId: nullableQuery(url, "collectionId"),
      cursor: nullableQuery(url, "cursor"),
      pageSize,
      pluginId,
      target: nullableQuery(url, "target"),
    }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: this.#projectResult(result) });
  }

  async #detail(url: URL): Promise<JsonObject> {
    const startedAt = performance.now();
    const result = await this.#host.detail(Object.freeze({ id: readOpaqueReference(url, "id"), pluginId: readPluginId(url) }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: this.#projectResult(result) });
  }

  async #chapters(url: URL): Promise<JsonObject> {
    const startedAt = performance.now();
    const result = await this.#host.chapters(Object.freeze({ id: readOpaqueReference(url, "id"), pluginId: readPluginId(url) }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: this.#projectResult(result) });
  }

  async #content(url: URL): Promise<JsonObject> {
    const startedAt = performance.now();
    const result = await this.#host.content(Object.freeze({ chapterId: readOpaqueReference(url, "chapterId"), id: readOpaqueReference(url, "id"), pluginId: readPluginId(url) }));
    return Object.freeze({ elapsedMs: Math.round(performance.now() - startedAt), result: projectContent(result, (coverUrl) => this.#retainProbe(coverUrl)) });
  }

  #logs(url: URL): JsonObject {
    const after = readNonNegativeInteger(url.searchParams.get("after"), 0, 10_000_000);
    const limit = readNonNegativeInteger(url.searchParams.get("limit"), 100, maxLogPageSize);
    return this.#host.logs(after, limit);
  }

  async #probe(url: URL, request: IncomingMessage, response: ServerResponse): Promise<void> {
    this.#pruneProbes();
    const id = requiredText(url.searchParams.get("probeId"), "probeId");
    const probe = this.#probes.get(id);
    if (probe === undefined) {
      writeJson(response, 404, { code: "probe_not_found" });
      return;
    }
    const controller = new AbortController();
    request.once("close", () => controller.abort());
    const upstream = await fetch(probe.coverUrl, { redirect: "follow", signal: controller.signal });
    const headers: Record<string, string> = { "Cache-Control": "no-store" };
    const contentType = upstream.headers.get("content-type");
    const contentLength = upstream.headers.get("content-length");
    if (contentType !== null) headers["Content-Type"] = contentType;
    if (contentLength !== null) headers["Content-Length"] = contentLength;
    response.writeHead(upstream.status, headers);
    const body = upstream.body;
    if (body === null) {
      response.end();
      return;
    }
    await new Promise<void>((resolve, reject) => {
      const stream = Readable.fromWeb(body);
      stream.once("error", reject);
      response.once("error", reject);
      response.once("finish", resolve);
      stream.pipe(response);
    });
  }

  #projectResult(value: JsonValue): JsonValue {
    return projectValue(value, (coverUrl) => this.#retainProbe(coverUrl));
  }

  #retainProbe(coverUrl: string): JsonObject {
    this.#pruneProbes();
    if (this.#probes.size >= maxProbeEntries) this.#probes.delete(this.#probes.keys().next().value as string);
    const id = randomBytes(18).toString("base64url");
    this.#probes.set(id, Object.freeze({ coverUrl, expiresAtMs: Date.now() + probeTtlMs }));
    return Object.freeze({ displayUrl: coverUrl, probeId: id, type: coverUrl.includes("/v1/source-resource/") ? "runtime-proxy" : "ordinary-url" });
  }

  #pruneProbes(): void {
    const now = Date.now();
    for (const [id, probe] of this.#probes) if (probe.expiresAtMs <= now) this.#probes.delete(id);
  }
}

async function listenDebugServer(server: Server, port: number): Promise<void> {
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
    server.listen({ host: debugHost, port });
  });
}

function isPreferredPortUnavailable(error: unknown): boolean {
  return error instanceof Error && "code" in error && (error.code === "EADDRINUSE" || error.code === "EACCES");
}

function projectValue(value: JsonValue, retainProbe: (coverUrl: string) => JsonObject): JsonValue {
  if (Array.isArray(value)) return Object.freeze(value.map((item) => projectValue(item, retainProbe)));
  if (value === null || typeof value !== "object") return value;
  const source = value as JsonObject;
  const projected: Record<string, JsonValue> = {};
  for (const key of ["kind", "type", "id", "title", "subtitle", "text", "layout", "target", "collectionId", "cursor", "nextCursor", "totalCount", "count", "elapsedMs", "pluginId", "sourceName", "author", "contentKind", "status", "access", "description", "language", "wordCount", "chapterCount", "publishedAt", "updatedAt", "isLocked", "order", "volumeTitle", "rank", "recommendation", "label", "value", "key", "selectedTabId", "aliases", "catalogUrl", "chapterId", "document", "tabs", "categories", "tags", "attributes", "latestChapter", "children", "components", "items", "content", "metric", "continuation"]) {
    const item = source[key];
    if (item !== undefined) projected[key] = projectValue(item, retainProbe);
  }
  const coverUrl = source.coverUrl;
  if (typeof coverUrl === "string") projected.cover = retainProbe(coverUrl);
  if (coverUrl === null) projected.cover = null;
  const url = source.url;
  if (typeof url === "string") projected.url = url;
  if (url === null) projected.url = null;
  return Object.freeze(projected);
}

/** Projects one explicit Debug content response without exposing plugin-private objects. */
function projectContent(value: JsonValue, retainProbe: (coverUrl: string) => JsonObject): JsonValue {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return projectValue(value, retainProbe);
  const source = value as JsonObject;
  const projected: Record<string, JsonValue> = {};
  for (const key of ["chapterId", "contentKind", "title", "updatedAt", "text"]) {
    const item = source[key];
    if (item !== undefined) projected[key] = item;
  }
  const pages = source.pages;
  if (Array.isArray(pages)) projected.pages = Object.freeze(pages.map((page) => projectValue(page, retainProbe)));
  return Object.freeze(projected);
}

function debugEndpoints(port: number): readonly string[] {
  const hosts = new Set<string>(["127.0.0.1"]);
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses ?? []) if (address.family === "IPv4" && !address.internal) hosts.add(address.address);
  }
  return Object.freeze([...hosts].map((host) => `http://${host}:${port}/__debug`));
}

function readPluginId(url: URL): string {
  const value = requiredText(url.searchParams.get("pluginId"), "pluginId");
  if (!/^[a-z0-9][a-z0-9.-]{0,127}$/.test(value)) throw new Error("plugin_id_invalid");
  return value;
}

function readPageSize(url: URL): number {
  const value = url.searchParams.get("pageSize");
  if (value === null || value === "") return 20;
  if (!/^\d+$/.test(value)) throw new Error("page_size_invalid");
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1 || parsed > maxPageSize) throw new Error("page_size_invalid");
  return parsed;
}

function readOpaqueReference(url: URL, key: string): string {
  const value = requiredText(url.searchParams.get(key), key);
  if (value.length > 512) throw new Error("reference_too_long");
  return value;
}

function readNonNegativeInteger(value: string | null, fallback: number, maximum: number): number {
  if (value === null || value === "") return fallback;
  if (!/^\d+$/.test(value)) throw new Error("parameter_invalid");
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > maximum) {
    throw new Error("parameter_invalid");
  }
  return parsed;
}

function nullableQuery(url: URL, key: string): string | null {
  const value = url.searchParams.get(key);
  if (value === null || value === "") return null;
  if (value.length > 500) throw new Error("parameter_too_long");
  return value;
}

function requiredText(value: string | null, name: string): string {
  if (value === null || value.trim() === "") throw new Error(`${name}_required`);
  return value.trim();
}

function stableDebugError(error: unknown): string {
  return error instanceof Error && /^[a-z_]+$/.test(error.message) ? error.message : "debug_request_failed";
}

function writeJson(response: ServerResponse, status: number, body: JsonObject): void {
  response.writeHead(status, { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(body));
}

function writeHtml(response: ServerResponse, body: string): void {
  response.writeHead(200, { "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'self' blob:; style-src 'self'; script-src 'self'; img-src 'self' blob:", "Content-Type": "text/html; charset=utf-8" });
  response.end(body);
}

function writeText(response: ServerResponse, status: number, body: string, contentType: string): void {
  response.writeHead(status, { "Cache-Control": "no-store", "Content-Type": contentType });
  response.end(body);
}
