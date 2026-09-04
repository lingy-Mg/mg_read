/**
 * Runtime-private source-resource orchestration.
 *
 * Responsibilities:
 * - Own bounded HLS manifest warmup and live source-resource opening.
 * - Attach URL-free completion diagnostics to loopback responses.
 *
 * Notes:
 * - This is an internal data-plane owner and does not change the wire contract.
 * - Diagnostics contain only kind, role, status, timing, bytes, and header count.
 */
import type { JsonObject } from "./protocol.js";
import { HlsManifestWarmup, type HlsWarmupEvent } from "./hls-manifest-warmup.js";
import type { PluginManagerEventSink, PluginRuntimeHttpClient } from "./plugin-manager-contract.js";
import { openSourceProxyResource, type SourceProxyEntry, type SourceProxyResource } from "./source-resource-proxy.js";
import { decodeSourceResourceToken } from "./source-resource-token.js";

export class SourceResourceCoordinator {
  readonly #warmup: HlsManifestWarmup;
  readonly #http: PluginRuntimeHttpClient;
  readonly #events: PluginManagerEventSink;
  readonly #debugLogEnabled: () => boolean;

  constructor(
    http: PluginRuntimeHttpClient,
    events: PluginManagerEventSink,
    debugLogEnabled: () => boolean,
  ) {
    this.#http = http;
    this.#events = events;
    this.#debugLogEnabled = debugLogEnabled;
    this.#warmup = new HlsManifestWarmup((event) => this.#logWarmup(event));
  }

  created(pluginId: string, request: JsonObject, proxy: SourceProxyEntry["proxy"]): void {
    this.#warmup.schedule(pluginId, { fetch: this.#http.fetch.bind(this.#http), proxy, request });
    if (!this.#debugLogEnabled()) return;
    const headers = request.headers;
    const count = headers !== null && typeof headers === "object" && !Array.isArray(headers) ? Object.keys(headers).length : 0;
    this.#events({
      code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy", logLevel: "debug",
      logMessage: `资源代理已创建：类型=${String(request.kind)}，角色=${String(request.resourceRole ?? "root")}，请求头数量=${count}`,
      outcome: "success", pluginId,
    });
  }

  async open(
    token: string,
    requestHeaders: Readonly<Record<string, string>>,
    signal: AbortSignal,
    proxy: (pluginId: string, request: JsonObject) => string,
  ): Promise<SourceProxyResource | undefined> {
    const decoded = decodeSourceResourceToken(token);
    if (decoded === undefined) return openSourceProxyResource(undefined, requestHeaders, signal);
    const entry: SourceProxyEntry = {
      fetch: this.#http.fetch.bind(this.#http),
      proxy: (request) => proxy(decoded.pluginId, request),
      request: decoded.request,
    };
    const resource = await this.#warmup.open(decoded.pluginId, entry, requestHeaders, signal);
    if (resource === undefined) return undefined;
    return Object.freeze({
      ...resource,
      onServed: (status: number, bytes: number, durationMs: number) => {
        if (!this.#debugLogEnabled()) return;
        this.#events({
          code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy",
          logLevel: status >= 400 ? "warn" : "debug",
          logMessage: `资源代理响应：类型=${String(decoded.request.kind)}，角色=${String(decoded.request.resourceRole ?? "root")}，状态=${status}，耗时毫秒=${Math.round(durationMs)}，字节=${bytes}`,
          outcome: status >= 400 ? "error" : "success", pluginId: decoded.pluginId,
        });
      },
    });
  }

  #logWarmup(event: HlsWarmupEvent): void {
    if (!this.#debugLogEnabled()) return;
    this.#events({
      code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy",
      logLevel: event.phase === "failed" ? "warn" : "debug",
      logMessage: `HLS清单预热：阶段=${event.phase}，角色=${event.resourceRole}，耗时毫秒=${event.durationMs}${event.bytes === undefined ? "" : `，字节=${event.bytes}`}`,
      outcome: event.phase === "failed" ? "error" : event.phase === "started" ? "started" : "success",
      pluginId: event.pluginId,
    });
  }
}
