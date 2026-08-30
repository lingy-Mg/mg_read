/**
 * Executes and validates one bounded plugin-authored resource response.
 *
 * Resource calls share the same invocation scope and operation capacity as
 * source capabilities so HTTP cancellation and exclusive cache cleanup remain
 * consistent. Response bytes stay on the Runtime data plane.
 */
import type { AsyncLocalStorage } from "node:async_hooks";

import type { JsonObject } from "./protocol.js";
import type {
  LoadedPlugin,
  PluginInvocationScope,
  PluginManagerEventSink,
  PluginResourceResponse,
} from "./plugin-manager-contract.js";
import { PluginManagerError } from "./plugin-manager-contract.js";

const maximumResourceBodyBytes = 8 * 1024 * 1024;

export async function invokePluginResource(options: {
  readonly debugLogEnabled: () => boolean;
  readonly deadlineUnixMs: string;
  readonly events: PluginManagerEventSink;
  readonly invocationScope: AsyncLocalStorage<PluginInvocationScope>;
  readonly loaded: LoadedPlugin;
  readonly pluginId: string;
  readonly request: JsonObject;
  readonly signal: AbortSignal;
}): Promise<PluginResourceResponse> {
  const { debugLogEnabled, deadlineUnixMs, events, invocationScope, loaded, pluginId, request, signal } = options;
  const startedAt = performance.now();
  if (debugLogEnabled()) events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy", logLevel: "debug", logMessage: `资源代理请求开始：参数=${JSON.stringify(request)}`, outcome: "success", pluginId });
  const result = await invocationScope.run(
    Object.freeze({ deadlineUnixMs, signal }),
    () => loaded.module.resource(request),
  );
  if (typeof result !== "object" || result === null) throw new PluginManagerError("invalid_request");
  const value = result as Record<string, unknown>;
  const status = value.status === undefined ? 200 : value.status;
  const bodyValue = value.body;
  const body = typeof bodyValue === "string"
    ? Buffer.from(bodyValue, "utf8")
    : bodyValue instanceof Uint8Array
      ? Buffer.from(bodyValue)
      : undefined;
  if (
    typeof status !== "number" ||
    !Number.isInteger(status) ||
    status < 100 ||
    status > 599 ||
    body === undefined ||
    body.byteLength > maximumResourceBodyBytes
  ) throw new PluginManagerError("invalid_request");
  const headers: Record<string, string> = {};
  if (value.headers !== undefined) {
    if (typeof value.headers !== "object" || value.headers === null) throw new PluginManagerError("invalid_request");
    for (const [key, header] of Object.entries(value.headers as Record<string, unknown>)) {
      if (!/^(content-type|cache-control|content-disposition|etag|expires|last-modified)$/i.test(key) || typeof header !== "string" || header.length > 1024) throw new PluginManagerError("invalid_request");
      headers[key] = header;
    }
  }
  if (debugLogEnabled()) events({ code: "plugin_log_emitted", logCategory: "runtime.plugin.resource_proxy", logLevel: "debug", logMessage: `资源代理请求完成：状态=${status}，字节=${body.byteLength}，耗时毫秒=${Math.round(performance.now() - startedAt)}`, outcome: "success", pluginId });
  return { status, headers, body };
}
