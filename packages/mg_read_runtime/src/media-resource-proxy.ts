/** Runtime data-plane media proxy registry. Plugin code never sees a body. */
import type { JsonObject } from "./protocol.js";
import type { PluginRuntimeHttpClient } from "./plugin-manager-contract.js";

export type MediaProxyEntry = {
  readonly fetch: PluginRuntimeHttpClient["fetch"];
  readonly proxy: (request: JsonObject) => string;
  readonly request: JsonObject;
};

/** Opens a Manager-owned media resource without duplicating its token registry. */
export async function openMediaProxyResource(
  entry: MediaProxyEntry | undefined,
  requestHeaders: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<{ readonly request: JsonObject; readonly response: Response; readonly proxy: MediaProxyEntry["proxy"] } | undefined> {
  if (entry === undefined || signal.aborted || !isMediaProxyRequest(entry.request)) return undefined;
  const rawUrl = entry.request.url;
  const headers = entry.request.headers;
  if (typeof rawUrl !== "string" || !isHeaderRecord(headers)) return undefined;
  const forwarded: Record<string, string> = { ...headers };
  for (const name of ["range", "if-range"]) {
    const value = requestHeaders[name];
    if (value !== undefined && value.length <= 512) forwarded[name] = value;
  }
  const response = await entry.fetch(rawUrl, { headers: forwarded, method: "GET", redirect: "follow", signal });
  return Object.freeze({ proxy: entry.proxy, request: entry.request, response });
}

function isMediaProxyRequest(request: JsonObject): boolean {
  const kind = request.kind;
  const url = request.url;
  return (kind === "audio" || kind === "video" || kind === "hls") && typeof url === "string" && isHttpUrl(url) && isHeaderRecord(request.headers);
}

function isHttpUrl(value: string): boolean {
  try { const url = new URL(value); return (url.protocol === "http:" || url.protocol === "https:") && url.username === "" && url.password === ""; }
  catch { return false; }
}

function isHeaderRecord(value: unknown): value is Readonly<Record<string, string>> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const values = Object.entries(value);
  return values.length <= 16 && values.every(([name, header]) => /^[A-Za-z0-9-]{1,64}$/.test(name) && typeof header === "string" && header.length <= 4096 && !/[\r\n]/.test(header));
}
