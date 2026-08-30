/** Validates the app-owned proxy setting sent to the Runtime control plane. */
import type { RuntimeProtocolError, RuntimeRequest } from "./protocol.js";

export type PluginHttpProxyConfiguration =
  | { readonly proxyUrl: string | undefined }
  | { readonly error: RuntimeProtocolError };

export function readPluginHttpProxyConfiguration(
  request: RuntimeRequest,
): PluginHttpProxyConfiguration {
  if (Object.keys(request.params).length !== 1) return invalid(request);
  const raw = request.params.proxyUrl;
  if (raw === null) return { proxyUrl: undefined };
  if (typeof raw !== "string" || Buffer.byteLength(raw, "utf8") > 2048) return invalid(request);
  try {
    const proxy = new URL(raw);
    if (
      !new Set(["http:", "https:", "socks5:"]).has(proxy.protocol) ||
      proxy.hostname === "" ||
      proxy.port === "" ||
      proxy.username !== "" ||
      proxy.password !== "" ||
      proxy.pathname !== "/" ||
      proxy.search !== "" ||
      proxy.hash !== ""
    ) return invalid(request);
    return { proxyUrl: proxy.href };
  } catch {
    return invalid(request);
  }
}

function invalid(request: RuntimeRequest): { readonly error: RuntimeProtocolError } {
  return {
    error: {
      code: "invalid_request",
      message: "The plugin HTTP proxy setting requires one credential-free HTTP, HTTPS or SOCKS5 proxy URL or null.",
      requestId: request.id,
      traceId: request.traceId,
    },
  };
}
