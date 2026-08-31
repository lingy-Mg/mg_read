/** Runtime data-plane source resource proxy. Plugin code never sees a body. */
import type { JsonObject } from "./protocol.js";
import type { PluginRuntimeHttpClient } from "./plugin-manager-contract.js";

export type SourceProxyEntry = {
  readonly fetch: PluginRuntimeHttpClient["fetch"];
  readonly proxy: (request: JsonObject) => string;
  readonly request: JsonObject;
};

/** Opens a Manager-owned source resource without duplicating its token registry. */
export async function openSourceProxyResource(
  entry: SourceProxyEntry | undefined,
  requestHeaders: Readonly<Record<string, string>>,
  signal: AbortSignal,
): Promise<{ readonly request: JsonObject; readonly response: Response; readonly proxy: SourceProxyEntry["proxy"] } | undefined> {
  if (entry === undefined || signal.aborted) return undefined;
  const rawUrl = entry.request.url;
  if (typeof entry.request.kind !== "string" || typeof rawUrl !== "string" || !isHttpUrl(rawUrl)) return undefined;
  const forwarded = sourceHeaders(entry.request);
  if (forwarded === undefined) return undefined;
  if (entry.request.resourceRole !== "hlsKey") {
    for (const name of ["range", "if-range"]) {
      const value = requestHeaders[name];
      if (value !== undefined && value.length <= 512) forwarded[name] = value;
    }
  }
  const response = await entry.fetch(rawUrl, { headers: forwarded, method: "GET", redirect: "follow", signal });
  return Object.freeze({ proxy: entry.proxy, request: entry.request, response });
}

function sourceHeaders(request: JsonObject): Record<string, string> | undefined {
  const configured = request.headers;
  if (!isHeaderRecord(configured)) return undefined;
  return { ...configured };
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
