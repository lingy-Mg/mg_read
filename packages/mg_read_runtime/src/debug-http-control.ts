/**
 * Runtime Debug HTTP 开关控制分派。
 *
 * 职责：
 * - 校验 Debug listener 的最小强类型控制参数；
 * - 将启停委托给已启动 Runtime 所拥有的 listener。
 *
 * 注意：
 * - 不创建 RPC 或资源路由；
 * - Release 是否调用此控制项由 Flutter Facade 的 Debug 边界决定。
 */
import { type RuntimeDebugHttpServer } from "./debug-http.js";
import type { JsonValue, RuntimeProtocolError, RuntimeRequest } from "./protocol.js";

export type RuntimeDebugHttpDispatchResult =
  | { readonly result: JsonValue }
  | { readonly error: RuntimeProtocolError };

export async function dispatchDebugHttpSetEnabled(
  request: RuntimeRequest,
  debugHttp: RuntimeDebugHttpServer | undefined,
): Promise<RuntimeDebugHttpDispatchResult> {
  if (
    Object.keys(request.params).length !== 1 ||
    typeof request.params.enabled !== "boolean"
  ) {
    return { error: requestError(request, "invalid_request", "The Runtime Debug HTTP setting requires one boolean enabled field.") };
  }
  if (debugHttp === undefined) {
    return { error: requestError(request, "internal", "The Runtime Debug HTTP server is unavailable.") };
  }
  try {
    return { result: await debugHttp.setEnabled(request.params.enabled) };
  } catch {
    return { error: requestError(request, "internal", "The Runtime Debug HTTP server could not change state.") };
  }
}

function requestError(
  request: RuntimeRequest,
  code: RuntimeProtocolError["code"],
  message: string,
): RuntimeProtocolError {
  return { code, message, requestId: request.id, traceId: request.traceId };
}
