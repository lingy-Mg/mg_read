/**
 * Debug HTTP 与 Runtime Core 分派桥。
 *
 * 职责：
 * - 为 Debug 页面构造有截止时间的内部 capability 请求；
 * - 复用 Core 的真实搜索、发现、插件和资源调用链。
 *
 * 注意：
 * - 不暴露内部 RuntimeRequest 或 token 给浏览器；
 * - 只在平台明确允许 Debug listener 时由 Core 创建。
 */
import { randomUUID } from "node:crypto";

import { RuntimeDebugHttpServer } from "./debug-http.js";
import type { JsonObject, JsonValue, RuntimeRequest } from "./protocol.js";
import { protocolVersion } from "./runtime-version.js";

type RuntimeDebugDispatch = (request: RuntimeRequest) => Promise<
  | { readonly result: JsonValue }
  | { readonly error: { readonly code: string } }
>;

export function createRuntimeDebugHttpServer(
  bootId: string,
  dispatch: RuntimeDebugDispatch,
): RuntimeDebugHttpServer {
  const invoke = async (method: string, params: JsonObject): Promise<JsonValue> => {
    const outcome = await dispatch({
      bootId,
      deadlineUnixMs: String(Date.now() + 30_000),
      id: `debug-http-${randomUUID()}`,
      idempotencyKey: null,
      method,
      params,
      traceId: `debug-http-${randomUUID()}`,
      v: protocolVersion,
    });
    if ("error" in outcome) throw new Error(outcome.error.code);
    return outcome.result;
  };
  return new RuntimeDebugHttpServer({
    discover: (params) => invoke("source.discover.v1", params),
    plugins: () => invoke("plugins.list.v1", {}),
    search: (params) => invoke("source.search.v1", params),
    status: async () => {
      const result = await invoke("runtime.status.v1", {});
      if (typeof result !== "object" || result === null || Array.isArray(result)) throw new Error("debug_status_invalid");
      return result as JsonObject;
    },
  });
}
